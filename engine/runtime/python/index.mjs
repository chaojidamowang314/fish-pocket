// Python for the in-process execution world: CPython embedded in the app
// (native/python), each process a subinterpreter on a thread of its own with
// pipes for its standard streams. This module decides which commands are
// Python, starts them, and gives the engine their streams. On a development
// machine there is no binding and Python is simply not a command.
//
// What runs as Python: `python`, `python3`, `python3.X` (from PATH when a venv
// is active, else the app's), `pip`/`pip3` (a venv's script, else `python -m
// pip`), files whose `#!` line names Python (`#!/usr/bin/env python3`, a venv's
// bin/python), and the console-script launchers boot.py has pip write. boot.py
// mirrors these rules for subprocess.
//
// Inside a shell script just-bash runs any file it finds as bash. So the
// app's python3 (which venvs link to as bin/python) is an sh script handing
// its arguments to the python3 command along with its own path, and pip's
// console scripts are sh launchers (boot.py).
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';
import { fileURLToPath } from 'node:url';
import { simpleWords } from '../direct.mjs';

const VERSION = '3.15';
const PYTHON_NAMES = new Set(['python', 'python3', `python${VERSION}`]);
const PIP_NAMES = new Set(['pip', 'pip3', `pip${VERSION}`]);
const SHELLS = new Set(['sh', 'bash', 'dash', 'zsh']);
/** The app bundle as the engine sees it: this file is in <bundle>/nodejs-project/runtime/python. */
const BUNDLE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const HOME = process.env.HOME || '/home/dsh';
/** sys.prefix outside a venv: pip installs here (bin/, lib/python3.X/site-packages). */
export const PREFIX = `${HOME}/.local`;
/** The app's python3: a placeholder file, so venvs can link to it and PATH lookups find it. */
export const EXECUTABLE = `${PREFIX}/bin/python3`;
const CAFILE = `${HOME}/.cache/fish-pocket/python/cacert.pem`;
/** What the placeholder executable says: run as a script, it is `python3` as itself. */
const STUB = [
  '#!/bin/sh',
  '# Fish Pocket runs Python inside the app. This file gives it a path (venvs link to',
  "# it); run as a script, it hands its arguments to the app's python3 as itself.",
  'DSH_PYTHON_EXECUTABLE="$0" /bin/python3 "$@"',
  '',
].join('\n');
/** The marker line of a console-script launcher (boot.py). */
const ENTRY_MARK = '# dsh-python-entry: ';
const SIGNALS = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGTERM: 15 };
const SIGNAL_NAMES = Object.fromEntries(Object.entries(SIGNALS).map(([name, number]) => [number, name]));
/** How long a process may take to stop when asked before the engine stops waiting for it. */
const KILL_GRACE_MS = 3000;

let cached;

function binding() {
  if (cached !== undefined) return cached;
  cached = null;
  try {
    cached = process._linkedBinding('dsh_python');
  } catch {
    return cached;
  }
  try {
    prepare();
    cached.configure({
      boot: fileURLToPath(new URL('./boot.py', import.meta.url)),
      stdlib: `${BUNDLE}/python/lib/python${VERSION}`,
      executable: EXECUTABLE,
      prefix: PREFIX,
      cafile: CAFILE,
    });
  } catch (error) {
    process.stderr.write(`python: ${error?.message ?? error}\n`);
    cached = null;
  }
  return cached;
}

/** The placeholder executables and the certificate bundle (Node's roots, which ssl then trusts). */
function prepare() {
  const bin = path.dirname(EXECUTABLE);
  fs.mkdirSync(bin, { recursive: true });
  let stub;
  try { stub = fs.readFileSync(EXECUTABLE, 'utf8'); } catch {}
  if (stub !== STUB) fs.writeFileSync(EXECUTABLE, STUB, { mode: 0o755 });
  for (const name of ['python', `python${VERSION}`]) {
    try { fs.symlinkSync('python3', path.join(bin, name)); } catch {}
  }
  const pem = `${tls.rootCertificates.join('\n')}\n`;
  let current;
  try { current = fs.readFileSync(CAFILE, 'utf8'); } catch {}
  if (current !== pem) {
    fs.mkdirSync(path.dirname(CAFILE), { recursive: true });
    fs.writeFileSync(CAFILE, pem);
  }
}

export function pythonAvailable() {
  return binding() !== null;
}

/** Names the shell gets as commands. */
export const PYTHON_COMMANDS = [...PYTHON_NAMES, ...PIP_NAMES];

function isFile(file) {
  try { return fs.statSync(file).isFile(); } catch { return false; }
}

function lookup(program, cwd, env) {
  if (program.includes('/')) return path.resolve(cwd, program);
  for (const dir of (env.PATH ?? '').split(':')) {
    if (!dir) continue;
    const candidate = path.resolve(cwd, dir, program);
    if (isFile(candidate)) return candidate;
  }
  return undefined;
}

function firstLines(file) {
  try {
    const fd = fs.openSync(file, 'r');
    try {
      const buffer = Buffer.alloc(4096);
      return buffer.subarray(0, fs.readSync(fd, buffer, 0, buffer.length, 0)).toString('utf8').split('\n');
    } finally { fs.closeSync(fd); }
  } catch { return ['']; }
}

/** The Python executable a program name stands for: its file on PATH (a venv's), else the app's. */
function interpreter(program, cwd, env) {
  const found = lookup(program, cwd, env);
  return found && isFile(found) ? found : EXECUTABLE;
}

/**
 * Plan argv (or a simple `sh -c` line) as one Python process, if it is one.
 * @returns {{ executable: string, argv: string[], env: object } | undefined}
 */
export function planPython(argv, { cwd, env }) {
  if (!pythonAvailable()) return undefined;
  let words = argv;
  const assignments = {};
  if (SHELLS.has(path.basename(argv[0] ?? ''))) {
    const c = argv.indexOf('-c');
    if (c < 0 || argv[c + 1] === undefined) return undefined;
    words = simpleWords(argv[c + 1]);
    if (words === undefined) return undefined;
  }
  while (words.length > 0 && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) {
    const [key, ...value] = words[0].split('=');
    assignments[key] = value.join('=');
    words = words.slice(1);
  }
  if (words.length === 0) return undefined;
  const runEnv = { ...env, ...assignments };
  const [program, ...args] = words;
  const base = path.basename(program);
  if (PYTHON_NAMES.has(base)) return { executable: interpreter(program, cwd, runEnv), argv: [program, ...args], env: runEnv };
  const file = lookup(program, cwd, runEnv);
  if (!file || !isFile(file)) {
    if (PIP_NAMES.has(base) && !program.includes('/')) return { executable: EXECUTABLE, argv: [program, '-m', 'pip', ...args], env: runEnv };
    return undefined;
  }
  const [line, second = ''] = firstLines(file);
  if (!line.startsWith('#!')) return undefined;
  if (line.trim() === '#!/bin/sh' && second.startsWith(ENTRY_MARK)) {
    let launcher;
    try { launcher = JSON.parse(second.slice(ENTRY_MARK.length)); } catch { return undefined; }
    const executable = isFile(launcher.python) ? launcher.python : EXECUTABLE;
    return { executable, argv: [program, '-c', launcher.code, file, ...args], env: runEnv };
  }
  let shebang = line.slice(2).trim().split(/\s+/);
  let executable;
  if (path.basename(shebang[0] ?? '') === 'env') {
    shebang = shebang.slice(1).filter((word) => word !== '-S');
    if (!PYTHON_NAMES.has(path.basename(shebang[0] ?? ''))) return undefined;
    executable = interpreter(shebang[0], cwd, runEnv);
  } else {
    if (!PYTHON_NAMES.has(path.basename(shebang[0] ?? ''))) return undefined;
    executable = isFile(shebang[0]) ? shebang[0] : EXECUTABLE;
  }
  return { executable, argv: [program, ...shebang.slice(1), file, ...args], env: runEnv };
}

/**
 * Start a planned Python process. Its stdin/stdout/stderr are streams of the
 * pipes it reads and writes; `exited` settles with { code, signal } once it
 * ends (or, after kill, once it has had KILL_GRACE_MS to).
 */
export function startPython({ executable, argv, cwd, env }) {
  const python = binding();
  if (!python) throw new Error('python is not available');
  let settle;
  const exited = new Promise((resolve) => { settle = resolve; });
  let finished = false;
  const ends = python.spawn({
    argv: argv.map(String),
    executable,
    cwd: path.resolve('/', cwd ?? '/'),
    env: Object.entries(env ?? {}).filter(([, value]) => typeof value === 'string').map(([key, value]) => `${key}=${value}`),
  }, (code, signal) => {
    if (finished) return;
    finished = true;
    settle({ code, signal: signal == null ? null : (SIGNAL_NAMES[signal] ?? `SIG${signal}`) });
  });
  const stdin = new net.Socket({ fd: ends.stdin, readable: false, writable: true });
  const stdout = new net.Socket({ fd: ends.stdout, readable: true, writable: false });
  const stderr = new net.Socket({ fd: ends.stderr, readable: true, writable: false });
  // A process that stops reading leaves writes failing with EPIPE: nothing to report.
  stdin.on('error', () => {});
  for (const stream of [stdout, stderr]) stream.on('error', () => {});
  return {
    pid: ends.pid,
    stdin,
    stdout,
    stderr,
    exited,
    kill(signal = 'SIGTERM') {
      if (finished) return false;
      const number = typeof signal === 'number' ? signal : (SIGNALS[signal] ?? SIGNALS.SIGTERM);
      python.kill(ends.pid, number);
      if (number === SIGNALS.SIGINT) return true;
      // A program blocked reading its input wakes up on end of input.
      stdin.destroy();
      // One blocked elsewhere (sleep, a socket) is left to finish on its own.
      setTimeout(() => {
        if (finished) return;
        finished = true;
        stdout.destroy();
        stderr.destroy();
        settle({ code: null, signal: SIGNAL_NAMES[number] ?? `SIG${number}` });
      }, KILL_GRACE_MS).unref();
      return true;
    },
  };
}

/** Wait for both output streams to end (or a moment after exit, as runDirect does). */
export function drained(child) {
  const ends = [child.stdout, child.stderr].map((stream) => new Promise((resolve) => {
    if (stream.readableEnded || stream.destroyed) return resolve();
    stream.once('end', resolve);
    stream.once('close', resolve);
  }));
  return Promise.all(ends);
}

/**
 * Python as just-bash commands. Inside a shell script the interpreter takes a
 * command's output when it exits, so this collects it; a top-level `python3 …`
 * goes through planPython instead and streams.
 */
export function pythonCommands(defineCommand, decode) {
  return PYTHON_COMMANDS.map((name) => defineCommand(name, async (args, ctx) => {
    const cwd = path.resolve('/', ctx.cwd);
    const env = { ...Object.fromEntries(ctx.env), ...ctx.exportedEnv };
    // From a placeholder executable (a venv's bin/python): Python as that file.
    const as = env.DSH_PYTHON_EXECUTABLE;
    delete env.DSH_PYTHON_EXECUTABLE;
    const plan = as ? { executable: path.resolve(cwd, as), argv: [as, ...args], env } : planPython([name, ...args], { cwd, env });
    if (!plan) return { stdout: '', stderr: `${name}: command not found\n`, exitCode: 127 };
    const child = startPython({ ...plan, cwd });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
    child.stdin.end(decode(ctx.stdin ?? ''));
    const stop = () => child.kill('SIGTERM');
    ctx.signal?.addEventListener('abort', stop, { once: true });
    const { code, signal } = await child.exited;
    await Promise.race([drained(child), new Promise((resolve) => setTimeout(resolve, 100))]);
    ctx.signal?.removeEventListener('abort', stop);
    return { stdout, stderr, exitCode: signal ? 128 + (SIGNALS[signal] ?? 15) : code };
  }));
}
