# The first code of every Python process in the app (native/python/python.c
# runs main(spec) in the process's fresh subinterpreter). A process here is an
# interpreter on a thread of the app, so before the program runs this:
#   - gives it its standard streams (the pipes the engine reads and writes);
#   - makes what would reach the whole app reach this process only: the
#     environment, os._exit, signals, its pid;
#   - loads extension modules from the app's Frameworks folder, finds
#     certificates for ssl, gives sqlite3 (the system's library, which
#     resolves paths itself) real paths, and runs Python children of subprocess as
#     processes of their own (other programs are not available);
#   - imports site for the executable it was started as, so a venv's
#     bin/python gets that venv;
#   - has pip write console scripts (bin/pip, bin/black…) as sh launchers,
#     which the app's shell can run (it reads every script as bash);
# and then runs the command line as the python executable does.
import sys
import os
import io

import _dsh

VERSION = sys.version.split()[0]
_pending_exit = None
_spec = None


class _Exit(BaseException):
    """os._exit in the main thread: ends the program, skipping its handlers as far as possible."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def main(spec):
    global _spec
    _spec = spec
    unbuffered = 'PYTHONUNBUFFERED' in (e.split('=', 1)[0] for e in spec['env'])
    _streams(spec['fds'], unbuffered)
    _environ(spec['env'])
    _frameworks(spec['bundle'])
    _process(spec)
    _ssl_certificates(spec['cafile'])
    _after_import('sqlite3', _sqlite_paths)
    _after_import('pip._vendor.distlib.scripts', _launchers)
    _subprocess()
    code = _run(spec['argv'][1:], spec['executable'])
    return _finish(code)


# ---- the process ------------------------------------------------------------

def _streams(fds, unbuffered):
    def stream(fd, mode, name, errors, line_buffering):
        raw = io.FileIO(fd, mode, closefd=False)
        raw.name = name
        buffered = io.BufferedReader(raw) if mode == 'r' else io.BufferedWriter(raw)
        return io.TextIOWrapper(buffered, encoding='utf-8', errors=errors, line_buffering=line_buffering,
                                write_through=unbuffered and mode == 'w')
    sys.stdin = sys.__stdin__ = stream(fds[0], 'r', '<stdin>', 'surrogateescape', False)
    sys.stdout = sys.__stdout__ = stream(fds[1], 'w', '<stdout>', 'surrogateescape', True)
    sys.stderr = sys.__stderr__ = stream(fds[2], 'w', '<stderr>', 'backslashreplace', True)


def _environ(entries):
    # The interpreter copied the app's environment; this process has its own.
    # putenv/unsetenv would change the app's, which every process shares.
    os.putenv = lambda key, value: None
    os.unsetenv = lambda key: None
    os.environ._data.clear()
    for entry in entries:
        key, _, value = entry.partition('=')
        if key:
            os.environ[key] = value


def _frameworks(bundle):
    # CPython finds an extension module's framework next to sys.executable,
    # which here names this process's program instead of the app.
    import _frozen_importlib_external as external
    loader = external.AppleFrameworkLoader

    def create_module(self, spec, _external=external):
        if spec.origin.endswith('.fwork'):
            with _external._io.FileIO(spec.origin, 'r') as file:
                binary = file.read().decode().strip()
            spec.origin = _external._path_join(bundle, binary)
        if self.path.endswith('.fwork'):
            path = self.path
        else:
            with _external._io.FileIO(self.path + '.origin', 'r') as file:
                path = _external._path_join('/opt/dsh', file.read().decode().strip())
        module = _external._bootstrap._call_with_frames_removed(_external._imp.create_dynamic, spec)
        try:
            module.__file__ = path
        except AttributeError:
            pass
        return module
    loader.create_module = create_module


def _process(spec):
    import signal

    pid, ppid = spec['pid'], spec['ppid'] or 1
    os.getpid = lambda: pid
    os.getppid = lambda: ppid

    def _exit(code):
        global _pending_exit
        import threading
        if threading.current_thread() is threading.main_thread():
            raise _Exit(code)
        _pending_exit = code
        _dsh.interrupt_main()
        raise SystemExit(code)
    os._exit = _exit
    os.abort = lambda: _exit(134)

    handlers = {}

    def kill(target, sig):
        if target in (pid, 0, -pid):
            if sig == 0:
                return
            if sig == signal.SIGINT and callable(handlers.get(sig)):
                handlers[sig](sig, None)
                return
            if sig == signal.SIGINT and handlers.get(sig) is None:
                raise KeyboardInterrupt
            if handlers.get(sig) == signal.SIG_IGN:
                return
            _exit(128 + int(sig))
        if not _dsh.kill(target, int(sig)):
            raise ProcessLookupError(3, 'No such process')
    os.kill = kill
    os.killpg = kill

    # Only the app's main interpreter may install handlers; a program's are kept
    # and reported back, and SIGINT's runs when this process is interrupted.
    def set_handler(sig, handler):
        previous = handlers.get(sig, signal.SIG_DFL if sig != signal.SIGINT else signal.default_int_handler)
        handlers[sig] = handler
        return previous
    signal.signal = set_handler
    signal.getsignal = lambda sig: handlers.get(sig, signal.SIG_DFL if sig != signal.SIGINT else signal.default_int_handler)
    signal.raise_signal = lambda sig: kill(pid, sig)

    def no_timer(*args, **kwargs):
        raise OSError(45, 'timer signals are not available in Fish Pocket')
    signal.alarm = no_timer
    signal.setitimer = no_timer


def _ssl_certificates(cafile):
    # No system certificate store is reachable from OpenSSL on iOS: ssl's
    # default verify paths are the engine's certificate bundle.
    if not cafile:
        return

    def patch(module):
        context = module.SSLContext
        original = context.set_default_verify_paths

        def set_default_verify_paths(self):
            try:
                self.load_verify_locations(cafile)
            except OSError:
                original(self)
        context.set_default_verify_paths = set_default_verify_paths
    _after_import('ssl', patch)


def _sqlite_paths(module):
    # libsqlite3 is the system's: it sees the app's real filesystem and working
    # directory, not this process's view.
    import functools

    def real(database, uri):
        if isinstance(database, bytes):
            database = os.fsdecode(database)
        elif isinstance(database, os.PathLike):
            database = os.fspath(database)
            if isinstance(database, bytes):
                database = os.fsdecode(database)
        if not isinstance(database, str) or database in ('', ':memory:'):
            return database
        if uri or database.startswith('file:'):
            if not uri:
                return _dsh.real(os.path.abspath(database))
            scheme, rest = database[:5], database[5:]
            if scheme != 'file:':
                return database
            path, mark, query = rest.partition('?')
            if path.startswith('//'):
                authority, slash, path = path[2:].partition('/')
                path = slash + path
            if not path or path == ':memory:':
                return database
            from urllib.parse import quote, unquote
            return 'file:' + quote(_dsh.real(os.path.abspath(unquote(path)))) + mark + query
        return _dsh.real(os.path.abspath(database))

    connect = module.connect

    @functools.wraps(connect)
    def wrapped(database, *args, **kwargs):
        uri = kwargs.get('uri', args[6] if len(args) > 6 else False)
        return connect(real(database, uri), *args, **kwargs)
    module.connect = wrapped
    if 'sqlite3.dbapi2' in sys.modules:
        sys.modules['sqlite3.dbapi2'].connect = wrapped


ENTRY_MARK = '# dsh-python-entry: '


def _launchers(module):
    # A console script is Python behind a #! line; the app's shell would run it
    # as bash. Write a launcher instead: sh that calls the entry point through
    # this environment's python, with a marker line from which the engine and
    # subprocess run it directly (engine/runtime/python/index.mjs).
    import json
    maker = module.ScriptMaker

    def make_script(self, entry, filenames, options=None):
        python = self.executable or sys.executable
        code = (f'import sys,importlib,functools;sys.argv[0]=sys.argv.pop(1);'
                f'sys.exit(functools.reduce(getattr,"{entry.suffix}".split("."),importlib.import_module("{entry.prefix}"))())')
        quoted = '"' + ''.join('\\' + c if c in '"$`\\' else c for c in python) + '"'
        text = (f'#!/bin/sh\n{ENTRY_MARK}{json.dumps({"python": python, "code": code})}\n'
                f"{quoted} -c '{code}' \"$0\" \"$@\"\n")
        names = self.get_script_filenames(entry.name)
        for name in names:
            path = os.path.abspath(os.path.join(self.target_dir, name))
            if os.path.exists(path) and not self.clobber:
                continue
            self._fileop.write_binary_file(path, text.encode('utf-8'))
            if self.set_mode:
                self._fileop.set_executable_mode([path])
            filenames.append(path)
    maker._make_script = make_script


def _after_import(name, patch):
    """Run patch(module) once `name` is imported, without importing it now."""
    if name in sys.modules:
        patch(sys.modules[name])
        return
    import importlib.abc
    import importlib.util

    class Finder(importlib.abc.MetaPathFinder):
        def find_spec(self, fullname, path, target=None):
            if fullname != name:
                return None
            sys.meta_path.remove(self)
            spec = importlib.util.find_spec(fullname)
            if spec is None or spec.loader is None:
                return spec
            # A loader can serve many modules (zipimport serves a whole
            # wheel): wrap it for this module instead of changing it.
            spec.loader = Loader(spec.loader)
            return spec

    class Loader(importlib.abc.Loader):
        def __init__(self, loader):
            self._loader = loader

        def __getattr__(self, attribute):
            return getattr(self._loader, attribute)

        def create_module(self, spec):
            return self._loader.create_module(spec)

        def exec_module(self, module):
            self._loader.exec_module(module)
            patch(module)
    sys.meta_path.insert(0, Finder())


# ---- Python children ----------------------------------------------------------

PYTHON_NAMES = ('python', 'python3', 'python' + VERSION.rsplit('.', 1)[0])
PIP_NAMES = ('pip', 'pip3', 'pip' + VERSION.rsplit('.', 1)[0])


def _lookup(program, cwd, env):
    if '/' in program:
        return os.path.join(cwd, program)
    for directory in (env.get('PATH') or '').split(':'):
        if directory:
            candidate = os.path.join(cwd, directory, program)
            if os.path.isfile(candidate):
                return candidate
    return None


def plan_python(argv, cwd, env):
    """(executable, args) when argv runs Python here, else None; mirrors engine/runtime/python/index.mjs."""
    program, args = argv[0], list(argv[1:])
    base = os.path.basename(program)
    if base in PYTHON_NAMES:
        found = _lookup(program, cwd, env)
        return (found if found and os.path.isfile(found) else _spec['base_executable']), args
    found = _lookup(program, cwd, env)
    if found is None:
        if base in PIP_NAMES and '/' not in program:
            return _spec['base_executable'], ['-m', 'pip', *args]
        return None
    try:
        with open(found, 'rb') as file:
            first = file.readline(512)
    except OSError:
        return None
    if not first.startswith(b'#!'):
        return None
    if first.strip() == b'#!/bin/sh':
        try:
            with open(found, encoding='utf-8') as file:
                file.readline()
                marked = file.readline()
        except (OSError, UnicodeDecodeError):
            return None
        if not marked.startswith(ENTRY_MARK):
            return None
        import json
        launcher = json.loads(marked[len(ENTRY_MARK):])
        python = launcher['python'] if os.path.isfile(launcher['python']) else _spec['base_executable']
        return python, ['-c', launcher['code'], found, *args]
    words = first[2:].decode('utf-8', 'replace').split()
    if words and os.path.basename(words[0]) == 'env':
        words = [w for w in words[1:] if w != '-S']
        if not words:
            return None
        found_interpreter = _lookup(words[0], cwd, env)
        interpreter = found_interpreter if found_interpreter and os.path.isfile(found_interpreter) else None
        if os.path.basename(words[0]) not in PYTHON_NAMES:
            return None
        return (interpreter or _spec['base_executable']), [*words[1:], found, *args]
    if not words or os.path.basename(words[0]) not in PYTHON_NAMES:
        return None
    interpreter = words[0] if os.path.isfile(words[0]) else _spec['base_executable']
    return interpreter, [*words[1:], found, *args]


def _subprocess():
    import subprocess

    def unavailable(program):
        return FileNotFoundError(2, f'{program}: only Python programs can run as a subprocess in Fish Pocket', program)

    def execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env, startupinfo, creationflags,
                      shell, p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite, restore_signals, gid, gids,
                      uid, umask, start_new_session, process_group):
        if isinstance(args, (str, bytes, os.PathLike)):
            args = [args]
        args = [os.fsdecode(a) for a in args]
        if shell:
            import shlex
            try:
                args = shlex.split(' '.join(args))
            except ValueError:
                raise unavailable('/bin/sh')
            if not args or any(any(c in a for c in '|&;<>()$`') for a in args):
                raise unavailable('/bin/sh')
        if executable is not None:
            args[0] = os.fsdecode(executable)
        cwd = os.path.abspath(os.fsdecode(cwd)) if cwd is not None else os.getcwd()
        environment = os.environ if env is None else {os.fsdecode(k): os.fsdecode(v) for k, v in env.items()}
        planned = plan_python(args, cwd, environment)
        if planned is None:
            raise unavailable(args[0])
        program, rest = planned
        fds = [p2cread, c2pwrite, errwrite]
        own = _spec['fds']
        fds = [fd if fd != -1 else own[i] for i, fd in enumerate(fds)]
        try:
            # The child gets its own copies of the descriptors.
            self.pid = _dsh.spawn([args[0], *rest], program, cwd, [f'{k}={v}' for k, v in environment.items()], *fds)
        finally:
            self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)
        self._child_created = True

    def internal_poll(self, _deadstate=None, _del_safe=None):
        if self.returncode is None and getattr(self, 'pid', None):
            code = _dsh.wait(self.pid, 0)
            if code is not None:
                self.returncode = code
        return self.returncode

    def wait(self, timeout):
        if self.returncode is not None:
            return self.returncode
        code = _dsh.wait(self.pid, timeout)
        if code is None:
            raise subprocess.TimeoutExpired(self.args, timeout)
        self.returncode = code
        return code

    def send_signal(self, sig):
        if self.poll() is None:
            _dsh.kill(self.pid, int(sig))

    subprocess._can_fork_exec = True
    subprocess.Popen._execute_child = execute_child
    subprocess.Popen._internal_poll = internal_poll
    subprocess.Popen._wait = wait
    subprocess.Popen.send_signal = send_signal


# ---- the command line ---------------------------------------------------------

USAGE = """usage: python3 [option] ... [-c cmd | -m mod | file | -] [arg] ...
Options (Fish Pocket runs Python inside the app; these are the ones it honours):
-B     : don't write .pyc files
-c cmd : program passed in as string
-E     : ignore PYTHON* environment variables
-h     : print this help message and exit
-I     : isolate Python from the user's environment (implies -E, -P and -s)
-m mod : run library module as a script
-P     : don't prepend a potentially unsafe path to sys.path
-q     : don't print version and copyright messages on interactive startup
-s     : don't add user site directory to sys.path
-S     : don't imply 'import site' on initialization
-u     : force the stdout and stderr streams to be unbuffered
-V     : print the Python version number and exit (also --version)
-W arg : warning control
-X opt : set implementation-specific option
file   : program read from script file
-      : program read from stdin (default; interactive mode is not available)
"""


def _run(args, executable):
    flags = set()
    warnings_options, x_options = [], []
    command = module = None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '--':
            i += 1
            break
        if arg in ('--version', '-V', '-VV'):
            print(f'Python {VERSION}')
            return 0
        if arg in ('--help', '-h', '-?'):
            print(USAGE, end='')
            return 0
        if not arg.startswith('-') or arg == '-':
            break
        j = 1
        while j < len(arg):
            option = arg[j]
            if option in 'cmWX':
                value = arg[j + 1:] or (args[i + 1] if i + 1 < len(args) else None)
                if value is None:
                    print(f'Argument expected for the -{option} option', file=sys.stderr)
                    return 2
                if not arg[j + 1:]:
                    i += 1
                if option == 'c':
                    command = value
                elif option == 'm':
                    module = value
                elif option == 'W':
                    warnings_options.append(value)
                else:
                    x_options.append(value)
                break
            if option == 'O':
                pass  # optimisation levels are fixed when the interpreter starts
            elif option in 'BEIPqsSuvbdi':
                flags.add(option)
            else:
                print(f'Unknown option: -{option}\n{USAGE}', file=sys.stderr, end='')
                return 2
            j += 1
        i += 1
        if command is not None or module is not None:
            break
    rest = args[i:]
    if 'I' in flags:
        flags.update('EPs')
    use_env = 'E' not in flags
    env = os.environ

    if 'B' in flags or (use_env and env.get('PYTHONDONTWRITEBYTECODE')):
        sys.dont_write_bytecode = True
    for option in x_options:
        key, _, value = option.partition('=')
        sys._xoptions[key] = value or True
    if use_env and env.get('PYTHONWARNINGS'):
        warnings_options = env['PYTHONWARNINGS'].split(',') + warnings_options
    if warnings_options:
        sys.warnoptions[:] = warnings_options
        import warnings
        warnings._processoptions(warnings_options)

    sys.executable = executable
    sys._base_executable = _spec['base_executable']
    _venv_prefix(executable)
    if use_env and env.get('PYTHONPATH'):
        sys.path[0:0] = [p for p in env['PYTHONPATH'].split(':') if p]
    if 'S' not in flags:
        import site
        if 's' in flags or (use_env and env.get('PYTHONNOUSERSITE')):
            site.ENABLE_USER_SITE = False
        site.main()

    safe = 'P' in flags or (use_env and env.get('PYTHONSAFEPATH'))
    _flags(no_site=int('S' in flags), isolated=int('I' in flags), ignore_environment=int(not use_env),
           safe_path=int(bool(safe)), no_user_site=int('s' in flags), dont_write_bytecode=int(sys.dont_write_bytecode),
           quiet=int('q' in flags), verbose=int('v' in flags), unbuffered=int('u' in flags))
    import runpy
    if command is not None:
        sys.argv[:] = ['-c', *rest]
        if not safe:
            sys.path.insert(0, '')
        return _call(lambda: _exec(command, '<string>'))
    if module is not None:
        if module == 'pip' and not _ensure_pip():
            return 1
        sys.argv[:] = ['-m', *rest]
        if not safe:
            sys.path.insert(0, os.getcwd())
        return _call(lambda: runpy._run_module_as_main(module, alter_argv=True))
    if not rest or rest[0] == '-':
        sys.argv[:] = rest or ['']
        if not safe:
            sys.path.insert(0, '')
        return _call(lambda: _exec(sys.stdin.read(), '<stdin>'))
    script = rest[0]
    sys.argv[:] = rest
    if not safe:
        sys.path.insert(0, os.path.dirname(os.path.realpath(script)) if os.path.isfile(script) else script)
    if not os.path.exists(script):
        print(f"{executable}: can't open file {os.path.abspath(script)!r}: [Errno 2] No such file or directory",
              file=sys.stderr)
        return 2
    # A script's traceback starts at the script, as python's does.
    _hidden.add(runpy.run_path.__code__.co_filename)
    return _call(lambda: runpy.run_path(os.path.abspath(script), run_name='__main__'))


class _Flags(tuple):
    """sys.flags as this process was started: the interpreter's are the app's."""

    def __new__(cls, flags, changes):
        names = [name for name in dir(flags)
                 if not name.startswith('_') and name not in ('count', 'index', 'n_fields', 'n_sequence_fields', 'n_unnamed_fields')]
        self = super().__new__(cls, flags)
        self._values = {name: changes.get(name, getattr(flags, name)) for name in names}
        return self

    def __getattr__(self, name):
        try:
            return self.__dict__['_values'][name]
        except KeyError:
            raise AttributeError(name) from None

    def __repr__(self):
        return 'sys.flags(' + ', '.join(f'{k}={v!r}' for k, v in self._values.items()) + ')'


def _flags(**changes):
    sys.flags = _Flags(sys.flags, changes)


def _ensure_pip():
    """pip outside a venv: the bundled one, installed into sys.prefix on first use."""
    import importlib.util
    if importlib.util.find_spec('pip') is not None:
        return True
    import subprocess
    print('pip: setting up pip for the first time…', file=sys.stderr, flush=True)
    done = subprocess.run([sys.executable, '-m', 'ensurepip', '--default-pip'], stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE, text=True)
    if done.returncode != 0:
        print(done.stderr, file=sys.stderr, end='')
        return False
    import site
    import importlib
    for directory in site.getsitepackages([sys.prefix]):
        if os.path.isdir(directory) and directory not in sys.path:
            site.addsitedir(directory)
    importlib.invalidate_caches()
    return True


def _venv_prefix(executable):
    """A venv's prefix, as CPython's getpath sets it from pyvenv.cfg before site runs."""
    exe_dir = os.path.dirname(os.path.abspath(executable))
    prefix = os.path.dirname(exe_dir)
    for candidate in (os.path.join(exe_dir, 'pyvenv.cfg'), os.path.join(prefix, 'pyvenv.cfg')):
        if os.path.isfile(candidate):
            sys.prefix = sys.exec_prefix = prefix
            return


def _exec(source, filename):
    import __main__
    code = compile(source, filename, 'exec')
    exec(code, __main__.__dict__)


def _code(value):
    if value is None:
        return 0
    if isinstance(value, int):
        return value & 0xFF
    print(value, file=sys.stderr)
    return 1


_hidden = set()


def _report(error):
    """Print the traceback as python does: from the program's first frame, not this file's."""
    traceback = error.__traceback__
    hidden = {main.__code__.co_filename, *_hidden}
    while traceback is not None and traceback.tb_frame.f_code.co_filename in hidden:
        traceback = traceback.tb_next
    sys.excepthook(type(error), error.with_traceback(traceback), traceback)


def _call(run):
    try:
        run()
        return 0
    except _Exit as exit:
        return _code(exit.code)
    except SystemExit as exit:
        return _code(_pending_exit if _pending_exit is not None else exit.code)
    except KeyboardInterrupt as error:
        _report(error)
        return 130
    except BaseException as error:
        _report(error)
        return 1


def _finish(code):
    """What the interpreter does after the program: join its threads, run atexit, flush."""
    try:
        if 'threading' in sys.modules:
            sys.modules['threading']._shutdown()
    except KeyboardInterrupt:
        code = 130
    except SystemExit as exit:
        code = _code(_pending_exit if _pending_exit is not None else exit.code)
    except BaseException:
        pass
    try:
        import atexit
        atexit._run_exitfuncs()
    except BaseException:
        pass
    if _pending_exit is not None:
        code = _code(_pending_exit)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except BaseException:
            pass
    return code
