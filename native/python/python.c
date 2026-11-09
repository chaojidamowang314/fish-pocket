// Python for the engine: CPython (python.org's iOS build, scripts/fetch-python.sh)
// embedded in the app. iOS has no fork/exec, so a Python "process" is a
// subinterpreter with its own GIL on a thread of its own:
//
//   - its stdin, stdout and stderr are pipes; the engine reads and writes the
//     other ends, so output streams while it runs (engine/runtime/python);
//   - its working directory is its own (DshRoot's dsh_root_enter, which the
//     threads it starts share);
//   - engine/runtime/python/boot.py runs first in it: it sets up sys and the
//     standard streams, makes what would act on the whole app (signals,
//     os._exit, the environment) act on this process only, and runs the
//     command line the way the python executable does.
//
// libpython and its extension modules depend on DshRoot instead of libSystem,
// so they see the engine's filesystem view, as Node does. The main interpreter
// only hosts the others: it is created on first use and never runs code.
//
// Registered as the linked binding `dsh_python`:
//   configure({ boot, stdlib, executable, prefix, cafile })
//   spawn({ argv, executable, cwd, env: ["K=V"…] }, onExit(code, signal))
//     -> { pid, stdin, stdout, stderr }  (the engine's ends of the pipes)
//   kill(pid, signal) -> whether the process was still running
#include <Python/Python.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <node_api.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../root/root.h"

// ---- settings --------------------------------------------------------------

static struct {
  char *bootPath;
  char *bootSource;
  char *stdlib;      // engine path of lib/python3.X
  char *executable;  // the default sys.executable: an engine path
  char *prefix;      // sys.prefix: where pip installs outside a venv
  char *cafile;      // certificates for ssl's default verify paths
  char bundle[PATH_MAX];  // the app bundle, real path: extension frameworks load from here
} settings;

static pthread_mutex_t settingsLock = PTHREAD_MUTEX_INITIALIZER;

// ---- processes -------------------------------------------------------------

enum { SIGNAL_NONE = 0 };

typedef struct Process {
  int pid;
  int parent;
  int argc;
  char **argv;
  char **env;
  char *cwd;
  char *executable;
  int fds[3];  // the Python side of stdin, stdout, stderr; owned by the process

  pthread_mutex_t lock;
  pthread_cond_t changed;
  PyInterpreterState *interpreter;
  unsigned long mainThread;
  bool running;    // interrupts may be delivered
  int deliveries;  // interrupts being delivered right now
  bool done;
  int exitCode;
  int killedWith;  // the signal that ended it, if one did
  int references;

  napi_threadsafe_function onExit;  // NULL when Python started it (_dsh.spawn)
  struct Process *next;
} Process;

static pthread_mutex_t tableLock = PTHREAD_MUTEX_INITIALIZER;
static Process *table;
static int nextPid = 20000;

static void retain(Process *process) {
  pthread_mutex_lock(&process->lock);
  process->references++;
  pthread_mutex_unlock(&process->lock);
}

static void freeStrings(char **strings) {
  if (strings == NULL) return;
  for (char **s = strings; *s != NULL; s++) free(*s);
  free(strings);
}

static void release(Process *process) {
  pthread_mutex_lock(&process->lock);
  int left = --process->references;
  pthread_mutex_unlock(&process->lock);
  if (left > 0) return;
  freeStrings(process->argv);
  freeStrings(process->env);
  free(process->cwd);
  free(process->executable);
  pthread_mutex_destroy(&process->lock);
  pthread_cond_destroy(&process->changed);
  free(process);
}

/** The process `pid`, retained; NULL when there is none. */
static Process *find(int pid) {
  pthread_mutex_lock(&tableLock);
  Process *found = table;
  while (found != NULL && found->pid != pid) found = found->next;
  if (found != NULL) retain(found);
  pthread_mutex_unlock(&tableLock);
  return found;
}

static void unlist(Process *process) {
  pthread_mutex_lock(&tableLock);
  for (Process **at = &table; *at != NULL; at = &(*at)->next) {
    if (*at == process) {
      *at = process->next;
      break;
    }
  }
  pthread_mutex_unlock(&tableLock);
}

static void report(int fd, const char *message) {
  char line[1024];
  int length = snprintf(line, sizeof line, "python: %s\n", message);
  if (length > 0) (void)!write(fd, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
}

// ---- the interpreters --------------------------------------------------------

static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static PyInterpreterState *mainInterpreter;
static char initError[512];

static PyObject *initDshModule(void);

static bool setString(PyConfig *config, wchar_t **field, const char *value, PyStatus *status) {
  *status = PyConfig_SetBytesString(config, field, value);
  return !PyStatus_Exception(*status);
}

static void initialize(void) {
  PyStatus status;
  PyPreConfig pre;
  PyPreConfig_InitIsolatedConfig(&pre);
  pre.utf8_mode = 1;
  status = Py_PreInitialize(&pre);
  if (PyStatus_Exception(status)) {
    snprintf(initError, sizeof initError, "pre-initialisation failed: %s", status.err_msg ? status.err_msg : "?");
    return;
  }
  if (PyImport_AppendInittab("_dsh", initDshModule) != 0) {
    snprintf(initError, sizeof initError, "cannot register _dsh");
    return;
  }

  PyConfig config;
  PyConfig_InitIsolatedConfig(&config);
  // The app's signals are the app's: no Python handlers on them.
  config.install_signal_handlers = 0;
  config.configure_c_stdio = 0;
  config.parse_argv = 0;
  config.use_environment = 0;
  config.user_site_directory = 0;
  config.pathconfig_warnings = 0;
  config.faulthandler = 0;
  // boot.py imports site for each process, after it knows the executable (a venv's or not).
  config.site_import = 0;
  config.write_bytecode = 1;

  char dynload[PATH_MAX];
  snprintf(dynload, sizeof dynload, "%s/lib-dynload", settings.stdlib);
  wchar_t *paths[2] = {Py_DecodeLocale(settings.stdlib, NULL), Py_DecodeLocale(dynload, NULL)};
  bool ok = paths[0] != NULL && paths[1] != NULL &&
            setString(&config, &config.program_name, "python3", &status) &&
            setString(&config, &config.executable, settings.executable, &status) &&
            setString(&config, &config.base_executable, settings.executable, &status) &&
            setString(&config, &config.prefix, settings.prefix, &status) &&
            setString(&config, &config.base_prefix, settings.prefix, &status) &&
            setString(&config, &config.exec_prefix, settings.prefix, &status) &&
            setString(&config, &config.base_exec_prefix, settings.prefix, &status) &&
            setString(&config, &config.stdlib_dir, settings.stdlib, &status);
  if (ok) {
    config.module_search_paths_set = 1;
    for (int i = 0; ok && i < 2; i++) {
      status = PyWideStringList_Append(&config.module_search_paths, paths[i]);
      ok = !PyStatus_Exception(status);
    }
  }
  PyMem_RawFree(paths[0]);
  PyMem_RawFree(paths[1]);
  if (ok) status = Py_InitializeFromConfig(&config);
  PyConfig_Clear(&config);
  if (!ok || PyStatus_Exception(status)) {
    snprintf(initError, sizeof initError, "initialisation failed: %s", status.err_msg ? status.err_msg : "?");
    return;
  }
  mainInterpreter = PyInterpreterState_Main();
  // The main interpreter only hosts: release its GIL for good.
  PyEval_SaveThread();
}

/** A Python str from UTF-8 (bytes that are not become surrogates, as file names do). */
static PyObject *text(const char *value) { return PyUnicode_DecodeFSDefault(value); }

static PyObject *stringList(char **strings) {
  PyObject *list = PyList_New(0);
  for (char **s = strings; list != NULL && *s != NULL; s++) {
    PyObject *item = text(*s);
    if (item == NULL || PyList_Append(list, item) != 0) Py_CLEAR(list);
    Py_XDECREF(item);
  }
  return list;
}

static int setItem(PyObject *dict, const char *key, PyObject *value) {
  if (value == NULL) return -1;
  int result = PyDict_SetItemString(dict, key, value);
  Py_DECREF(value);
  return result;
}

/** Run boot.py's main(spec) in the current (new) interpreter: the exit code. */
static int boot(Process *process) {
  PyObject *spec = PyDict_New();
  if (spec == NULL || setItem(spec, "argv", stringList(process->argv)) != 0 ||
      setItem(spec, "env", stringList(process->env)) != 0 || setItem(spec, "cwd", text(process->cwd)) != 0 ||
      setItem(spec, "executable", text(process->executable)) != 0 ||
      setItem(spec, "base_executable", text(settings.executable)) != 0 ||
      setItem(spec, "bundle", text(settings.bundle)) != 0 ||
      setItem(spec, "cafile", text(settings.cafile ? settings.cafile : "")) != 0 ||
      setItem(spec, "pid", PyLong_FromLong(process->pid)) != 0 ||
      setItem(spec, "ppid", PyLong_FromLong(process->parent)) != 0 ||
      setItem(spec, "fds", Py_BuildValue("(iii)", process->fds[0], process->fds[1], process->fds[2])) != 0) {
    Py_XDECREF(spec);
    PyErr_Clear();
    report(process->fds[2], "cannot describe the process to Python");
    return 1;
  }
  int code = 1;
  PyObject *globals = PyDict_New();
  PyObject *compiled = NULL, *result = NULL, *main = NULL;
  if (globals != NULL && PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins()) == 0 &&
      setItem(globals, "__name__", text("_dsh_boot")) == 0 &&
      (compiled = Py_CompileString(settings.bootSource, settings.bootPath, Py_file_input)) != NULL &&
      (result = PyEval_EvalCode(compiled, globals, globals)) != NULL &&
      (main = PyDict_GetItemString(globals, "main")) != NULL) {
    PyObject *returned = PyObject_CallOneArg(main, spec);
    if (returned != NULL) {
      code = (int)PyLong_AsLong(returned);
      if (code == -1 && PyErr_Occurred()) code = 1;
      Py_DECREF(returned);
    }
  }
  if (PyErr_Occurred()) {
    // boot.py reports what the program raises; this is boot.py itself failing.
    PyObject *error = PyErr_GetRaisedException();
    PyObject *description = error ? PyObject_Str(error) : NULL;
    const char *message = description ? PyUnicode_AsUTF8(description) : NULL;
    PyErr_Clear();
    report(process->fds[2], message ? message : "boot failed");
    Py_XDECREF(description);
    Py_XDECREF(error);
  }
  Py_XDECREF(result);
  Py_XDECREF(compiled);
  Py_XDECREF(globals);
  Py_DECREF(spec);
  return code;
}

/** The interpreter's threads other than `self`; with `stop`, each is asked to raise SystemExit. */
static int otherThreads(PyThreadState *self, bool stop) {
  int others = 0;
  for (PyThreadState *t = PyInterpreterState_ThreadHead(PyThreadState_GetInterpreter(self)); t != NULL; t = PyThreadState_Next(t)) {
    if (t == self) continue;
    others++;
    if (stop) PyThreadState_SetAsyncExc(t->thread_id, PyExc_SystemExit);
  }
  return others;
}

/**
 * The process's life on its thread. A process ends when its main thread does,
 * as a real one does: the daemon threads it leaves are asked to stop; any that
 * do not within half a second keep the interpreter (and only that) alive.
 */
static int runInterpreter(Process *process, bool *abandoned) {
  pthread_once(&initialized, initialize);
  if (mainInterpreter == NULL) {
    report(process->fds[2], initError);
    return 1;
  }
  PyThreadState *bridge = PyThreadState_New(mainInterpreter);
  PyEval_RestoreThread(bridge);
  PyInterpreterConfig config = {
      .use_main_obmalloc = 0,
      .allow_fork = 0,
      .allow_exec = 0,
      .allow_threads = 1,
      .allow_daemon_threads = 1,
      .check_multi_interp_extensions = 1,
      .gil = PyInterpreterConfig_OWN_GIL,
  };
  PyThreadState *state = NULL;
  PyStatus status = Py_NewInterpreterFromConfig(&state, &config);
  if (PyStatus_Exception(status)) {
    report(process->fds[2], status.err_msg ? status.err_msg : "cannot create an interpreter");
    PyThreadState_Clear(bridge);
    PyThreadState_DeleteCurrent();
    return 1;
  }
  // The main interpreter's GIL is released; this one's is held.
  pthread_mutex_lock(&process->lock);
  process->interpreter = PyThreadState_GetInterpreter(state);
  process->mainThread = PyThread_get_thread_ident();
  process->running = true;
  int killedEarly = process->killedWith;
  pthread_mutex_unlock(&process->lock);

  // Killed before it could run: it never starts.
  int code = killedEarly != SIGNAL_NONE ? 128 + killedEarly : boot(process);

  for (int round = 0; round < 10 && otherThreads(state, round % 5 == 0) > 0; round++) {
    Py_BEGIN_ALLOW_THREADS
    usleep(50 * 1000);
    Py_END_ALLOW_THREADS
  }
  // No interrupt may be on its way in once the interpreter goes.
  PyThreadState *saved = PyEval_SaveThread();
  pthread_mutex_lock(&process->lock);
  process->running = false;
  while (process->deliveries > 0) pthread_cond_wait(&process->changed, &process->lock);
  // A later interpreter may get this address: it must not be taken for this process.
  process->interpreter = NULL;
  pthread_mutex_unlock(&process->lock);
  PyEval_RestoreThread(saved);

  if (otherThreads(state, false) == 0) {
    Py_EndInterpreter(state);
  } else {
    *abandoned = true;
    PyEval_SaveThread();
  }
  PyEval_RestoreThread(bridge);
  PyThreadState_Clear(bridge);
  PyThreadState_DeleteCurrent();
  return code;
}

static void callExit(napi_env env, napi_value callback, void *context, void *data) {
  Process *process = data;
  if (env != NULL && callback != NULL) {
    napi_value arguments[2], global;
    pthread_mutex_lock(&process->lock);
    int code = process->exitCode, signal = process->killedWith;
    pthread_mutex_unlock(&process->lock);
    if (signal != SIGNAL_NONE) {
      napi_get_null(env, &arguments[0]);
      napi_create_int32(env, signal, &arguments[1]);
    } else {
      napi_create_int32(env, code, &arguments[0]);
      napi_get_null(env, &arguments[1]);
    }
    napi_get_global(env, &global);
    napi_call_function(env, global, callback, 2, arguments, NULL);
  }
  release(process);
}

static void *runProcess(void *value) {
  Process *process = value;
  if (dsh_root_enter(process->cwd) != 0) dsh_root_enter("/");
  bool abandoned = false;
  int code = runInterpreter(process, &abandoned);
  dsh_root_leave();
  // Closing the pipes is what the engine sees as end of output. Threads that
  // outlived the process may still hold these numbers: point them at
  // /dev/null instead, so the numbers never reach a file opened later.
  int null = abandoned ? open("/dev/null", O_RDWR | O_CLOEXEC) : -1;
  for (int i = 0; i < 3; i++) {
    if (null >= 0) dup2(null, process->fds[i]);
    else close(process->fds[i]);
  }
  if (null >= 0) close(null);

  pthread_mutex_lock(&process->lock);
  process->exitCode = code;
  process->done = true;
  pthread_cond_broadcast(&process->changed);
  napi_threadsafe_function onExit = process->onExit;
  pthread_mutex_unlock(&process->lock);
  if (onExit != NULL) {
    // Reaped: the table's reference goes to the exit callback.
    unlist(process);
    if (napi_call_threadsafe_function(onExit, process, napi_tsfn_blocking) != napi_ok) release(process);
    napi_release_threadsafe_function(onExit, napi_tsfn_release);
  }
  release(process);  // the thread's reference
  return NULL;
}

static char **copyStrings(char **strings, int count) {
  char **copy = calloc((size_t)count + 1, sizeof *copy);
  for (int i = 0; copy != NULL && i < count; i++) {
    if ((copy[i] = strdup(strings[i])) == NULL) {
      freeStrings(copy);
      return NULL;
    }
  }
  return copy;
}

/**
 * A new process with the given descriptors (which it now owns), listed and
 * started; the table holds one reference until it is reaped. NULL with errno.
 */
static Process *start(int argc, char **argv, int envc, char **env, const char *cwd, const char *executable, int parent,
                      const int fds[3], napi_threadsafe_function onExit) {
  Process *process = calloc(1, sizeof *process);
  if (process == NULL) return NULL;
  pthread_mutex_init(&process->lock, NULL);
  pthread_cond_init(&process->changed, NULL);
  process->references = 2;  // the table's and the thread's
  process->argc = argc;
  process->argv = copyStrings(argv, argc);
  process->env = copyStrings(env, envc);
  process->cwd = strdup(cwd);
  process->executable = strdup(executable);
  process->parent = parent;
  memcpy(process->fds, fds, sizeof process->fds);
  process->onExit = onExit;
  if (process->argv == NULL || process->env == NULL || process->cwd == NULL || process->executable == NULL) {
    process->references = 1;
    release(process);
    errno = ENOMEM;
    return NULL;
  }
  pthread_mutex_lock(&tableLock);
  process->pid = nextPid++;
  process->next = table;
  table = process;
  pthread_mutex_unlock(&tableLock);

  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  // Python's own default thread stack on Apple platforms is larger than pthread's.
  pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  pthread_t thread;
  int failure = pthread_create(&thread, &attributes, runProcess, process);
  pthread_attr_destroy(&attributes);
  if (failure != 0) {
    unlist(process);
    process->references = 1;
    release(process);
    errno = failure;
    return NULL;
  }
  return process;
}

typedef struct {
  Process *process;
  int signal;
} Delivery;

/** Raise KeyboardInterrupt (SIGINT) or SystemExit (anything else) in the process's main thread. */
static void *deliver(void *value) {
  Delivery delivery = *(Delivery *)value;
  free(value);
  Process *process = delivery.process;
  pthread_mutex_lock(&process->lock);
  bool running = process->running;
  if (running) process->deliveries++;
  pthread_mutex_unlock(&process->lock);
  if (running) {
    PyThreadState *visitor = PyThreadState_New(process->interpreter);
    PyEval_RestoreThread(visitor);
    PyThreadState_SetAsyncExc(process->mainThread, delivery.signal == SIGINT ? PyExc_KeyboardInterrupt : PyExc_SystemExit);
    PyThreadState_Clear(visitor);
    PyThreadState_DeleteCurrent();
    pthread_mutex_lock(&process->lock);
    process->deliveries--;
    pthread_cond_broadcast(&process->changed);
    pthread_mutex_unlock(&process->lock);
  }
  release(process);
  return NULL;
}

/**
 * Signal a process: SIGINT interrupts it, any other signal but 0 ends it. The
 * interrupt takes effect when its main thread next runs Python code. Returns
 * whether it was still running.
 */
static bool signalProcess(Process *process, int signal) {
  pthread_mutex_lock(&process->lock);
  bool running = !process->done;
  if (running && signal != SIGINT && signal != 0) process->killedWith = signal;
  pthread_mutex_unlock(&process->lock);
  if (!running || signal == 0) return running;
  Delivery *delivery = malloc(sizeof *delivery);
  if (delivery == NULL) return running;
  *delivery = (Delivery){process, signal};
  retain(process);
  pthread_t thread;
  // Delivering waits for the process's GIL: never on the caller's thread.
  if (pthread_create(&thread, NULL, deliver, delivery) == 0) {
    pthread_detach(thread);
  } else {
    free(delivery);
    release(process);
  }
  return running;
}

// ---- _dsh: what boot.py gets from here ---------------------------------------

/** The process whose interpreter is the current one: its pid, or 0. */
static int currentPid(void) {
  PyInterpreterState *interpreter = PyInterpreterState_Get();
  int pid = 0;
  pthread_mutex_lock(&tableLock);
  for (Process *p = table; p != NULL && pid == 0; p = p->next) {
    if (p->interpreter == interpreter) pid = p->pid;
  }
  pthread_mutex_unlock(&tableLock);
  return pid;
}

/** Strings of a Python sequence of str, NULL-terminated; NULL with an exception set. */
static char **pyStrings(PyObject *sequence, int *count) {
  PyObject *items = PySequence_Fast(sequence, "expected a sequence of str");
  if (items == NULL) return NULL;
  Py_ssize_t n = PySequence_Fast_GET_SIZE(items);
  char **strings = calloc((size_t)n + 1, sizeof *strings);
  for (Py_ssize_t i = 0; strings != NULL && i < n; i++) {
    PyObject *encoded = PyUnicode_EncodeFSDefault(PySequence_Fast_GET_ITEM(items, i));
    if (encoded == NULL || (strings[i] = strdup(PyBytes_AS_STRING(encoded))) == NULL) {
      Py_XDECREF(encoded);
      freeStrings(strings);
      strings = NULL;
      break;
    }
    Py_DECREF(encoded);
  }
  Py_DECREF(items);
  if (strings == NULL && !PyErr_Occurred()) PyErr_NoMemory();
  *count = (int)n;
  return strings;
}

/** _dsh.spawn(argv, executable, cwd, env, stdin, stdout, stderr) -> pid; the descriptors are duplicated. */
static PyObject *dshSpawn(PyObject *module, PyObject *args) {
  PyObject *argvList, *envList, *executableBytes = NULL, *cwdBytes = NULL;
  int given[3];
  if (!PyArg_ParseTuple(args, "OO&O&Oiii", &argvList, PyUnicode_FSConverter, &executableBytes, PyUnicode_FSConverter, &cwdBytes,
                        &envList, &given[0], &given[1], &given[2])) {
    Py_XDECREF(executableBytes);
    Py_XDECREF(cwdBytes);
    return NULL;
  }
  int argc = 0, envc = 0;
  char **argv = pyStrings(argvList, &argc);
  char **env = argv ? pyStrings(envList, &envc) : NULL;
  PyObject *result = NULL;
  if (argv != NULL && env != NULL) {
    int fds[3] = {-1, -1, -1};
    bool ok = true;
    for (int i = 0; ok && i < 3; i++) ok = (fds[i] = fcntl(given[i], F_DUPFD_CLOEXEC, 3)) >= 0;
    Process *process = NULL;
    if (ok) {
      process = start(argc, argv, envc, env, PyBytes_AS_STRING(cwdBytes), PyBytes_AS_STRING(executableBytes), currentPid(), fds, NULL);
    }
    if (process == NULL) {
      int failure = errno;
      for (int i = 0; i < 3; i++) if (fds[i] >= 0) close(fds[i]);
      errno = failure;
      PyErr_SetFromErrno(PyExc_OSError);
    } else {
      result = PyLong_FromLong(process->pid);
    }
  }
  freeStrings(argv);
  freeStrings(env);
  Py_DECREF(executableBytes);
  Py_DECREF(cwdBytes);
  return result;
}

/** The exit status as Popen.returncode has it: the code, or minus the signal. */
static int returncode(Process *process) { return process->killedWith != SIGNAL_NONE ? -process->killedWith : process->exitCode; }

/** _dsh.wait(pid, timeout=None) -> returncode, or None when the timeout passes first. */
static PyObject *dshWait(PyObject *module, PyObject *args) {
  int pid;
  PyObject *timeoutObject = Py_None;
  if (!PyArg_ParseTuple(args, "i|O", &pid, &timeoutObject)) return NULL;
  double timeout = timeoutObject == Py_None ? -1 : PyFloat_AsDouble(timeoutObject);
  if (timeout == -1 && PyErr_Occurred()) return NULL;
  Process *process = find(pid);
  if (process == NULL) {
    PyErr_SetFromErrno(PyExc_ChildProcessError);
    return NULL;
  }
  bool done;
  int code;
  Py_BEGIN_ALLOW_THREADS
  pthread_mutex_lock(&process->lock);
  if (timeout < 0) {
    while (!process->done) pthread_cond_wait(&process->changed, &process->lock);
  } else {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    long long nanos = deadline.tv_nsec + (long long)(timeout * 1e9);
    deadline.tv_sec += (time_t)(nanos / 1000000000LL);
    deadline.tv_nsec = (long)(nanos % 1000000000LL);
    while (!process->done && pthread_cond_timedwait(&process->changed, &process->lock, &deadline) != ETIMEDOUT) {}
  }
  done = process->done;
  code = returncode(process);
  pthread_mutex_unlock(&process->lock);
  Py_END_ALLOW_THREADS
  if (done) {
    unlist(process);  // reaped
    release(process);  // the table's reference, which unlisting gave up
  }
  release(process);
  if (!done) Py_RETURN_NONE;
  return PyLong_FromLong(code);
}

/** _dsh.kill(pid, signal) -> whether it was running. */
static PyObject *dshKill(PyObject *module, PyObject *args) {
  int pid, signal;
  if (!PyArg_ParseTuple(args, "ii", &pid, &signal)) return NULL;
  Process *process = find(pid);
  if (process == NULL) Py_RETURN_FALSE;
  bool running = signalProcess(process, signal);
  release(process);
  return PyBool_FromLong(running);
}

/**
 * _dsh.interrupt_main(): raise SystemExit in the current process's main thread,
 * which is how os._exit from another thread ends it (boot.py keeps the code).
 */
static PyObject *dshInterruptMain(PyObject *module, PyObject *unused) {
  PyInterpreterState *interpreter = PyInterpreterState_Get();
  unsigned long main = 0;
  pthread_mutex_lock(&tableLock);
  for (Process *p = table; p != NULL && main == 0; p = p->next) {
    if (p->interpreter == interpreter) main = p->mainThread;
  }
  pthread_mutex_unlock(&tableLock);
  if (main != 0) PyThreadState_SetAsyncExc(main, PyExc_SystemExit);
  Py_RETURN_NONE;
}

/**
 * _dsh.real(path) -> the real path of an engine path. For libraries outside
 * the engine's view: the system's libsqlite3 resolves paths itself.
 */
static PyObject *dshReal(PyObject *module, PyObject *args) {
  PyObject *bytes = NULL;
  if (!PyArg_ParseTuple(args, "O&", PyUnicode_FSConverter, &bytes)) return NULL;
  char real[PATH_MAX];
  int failed = dsh_root_real(PyBytes_AS_STRING(bytes), real, sizeof real);
  Py_DECREF(bytes);
  if (failed != 0) return PyErr_SetFromErrno(PyExc_OSError);
  return PyUnicode_DecodeFSDefault(real);
}

static PyMethodDef dshMethods[] = {
    {"spawn", dshSpawn, METH_VARARGS, "Start a Python process: (argv, executable, cwd, env, stdin, stdout, stderr) -> pid."},
    {"wait", dshWait, METH_VARARGS, "Wait for a process started by spawn: (pid, timeout=None) -> returncode or None."},
    {"kill", dshKill, METH_VARARGS, "Signal a process started by spawn: (pid, signal) -> whether it was running."},
    {"real", dshReal, METH_VARARGS, "The real path of an engine path."},
    {"interrupt_main", dshInterruptMain, METH_NOARGS, "Raise SystemExit in the current process's main thread."},
    {NULL, NULL, 0, NULL},
};

static PyModuleDef_Slot dshSlots[] = {
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {0, NULL},
};

static struct PyModuleDef dshModule = {
    PyModuleDef_HEAD_INIT, "_dsh", "Processes for Fish Pocket's embedded Python.", 0, dshMethods, dshSlots, NULL, NULL, NULL,
};

static PyObject *initDshModule(void) { return PyModuleDef_Init(&dshModule); }

// ---- N-API -----------------------------------------------------------------

static napi_value throwError(napi_env env, const char *message) {
  napi_throw_error(env, NULL, message);
  return NULL;
}

/** A property of `object` as a newly allocated UTF-8 string; NULL when absent. */
static char *property(napi_env env, napi_value object, const char *name) {
  napi_value value;
  napi_valuetype type;
  if (napi_get_named_property(env, object, name, &value) != napi_ok || napi_typeof(env, value, &type) != napi_ok ||
      type != napi_string) {
    return NULL;
  }
  size_t length;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) return NULL;
  char *result = malloc(length + 1);
  if (result != NULL) napi_get_value_string_utf8(env, value, result, length + 1, &length);
  return result;
}

/** An array property of strings; NULL when absent. */
static char **stringArray(napi_env env, napi_value object, const char *name, int *count) {
  napi_value array;
  bool isArray = false;
  uint32_t length = 0;
  if (napi_get_named_property(env, object, name, &array) != napi_ok || napi_is_array(env, array, &isArray) != napi_ok || !isArray ||
      napi_get_array_length(env, array, &length) != napi_ok) {
    return NULL;
  }
  char **strings = calloc(length + 1, sizeof *strings);
  for (uint32_t i = 0; strings != NULL && i < length; i++) {
    napi_value item;
    size_t size;
    if (napi_get_element(env, array, i, &item) != napi_ok || napi_get_value_string_utf8(env, item, NULL, 0, &size) != napi_ok ||
        (strings[i] = malloc(size + 1)) == NULL) {
      freeStrings(strings);
      return NULL;
    }
    napi_get_value_string_utf8(env, item, strings[i], size + 1, &size);
  }
  *count = (int)length;
  return strings;
}

static char *readFile(const char *path) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return NULL;
  char *buffer = NULL;
  size_t size = 0, capacity = 0;
  for (;;) {
    if (size + 4096 + 1 > capacity) {
      capacity = capacity ? capacity * 2 : 16384;
      char *grown = realloc(buffer, capacity);
      if (grown == NULL) {
        free(buffer);
        fclose(file);
        return NULL;
      }
      buffer = grown;
    }
    size_t got = fread(buffer + size, 1, 4096, file);
    size += got;
    if (got < 4096) break;
  }
  fclose(file);
  buffer[size] = '\0';
  return buffer;
}

static napi_value configure(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value options;
  if (napi_get_cb_info(env, info, &argc, &options, NULL, NULL) != napi_ok || argc < 1) return throwError(env, "configure(options)");
  char *bootPath = property(env, options, "boot");
  char *stdlib = property(env, options, "stdlib");
  char *executable = property(env, options, "executable");
  char *prefix = property(env, options, "prefix");
  char *cafile = property(env, options, "cafile");
  char *source = bootPath ? readFile(bootPath) : NULL;
  if (source == NULL || stdlib == NULL || executable == NULL || prefix == NULL) {
    free(bootPath); free(stdlib); free(executable); free(prefix); free(cafile); free(source);
    return throwError(env, "configure: boot (a readable file), stdlib, executable and prefix are required");
  }
  pthread_mutex_lock(&settingsLock);
  // The interpreter reads these once it starts; later calls only replace boot.py and the certificates.
  free(settings.bootPath);
  free(settings.bootSource);
  free(settings.cafile);
  settings.bootPath = bootPath;
  settings.bootSource = source;
  settings.cafile = cafile;
  if (settings.stdlib == NULL) {
    settings.stdlib = stdlib;
    settings.executable = executable;
    settings.prefix = prefix;
    char executablePath[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof executablePath;
    // This image's realpath() answers in the engine's view (/opt/dsh/…); dlopen needs the real path.
    if (_NSGetExecutablePath(executablePath, &size) == 0 && realpath(executablePath, resolved) != NULL) {
      *strrchr(resolved, '/') = '\0';
      if (dsh_root_real(resolved, settings.bundle, sizeof settings.bundle) != 0) {
        snprintf(settings.bundle, sizeof settings.bundle, "%s", resolved);
      }
    }
  } else {
    free(stdlib); free(executable); free(prefix);
  }
  pthread_mutex_unlock(&settingsLock);
  // A write to a pipe the engine closed must fail, not end the app.
  struct sigaction current;
  if (sigaction(SIGPIPE, NULL, &current) == 0 && current.sa_handler == SIG_DFL) signal(SIGPIPE, SIG_IGN);
  return NULL;
}

static napi_value spawnProcess(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return throwError(env, "spawn(spec, onExit)");
  if (settings.bootSource == NULL) return throwError(env, "spawn: call configure first");
  int count = 0, envc = 0;
  char **args = stringArray(env, argv[0], "argv", &count);
  char **environment = stringArray(env, argv[0], "env", &envc);
  char *cwd = property(env, argv[0], "cwd");
  char *executable = property(env, argv[0], "executable");
  napi_value result = NULL;
  int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
  if (args == NULL || count == 0 || environment == NULL || cwd == NULL || executable == NULL) {
    throwError(env, "spawn: argv, env, cwd and executable are required");
  } else if (pipe(in) != 0 || pipe(out) != 0 || pipe(err) != 0) {
    throwError(env, strerror(errno));
  } else {
    int ends[6] = {in[0], in[1], out[0], out[1], err[0], err[1]};
    for (int i = 0; i < 6; i++) {
      fcntl(ends[i], F_SETFD, FD_CLOEXEC);
      fcntl(ends[i], F_SETNOSIGPIPE, 1);
    }
    napi_value name;
    napi_threadsafe_function onExit = NULL;
    napi_create_string_utf8(env, "python exit", NAPI_AUTO_LENGTH, &name);
    const int fds[3] = {in[0], out[1], err[1]};
    Process *process = NULL;
    if (napi_create_threadsafe_function(env, argv[1], NULL, name, 0, 1, NULL, NULL, NULL, callExit, &onExit) == napi_ok) {
      process = start(count, args, envc, environment, cwd, executable, 0, fds, onExit);
    }
    if (process == NULL) {
      if (onExit != NULL) napi_release_threadsafe_function(onExit, napi_tsfn_abort);
      throwError(env, "spawn: cannot start the process");
    } else {
      napi_value pid, stdinEnd, stdoutEnd, stderrEnd;
      napi_create_object(env, &result);
      napi_create_int32(env, process->pid, &pid);
      napi_create_int32(env, in[1], &stdinEnd);
      napi_create_int32(env, out[0], &stdoutEnd);
      napi_create_int32(env, err[0], &stderrEnd);
      napi_set_named_property(env, result, "pid", pid);
      napi_set_named_property(env, result, "stdin", stdinEnd);
      napi_set_named_property(env, result, "stdout", stdoutEnd);
      napi_set_named_property(env, result, "stderr", stderrEnd);
      in[0] = in[1] = out[0] = out[1] = err[0] = err[1] = -1;
    }
  }
  int leftovers[6] = {in[0], in[1], out[0], out[1], err[0], err[1]};
  for (int i = 0; i < 6; i++) if (leftovers[i] >= 0) close(leftovers[i]);
  freeStrings(args);
  freeStrings(environment);
  free(cwd);
  free(executable);
  return result;
}

static napi_value killProcess(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2], result;
  int32_t pid = 0, signal = SIGTERM;
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1 || napi_get_value_int32(env, argv[0], &pid) != napi_ok) return throwError(env, "kill(pid, signal)");
  if (argc > 1) napi_get_value_int32(env, argv[1], &signal);
  Process *process = find(pid);
  bool running = process != NULL && signalProcess(process, signal);
  if (process != NULL) release(process);
  napi_get_boolean(env, running, &result);
  return result;
}

static napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"configure", NULL, configure, NULL, NULL, NULL, napi_default, NULL},
      {"spawn", NULL, spawnProcess, NULL, NULL, NULL, napi_default, NULL},
      {"kill", NULL, killProcess, NULL, NULL, NULL, napi_default, NULL},
  };
  napi_define_properties(env, exports, sizeof properties / sizeof *properties, properties);
  return exports;
}

static napi_module module = {1, 0, __FILE__, init, "dsh_python", NULL, {0}};
__attribute__((constructor)) static void registerModule(void) { napi_module_register(&module); }
