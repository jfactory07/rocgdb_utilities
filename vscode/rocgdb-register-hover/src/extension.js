/* eslint-disable no-control-regex */
const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');

/**
 * Minimal GDB/MI client for rocgdb.
 * We only need:
 *  - spawn rocgdb --interpreter=mi2
 *  - run console commands via -interpreter-exec console "..."
 *  - collect ~"console output" and wait for token^done / token^error
 */
class RocgdbMiClient {
  constructor(outputChannel, logger) {
    this.outputChannel = outputChannel;
    this.logger = logger;
    this.proc = null;
    this.buf = '';
    this.token = 1;
    this.pending = new Map(); // token -> {resolve,reject,lines,timeout}
    this.queue = Promise.resolve(); // serialize commands
  }

  isRunning() {
    return !!this.proc && !this.proc.killed;
  }

  async start() {
    if (this.isRunning()) return;

    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const rocgdbPath = cfg.get('rocgdbPath');
    const rocgdbArgs = cfg.get('rocgdbArgs') || [];

    const args = ['--interpreter=mi2', '-q', ...rocgdbArgs];
    this.outputChannel.appendLine(`[rocgdbHover] starting: ${rocgdbPath} ${args.join(' ')}`);
    this.logger.info(`spawn.start rocgdbPath=${rocgdbPath} args=${JSON.stringify(args)}`);

    const proc = cp.spawn(rocgdbPath, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    this.proc = proc;

    proc.stdout.setEncoding('utf8');
    proc.stderr.setEncoding('utf8');

    proc.stdout.on('data', (d) => this._onData(d));
    proc.stderr.on('data', (d) => this._onData(d)); // MI sometimes writes to stderr too

    proc.on('exit', (code, sig) => {
      this.outputChannel.appendLine(`[rocgdbHover] rocgdb exited: code=${code} sig=${sig}`);
      this.logger.error(`spawn.exit code=${code} sig=${sig}`);
      for (const [t, p] of this.pending.entries()) {
        clearTimeout(p.timeout);
        p.reject(new Error(`rocgdb exited while waiting for token ${t}`));
      }
      this.pending.clear();
      this.proc = null;
      this.buf = '';
    });

    // Basic init: rocgdb may emit async records; we don't need to wait for them.
    // Run configured startup commands.
    const startup = cfg.get('startupCommands') || [];
    for (const cmd of startup) {
      if (typeof cmd === 'string' && cmd.trim()) {
        await this.runConsole(cmd.trim());
      }
    }
  }

  async stop() {
    if (!this.isRunning()) return;
    this.logger.info('spawn.stop');
    try {
      // Ask gdb to exit nicely, then kill if still alive.
      await this._sendMiRaw('-gdb-exit', 300);
    } catch {
      // ignore
    }
    try {
      this.proc.kill('SIGTERM');
    } catch {
      // ignore
    }
    this.proc = null;
  }

  async runConsole(command, timeoutMs) {
    this.logger.debug(`spawn.runConsole cmd=${command}`);
    const cmd = `-interpreter-exec console "${miEscape(command)}"`;
    const out = await this._sendMiRaw(cmd, timeoutMs);
    return out.consoleText;
  }

  async _sendMiRaw(miCommand, timeoutMs) {
    if (!this.isRunning()) throw new Error('rocgdb not running');

    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const timeout = timeoutMs ?? cfg.get('hoverTimeoutMs') ?? 800;

    // Serialize to keep parsing simple.
    this.queue = this.queue.then(() => this.__sendMiRawSerialized(miCommand, timeout));
    return this.queue;
  }

  __sendMiRawSerialized(miCommand, timeoutMs) {
    return new Promise((resolve, reject) => {
      const t = this.token++;
      const line = `${t}${miCommand}\n`;
      const pending = {
        resolve,
        reject,
        consoleChunks: [],
        timeout: setTimeout(() => {
          this.pending.delete(t);
          reject(new Error(`rocgdb timeout after ${timeoutMs}ms for: ${miCommand}`));
        }, timeoutMs)
      };
      this.pending.set(t, pending);
      this.proc.stdin.write(line);
    });
  }

  _onData(chunk) {
    this.buf += chunk;
    let idx;
    while ((idx = this.buf.indexOf('\n')) !== -1) {
      const rawLine = this.buf.slice(0, idx);
      this.buf = this.buf.slice(idx + 1);
      const line = rawLine.replace(/\r$/, '');
      this._handleMiLine(line);
    }
  }

  _handleMiLine(line) {
    // console stream: ~"...."
    if (line.startsWith('~"')) {
      const s = parseMiCString(line.slice(1)); // keep leading quote for parser
      // console streams are not token-tagged; we attach to the most recent pending token.
      const lastToken = Math.max(0, ...this.pending.keys());
      if (lastToken && this.pending.has(lastToken)) {
        this.pending.get(lastToken).consoleChunks.push(s);
      }
      return;
    }

    // result record: <token>^done / <token>^error
    const m = line.match(/^(\d+)\^(done|error)(.*)$/);
    if (m) {
      const t = Number(m[1]);
      const status = m[2];
      const pending = this.pending.get(t);
      if (!pending) return;
      clearTimeout(pending.timeout);
      this.pending.delete(t);
      const consoleText = pending.consoleChunks.join('');
      if (status === 'done') {
        pending.resolve({ consoleText });
      } else {
        pending.reject(new Error(`rocgdb MI error for token ${t}: ${m[3]}\n${consoleText}`));
      }
      return;
    }
  }
}

class FileLogger {
  constructor(outputChannel) {
    this.outputChannel = outputChannel;
  }

  _cfg() {
    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const logFile = cfg.get('logFile') || '';
    const logLevel = cfg.get('logLevel') || 'info';
    return { logFile, logLevel };
  }

  _should(level) {
    const order = { error: 0, info: 1, debug: 2 };
    const { logLevel } = this._cfg();
    return (order[level] ?? 1) <= (order[logLevel] ?? 1);
  }

  _write(level, msg) {
    if (!this._should(level)) return;
    const { logFile } = this._cfg();
    const line = `${new Date().toISOString()} [${level}] ${msg}\n`;
    if (!logFile) return;
    try {
      fs.appendFileSync(logFile, line, { encoding: 'utf8' });
    } catch (e) {
      // Don't throw; just echo once to output to avoid spam.
      this.outputChannel.appendLine(`[rocgdbHover] failed writing logFile: ${String(e && e.message ? e.message : e)}`);
    }
  }

  error(msg) { this._write('error', msg); }
  info(msg) { this._write('info', msg); }
  debug(msg) { this._write('debug', msg); }
}

/**
 * Backend that reuses VS Code's active debug session (cppdbg) instead of spawning rocgdb.
 * This depends on the debug adapter accepting at least one of:
 *  - customRequest("executeCommand", { command })
 *  - customRequest("evaluate", { expression: command, context: "repl" })
 *
 * For cppdbg, users typically run rocgdb by setting launch.json:
 *   "MIMode": "gdb",
 *   "miDebuggerPath": "/opt/rocm/bin/rocgdb"
 */
class ActiveCppdbgBackend {
  constructor(outputChannel, logger) {
    this.outputChannel = outputChannel;
    this.logger = logger;
    // NOTE: Older versions attempted to "probe" every DAP thread by running
    // `info lanes` until a GPU lane table appeared, then used that frameId.
    // On real-world stops with many threads this caused a storm of evaluate()
    // requests and frequent timeouts. We now avoid probing and (by default)
    // avoid passing frameId for `-exec` commands so thread/lane selection can stick.
  }

  _session() {
    return vscode.debug.activeDebugSession || null;
  }

  isRunning() {
    const s = this._session();
    return !!s && s.type === 'cppdbg';
  }

  async start() {
    // no-op: driven by user starting cppdbg session
  }

  async stop() {
    // no-op: we don't own the session
  }

  async runConsole(command, timeoutMs) {
    const s = this._session();
    if (!s || s.type !== 'cppdbg') throw new Error('No active cppdbg debug session');

    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const timeout = timeoutMs ?? cfg.get('hoverTimeoutMs') ?? 800;

    // Wrap in a timeout because customRequest may hang depending on adapter state.
    this.logger.debug(`cppdbg.runConsole type=${s.type} name=${s.name} cmd=${command}`);
    return await promiseWithTimeout(this._tryRunConsole(s, command), timeout, `cppdbg timeout after ${timeout}ms for: ${command}`);
  }

  async _tryRunConsole(session, command) {
    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const transport = cfg.get('cppdbgTransport') || 'auto';

    const wrapExec = (cmd) => {
      // For MIEngine-based adapters, debug console commonly expects "-exec <gdb command>"
      // to run a CLI command. Without it, the adapter may try to -var-create it.
      const c = String(cmd || '').trim();
      if (!c) return c;
      if (c.startsWith('-')) return c;
      return `-exec ${c}`;
    };

    const shouldPassFrameId = (expression) => {
      // For `-exec <gdb-cli>` we intentionally do NOT pass frameId:
      // - passing frameId can force MIEngine to re-select a CPU frame on every call,
      //   undoing `thread <id>` / `lane <id>` commands between calls.
      // - most adapters accept evaluate(repl) without frameId for `-exec` commands.
      //
      // If a particular adapter requires a frameId, we will retry with a best-effort one.
      const x = String(expression || '').trim();
      if (!x) return false;
      if (x.startsWith('-exec ')) return false;
      return true;
    };

    const pickAnyFrameId = async () => {
      try {
        const threads = await session.customRequest('threads', {});
        const list = threads && threads.threads;
        if (!Array.isArray(list) || list.length === 0) return null;
        const t0 = list.find((t) => t && t.id != null) || list[0];
        if (!t0 || t0.id == null) return null;
        const st = await session.customRequest('stackTrace', { threadId: t0.id, startFrame: 0, levels: 1 });
        const frames = st && st.stackFrames;
        if (!Array.isArray(frames) || frames.length === 0) return null;
        const fid = frames[0].id;
        return (typeof fid === 'number') ? fid : null;
      } catch {
        return null;
      }
    };

    const isFrameIdLikelyRequiredError = (e) => {
      const msg = String(e && e.message ? e.message : e || '');
      return (
        /frameId/i.test(msg) ||
        /stack frame/i.test(msg) ||
        /specified stack frame/i.test(msg)
      );
    };

    const evalRepl = async () => {
      const expression = wrapExec(command);
      const baseArgs = { expression, context: 'repl' };
      try {
        const r = await session.customRequest('evaluate', baseArgs);
        this.logger.debug(`cppdbg.evaluate(repl) expr=${expression} resp=${toPrintableString(r)}`);
        const out = normalizeDebugAdapterOutput(r);
        if (looksLikeVarCreateFailure(out)) throw new Error(out);
        return out;
      } catch (e) {
        // Retry with a best-effort frameId only if it looks required.
        if (!shouldPassFrameId(expression) && !isFrameIdLikelyRequiredError(e)) throw e;
        const fid = await pickAnyFrameId();
        if (fid == null) throw e;
        const args = { ...baseArgs, frameId: fid };
        const r2 = await session.customRequest('evaluate', args);
        this.logger.debug(`cppdbg.evaluate(repl,frameId) frameId=${fid} expr=${expression} resp=${toPrintableString(r2)}`);
        const out2 = normalizeDebugAdapterOutput(r2);
        if (looksLikeVarCreateFailure(out2)) throw new Error(out2);
        return out2;
      }
    };

    const evalMi = async () => {
      // In practice, many cppdbg MIEngine builds accept "-exec <gdb-cli>" (same as evalRepl).
      // Keep the setting name but use the safer/working path here.
      const expression = wrapExec(command);
      const baseArgs = { expression, context: 'repl' };
      try {
        const r = await session.customRequest('evaluate', baseArgs);
        this.logger.debug(`cppdbg.evaluate(mi) expr=${expression} resp=${toPrintableString(r)}`);
        const out = normalizeDebugAdapterOutput(r);
        if (looksLikeVarCreateFailure(out)) throw new Error(out);
        return out;
      } catch (e) {
        if (!shouldPassFrameId(expression) && !isFrameIdLikelyRequiredError(e)) throw e;
        const fid = await pickAnyFrameId();
        if (fid == null) throw e;
        const args = { ...baseArgs, frameId: fid };
        const r2 = await session.customRequest('evaluate', args);
        this.logger.debug(`cppdbg.evaluate(mi,frameId) frameId=${fid} expr=${expression} resp=${toPrintableString(r2)}`);
        const out2 = normalizeDebugAdapterOutput(r2);
        if (looksLikeVarCreateFailure(out2)) throw new Error(out2);
        return out2;
      }
    };

    const execCmd = async () => {
      // WARNING: some adapters crash on unknown requests. Only use if user explicitly enables it.
      const r = await session.customRequest('executeCommand', { command });
      this.logger.debug(`cppdbg.executeCommand resp=${toPrintableString(r)}`);
      return normalizeDebugAdapterOutput(r);
    };

    // Safe defaults: never send executeCommand unless explicitly selected.
    if (transport === 'evaluateRepl') {
      return await evalRepl();
    }
    if (transport === 'evaluateMi') {
      return await evalMi();
    }
    if (transport === 'executeCommand') {
      return await execCmd();
    }

    // auto: try evaluate(repl) then evaluate(mi)
    try {
      const out1 = await evalRepl();
      if (out1) return out1;
    } catch (e) {
      this.outputChannel.appendLine(`[rocgdbHover] evaluate(repl) failed: ${String(e && e.message ? e.message : e)}`);
      this.logger.info(`cppdbg.evaluate(repl) failed: ${String(e && e.message ? e.message : e)}`);
    }
    try {
      const out2 = await evalMi();
      if (out2) return out2;
      return out2;
    } catch (e) {
      this.outputChannel.appendLine(`[rocgdbHover] evaluate(mi) failed: ${String(e && e.message ? e.message : e)}`);
      this.logger.info(`cppdbg.evaluate(mi) failed: ${String(e && e.message ? e.message : e)}`);
    }

    throw new Error('Active cppdbg session did not accept debugger commands via evaluate(). Consider rocgdbHover.backend=spawnRocgdb or adjust rocgdbHover.cppdbgTransport.');
  }
}

function miEscape(s) {
  // Escape for MI "..." string
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"');
}

function toPrintableString(x) {
  if (x == null) return '';
  if (typeof x === 'string') return x;
  if (typeof x === 'number' || typeof x === 'boolean' || typeof x === 'bigint') return String(x);
  try {
    return JSON.stringify(x);
  } catch {
    try {
      return String(x);
    } catch {
      return '[unprintable]';
    }
  }
}

function normalizeDebugAdapterOutput(r) {
  if (r == null) return '';
  if (typeof r === 'string') return r;
  if (typeof r.output === 'string') return r.output;
  if (typeof r.result === 'string') return r.result;
  if (typeof r.value === 'string') return r.value;
  if (r.body) {
    if (typeof r.body.output === 'string') return r.body.output;
    if (typeof r.body.result === 'string') return r.body.result;
    if (typeof r.body.value === 'string') return r.body.value;
  }
  return toPrintableString(r);
}

function looksLikeVarCreateFailure(s) {
  const t = String(s || '');
  return t.includes('-var-create:') || t.includes('unable to create variable object');
}

function parseMiCString(miQuoted) {
  // Input like: "\"text\\n\"" (including surrounding quotes)
  // We receive line.slice(1) from ~"...", so miQuoted starts with a quote.
  let s = miQuoted;
  if (s.startsWith('"') && s.endsWith('"')) s = s.slice(1, -1);
  // Unescape common sequences.
  s = s
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\r')
    .replace(/\\t/g, '\t')
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, '\\');
  return s;
}

function promiseWithTimeout(p, timeoutMs, msg) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(msg)), timeoutMs);
    Promise.resolve(p).then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e) => {
        clearTimeout(t);
        reject(e);
      }
    );
  });
}

function logDebug(client, msg) {
  try {
    if (client && client.logger && typeof client.logger.debug === 'function') client.logger.debug(msg);
  } catch {
    // ignore
  }
}

function logInfo(client, msg) {
  try {
    if (client && client.logger && typeof client.logger.info === 'function') client.logger.info(msg);
  } catch {
    // ignore
  }
}

function isAsmLikeDocument(document) {
  const p = (document.uri && document.uri.fsPath) || '';
  return /\.s$/i.test(p) || /\.S$/i.test(p);
}

// Cache parsed ".set/.equ" symbols per document version.
// key = `${fsPath}:${version}` -> Map<string, number>
const asmSymbolCache = new Map();

function stripAsmComments(line) {
  // Good-enough stripping for Tensile/AMDGPU asm:
  // - line comments commonly use '//' (Tensile) or '#'
  // We avoid being too clever here; this is for parsing .set/.equ lines.
  const s = String(line || '');
  const cut = Math.min(
    ...[s.indexOf('//'), s.indexOf('#')].filter((x) => x >= 0)
  );
  return cut === Infinity ? s : s.slice(0, cut);
}

function parseAsmImmediate(s) {
  const t = String(s || '').trim();
  if (!t) return null;
  try {
    if (/^[+-]?0x[0-9a-fA-F]+$/.test(t)) return Number(BigInt(t));
    if (/^[+-]?\d+$/.test(t)) return Number(BigInt(t));
  } catch {
    return null;
  }
  return null;
}

function buildAsmSymbolTable(document) {
  const table = new Map();
  const lineCount = document.lineCount || 0;
  for (let i = 0; i < lineCount; i++) {
    const raw = document.lineAt(i).text;
    const line = stripAsmComments(raw).trim();
    if (!line) continue;

    // Match:
    //   .set name, 54
    //   .equ name, 54
    //   name = 54
    let m = line.match(/^\s*\.(?:set|equ|equiv)\s+([A-Za-z_]\w*)\s*,\s*([+-]?(?:0x[0-9a-fA-F]+|\d+))\b/);
    if (!m) {
      m = line.match(/^\s*([A-Za-z_]\w*)\s*=\s*([+-]?(?:0x[0-9a-fA-F]+|\d+))\b/);
    }
    if (!m) continue;

    const name = m[1];
    const imm = parseAsmImmediate(m[2]);
    if (name && imm != null && Number.isFinite(imm)) {
      table.set(name, imm);
    }
  }
  return table;
}

function getAsmSymbolTable(document) {
  const fsPath = (document.uri && document.uri.fsPath) || '';
  const v = typeof document.version === 'number' ? document.version : 0;
  const key = `${fsPath}:${v}`;
  const cached = asmSymbolCache.get(key);
  if (cached) return cached;
  const table = buildAsmSymbolTable(document);
  asmSymbolCache.set(key, table);
  // best-effort: keep cache bounded (avoid leaking across many generated asm files)
  if (asmSymbolCache.size > 64) {
    const firstKey = asmSymbolCache.keys().next().value;
    if (firstKey) asmSymbolCache.delete(firstKey);
  }
  return table;
}

function resolveAsmSymbolOrNumber(document, token) {
  const t = String(token || '').trim();
  if (!t) return null;
  const imm = parseAsmImmediate(t);
  if (imm != null) return imm;
  const table = getAsmSymbolTable(document);
  const v = table.get(t);
  return (typeof v === 'number' && Number.isFinite(v)) ? v : null;
}

function extractRegisterAt(document, position) {
  const line = document.lineAt(position.line).text;
  const col = position.character;

  // Expand around cursor to catch e.g. "v0", "s13", "v[0:3]", "s[sgprFoo]" (named regs)
  const left = Math.max(0, col - 32);
  const right = Math.min(line.length, col + 32);
  const window = line.slice(left, right);
  const cursorInWindow = col - left;

  // Find nearest match that contains cursor.
  // Support:
  //  - s13 / v0
  //  - s[74:75] / v[0:3] (range)
  //  - s[sgprFoo] / v[vgprBar] (symbolic index)
  //  - s[sgprA:sgprB] / v[vgprA:vgprB] (symbolic range)
  const patterns = [
    // IMPORTANT: avoid regex lookbehind (older extension hosts may not support it).
    // Also avoid trailing \b for bracketed forms (`]` is not a word char, so `s[foo],` must match).
    { type: 'rangeSym', re: /\b([sv])\[(\w+):(\w+)\]/g },
    { type: 'range', re: /\b([sv])\[(\d+):(\d+)\]/g },
    { type: 'singleSym', re: /\b([sv])\[(\w+)\]/g },
    { type: 'single', re: /\b([sv])(\d+)\b/g }
  ];

  for (const p of patterns) {
    let m;
    while ((m = p.re.exec(window)) !== null) {
      const start = m.index;
      const end = start + m[0].length;
      if (cursorInWindow >= start && cursorInWindow <= end) {
        const kind = m[1] === 's' ? 'sgpr' : 'vgpr';
        if (p.type === 'single') {
          const name = `${m[1]}${m[2]}`;
          return { kind, name, names: [name], raw: m[0] };
        }
        if (p.type === 'singleSym') {
          const idx = resolveAsmSymbolOrNumber(document, m[2]);
          if (idx == null) {
            return { kind, name: m[0], names: [], raw: m[0], unresolvedSymbols: [m[2]] };
          }
          const name = `${m[1]}${idx}`;
          return { kind, name, names: [name], raw: m[0], resolvedFrom: m[2] };
        }

        // range / rangeSym
        const a = (p.type === 'rangeSym') ? resolveAsmSymbolOrNumber(document, m[2]) : Number(m[2]);
        const b = (p.type === 'rangeSym') ? resolveAsmSymbolOrNumber(document, m[3]) : Number(m[3]);
        if (!Number.isFinite(a) || !Number.isFinite(b)) {
          const unresolved = [];
          if (p.type === 'rangeSym') {
            if (!Number.isFinite(a)) unresolved.push(m[2]);
            if (!Number.isFinite(b)) unresolved.push(m[3]);
          }
          return { kind, name: m[0], names: [], raw: m[0], unresolvedSymbols: unresolved };
        }
        const lo = Math.min(a, b);
        const hi = Math.max(a, b);
        const names = [];
        for (let i = lo; i <= hi; i++) names.push(`${m[1]}${i}`);
        const title = `${m[1]}[${lo}:${hi}]`;
        return { kind, name: title, names, range: { lo, hi }, raw: m[0] };
      }
    }
  }
  return null;
}

function parseInfoRegistersValue(output, regName) {
  // Typical: "v0  0x0000000000000000\n" or "s13  123\n"
  const o = String(output || '');
  if (o.includes('Invalid register')) return null;
  const lines = output.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const l of lines) {
    // Some builds align columns; reg name is first token.
    const parts = l.split(/\s+/);
    if (parts.length >= 2 && parts[0] === regName) {
      return parts[parts.length - 1];
    }
  }
  return null;
}

function parseInfoRegistersVector(output, regName) {
  // rocgdb may print VGPR vectors as:
  //   v17            {0x0, 0x100, ..., 0xc0f00}
  // Return array of per-lane values, or null if not a vector.
  const s = String(output || '');
  if (!s.trim()) return null;
  if (s.includes('Invalid register')) return null;
  const re = new RegExp(`\\b${regName.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')}\\b\\s*\\{([^}]*)\\}`, 'm');
  const m = s.match(re);
  if (!m) return null;
  const body = (m[1] || '').trim();
  if (!body) return [];
  return body
    .split(',')
    .map((x) => x.trim())
    .filter(Boolean);
}

function parsePrintValue(output) {
  // Examples:
  //  "$1 = 0x00000001"
  //  "$2 = 123"
  //  "Invalid register `s75'"
  const s = String(output || '').trim();
  if (!s) return null;
  if (/Invalid register/i.test(s)) return null;
  const lines = s.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const l of lines) {
    const m = l.match(/=\s*(.+)\s*$/);
    if (m) {
      const v = m[1].trim();
      // Treat "void" as "no value" so we keep trying other register name variants.
      if (/^\(?void\)?$/i.test(v)) return null;
      return v;
    }
  }
  // fallback: last token of last non-empty line
  const last = lines[lines.length - 1] || '';
  const parts = last.split(/\s+/);
  const v = parts[parts.length - 1] || null;
  if (v && /^\(?void\)?$/i.test(v)) return null;
  return v;
}

async function tryReadRegisterViaPrint(client, regName) {
  // Try common naming variants. Some rocgdb builds accept $s75/$v0,
  // others may expose $sgpr75/$vgpr0.
  const variants = [];
  if (/^[sv]\d+$/.test(regName)) {
    variants.push(`$${regName}`); // $s75 / $v0
    if (regName[0] === 's') variants.push(`$sgpr${regName.slice(1)}`);
    if (regName[0] === 'v') variants.push(`$vgpr${regName.slice(1)}`);
  } else {
    variants.push(`$${regName}`);
  }

  for (const v of variants) {
    const out = await client.runConsole(`p/x ${v}`);
    if (looksLikeCppdbgExpressionFailure(out)) {
      throw new Error('cppdbg cannot execute debugger console commands via evaluate(). Set rocgdbHover.backend=spawnRocgdb (recommended).');
    }
    const val = parsePrintValue(out);
    if (val != null) return val;
  }
  return null;
}

function looksLikeCppdbgExpressionFailure(output) {
  const s = String(output || '');
  return (
    s.includes('Cannot evaluate expression on the specified stack frame') ||
    s.includes('-var-create: unable to create variable object') ||
    s.includes('unable to create variable object')
  );
}

async function runContextCommands(client) {
  const cfg = vscode.workspace.getConfiguration('rocgdbHover');
  const cmds = cfg.get('contextCommands') || [];
  for (const cmd of cmds) {
    if (typeof cmd === 'string' && cmd.trim()) {
      await client.runConsole(cmd.trim());
    }
  }
}

function parseInfoThreads(output) {
  const lines = String(output || '').split('\n');
  const threads = [];
  let current = null;

  for (const raw of lines) {
    const l = raw.trimEnd();
    if (!l.trim()) continue;
    // Skip common headers
    if (/^\s*Id\s+Target\s+Id\s+Frame/i.test(l)) continue;
    // Common GDB format:
    // "* 3 Thread 0x... (LWP ...)  ..."
    // "  2 Thread 0x... ..."
    // rocgdb heterogeneous threads may not include the literal word "Thread" (e.g. "Agent", "Queue", etc).
    // Be permissive: parse any line that starts with an optional '*' + numeric id.
    const m = l.match(/^\s*(\*)?\s*(\d+)\s+(.*)$/);
    if (!m) continue;
    const isCurrent = !!m[1];
    const id = Number(m[2]);
    const rest = (m[3] || '').trim();
    if (!Number.isFinite(id)) continue;
    const t = { id, isCurrent, text: rest, raw: l };
    threads.push(t);
    if (isCurrent) current = t;
  }
  return { threads, current };
}

function scoreGpuThread(text, gpuRegex) {
  const s = String(text || '');
  try {
    const re = new RegExp(gpuRegex, 'i');
    return re.test(s) ? 100 : 0;
  } catch {
    // fallback keywords
    const n = s.toLowerCase();
    if (n.includes('gpu') || n.includes('amdgpu') || n.includes('hsa') || n.includes('dispatch') || n.includes('queue') || n.includes('wave') || n.includes('lane')) return 100;
    return 0;
  }
}

async function tryAutoSelectGpuThread(client) {
  const cfg = vscode.workspace.getConfiguration('rocgdbHover');
  const enabled = cfg.get('autoSelectGpuThread');
  if (!enabled) return { switched: false, threadsOutput: '' };

  let threadsOutput = '';
  try {
    threadsOutput = await client.runConsole('info threads');
  } catch {
    return { switched: false, threadsOutput: '' };
  }

  const gpuRegex = cfg.get('gpuThreadRegex') || '(gpu|amdgpu|hsa|dispatch|queue|wave|lane)';
  const { threads, current } = parseInfoThreads(threadsOutput);
  if (!threads.length) return { switched: false, threadsOutput };

  // Pick best GPU-looking thread by score; if tie, keep current.
  let best = current || threads[0];
  let bestScore = scoreGpuThread(best.raw, gpuRegex);
  for (const t of threads) {
    const s = scoreGpuThread(t.raw, gpuRegex);
    if (s > bestScore) {
      best = t;
      bestScore = s;
    }
  }

  if (!best || bestScore <= 0) {
    logInfo(client, `autoSelectGpuThread: no GPU-like thread matched regex=${gpuRegex}`);
    return { switched: false, threadsOutput };
  }

  if (current && best.id === current.id) {
    logDebug(client, `autoSelectGpuThread: already on candidate thread ${best.id}`);
    return { switched: false, threadsOutput };
  }

  logInfo(client, `autoSelectGpuThread: switching thread ${current ? current.id : 'unknown'} -> ${best.id} (score=${bestScore})`);
  await client.runConsole(`thread ${best.id}`);
  return { switched: true, threadsOutput };
}

function parseInfoLanes(output) {
  // Heuristics because the exact format can vary.
  // Accept:
  // - "Lane 0 ..." / "lane 0 ..."
  // - lines starting with lane id: "0  ..."
  const lanes = [];
  const lines = String(output || '').split('\n');
  for (const raw of lines) {
    const l = raw.trim();
    if (!l) continue;
    // Some rocgdb contexts return an error line like:
    // "Lane 0 does not exist on this thread."
    // Treat those as "no lanes".
    if (/does not exist on this thread/i.test(l)) continue;
    if (/no lanes?/i.test(l)) continue;
    let m = l.match(/^(?:Lane|lane)\s+(\d+)\b/);
    if (m) {
      lanes.push(Number(m[1]));
      continue;
    }
    m = l.match(/^(\d+)\b/);
    if (m) {
      lanes.push(Number(m[1]));
    }
  }
  return Array.from(new Set(lanes.filter((n) => Number.isFinite(n)))).sort((a, b) => a - b);
}

async function getLaneIdsOrExplain(client) {
  // Returns { lanes, raw } where lanes is [] if none.
  let raw = '';
  try {
    raw = await client.runConsole('info lanes -all');
  } catch {
    try {
      raw = await client.runConsole('info lanes -active');
    } catch {
      raw = await client.runConsole('info lanes');
    }
  }
  return { lanes: parseInfoLanes(raw), raw };
}

async function ensureLaneSelected(client, preferLane) {
  let { lanes, raw } = await getLaneIdsOrExplain(client);
  let threadsOutput = '';

  if (!lanes.length) {
    // Try one automatic thread switch (GPU thread) then retry info lanes.
    const sw = await tryAutoSelectGpuThread(client);
    threadsOutput = sw.threadsOutput || '';
    if (sw.switched) {
      const retry = await getLaneIdsOrExplain(client);
      lanes = retry.lanes;
      raw = retry.raw;
    }
  }

  if (!lanes.length) {
    if (!threadsOutput) {
      try {
        threadsOutput = await client.runConsole('info threads');
      } catch {
        // ignore
      }
    }
    const msg =
      'No GPU lanes are available in the current debugger context.\n' +
      'Even if you see a GPU thread in the console, the debugger may still be on a CPU thread.\n' +
      'Try switching to the GPU thread/dispatch in rocgdb, or add rocgdbHover.contextCommands (e.g. thread/agent/queue/dispatch selection).\n' +
      '\ninfo lanes:\n' + String(raw).slice(0, 1200) +
      (threadsOutput ? '\n\ninfo threads:\n' + String(threadsOutput).slice(0, 1200) : '');
    throw new Error(msg);
  }
  const lane = lanes.includes(preferLane) ? preferLane : lanes[0];
  let out = await client.runConsole(`lane ${lane}`);
  if (/does not exist/i.test(out)) {
    // Try to recover by auto-switching thread once and retry lane selection.
    const sw = await tryAutoSelectGpuThread(client);
    if (sw.switched) {
      out = await client.runConsole(`lane ${lane}`);
      if (!/does not exist/i.test(out)) return { lane, lanes };
    }
    let threads = sw.threadsOutput || '';
    if (!threads) {
      try {
        threads = await client.runConsole('info threads');
      } catch {
        // ignore
      }
    }
    const msg =
      'No GPU lanes are available in the current debugger context (lane selection failed).\n' +
      'This usually means you are stopped in a CPU thread, not in a GPU dispatch/thread.\n' +
      'Switch to the GPU thread/dispatch in rocgdb, or add rocgdbHover.contextCommands to select it.\n' +
      `\nlane ${lane}:\n` + String(out).slice(0, 1200) +
      '\n\ninfo lanes:\n' + String(raw).slice(0, 1200) +
      (threads ? '\n\ninfo threads:\n' + String(threads).slice(0, 1200) : '');
    throw new Error(msg);
  }
  return { lane, lanes };
}

async function readSgpr(client, regName) {
  const cfg = vscode.workspace.getConfiguration('rocgdbHover');
  const lane = cfg.get('sgprLane') ?? 0;
  await runContextCommands(client);
  await ensureLaneSelected(client, lane);
  // Prefer "info registers": it tends to return a stable "s75 0x...." format.
  // If not supported, fall back to printing $s75/$sgpr75...
  const out = await client.runConsole(`info registers ${regName}`);
  if (looksLikeCppdbgExpressionFailure(out)) {
    throw new Error('cppdbg cannot execute debugger console commands via evaluate(). Set rocgdbHover.backend=spawnRocgdb (recommended).');
  }
  const vInfo = parseInfoRegistersValue(out, regName);
  if (vInfo != null) return vInfo;

  const vPrint = await tryReadRegisterViaPrint(client, regName);
  if (vPrint != null) return vPrint;

  if (/Invalid register/i.test(out)) {
    throw new Error(`Register ${regName} is not valid in the current context.\n\n${out}`);
  }
  return null;
}

async function readSgprMany(client, regNames) {
  const vals = [];
  for (const r of regNames) {
    // Keep per-reg requests; SGPR ranges are usually small (often 2).
    // If this becomes a perf issue we can batch with "info registers s74 s75 ..." later.
    vals.push(await readSgpr(client, r));
  }
  return vals;
}

function tryCombineSgprPair(loVal, hiVal) {
  // SGPRs are 32-bit. If both parse as hex/dec 32-bit, combine into 64-bit.
  const lo = parseUint32(loVal);
  const hi = parseUint32(hiVal);
  if (lo == null || hi == null) return null;
  const x = (BigInt(hi) << 32n) | BigInt(lo);
  return `0x${x.toString(16).padStart(16, '0')}`;
}

function parseUint32(v) {
  if (v == null) return null;
  const s = String(v).trim();
  try {
    if (/^0x[0-9a-fA-F]+$/.test(s)) {
      const n = BigInt(s);
      if (n < 0n || n > 0xffffffffn) return null;
      return Number(n);
    }
    if (/^\d+$/.test(s)) {
      const n = BigInt(s);
      if (n < 0n || n > 0xffffffffn) return null;
      return Number(n);
    }
  } catch {
    return null;
  }
  return null;
}

async function readVgpr(client, regName) {
  const cfg = vscode.workspace.getConfiguration('rocgdbHover');
  const laneCount = cfg.get('laneCount') ?? 64;
  await runContextCommands(client);

  // Prefer "info registers": rocgdb can return either a scalar (single lane)
  // or a vector of all lanes for VGPR.
  const out = await client.runConsole(`info registers ${regName}`);
  if (looksLikeCppdbgExpressionFailure(out)) {
    throw new Error('cppdbg cannot execute debugger console commands via evaluate(). Set rocgdbHover.backend=spawnRocgdb (recommended).');
  }
  const vec = parseInfoRegistersVector(out, regName);
  if (Array.isArray(vec)) {
    const values = vec.slice(0, laneCount);
    return { kind: 'vector', values };
  }
  const vInfo = parseInfoRegistersValue(out, regName);
  if (vInfo != null) return { kind: 'scalar', value: vInfo };

  const vPrint = await tryReadRegisterViaPrint(client, regName);
  if (vPrint != null) return { kind: 'scalar', value: vPrint };

  if (/Invalid register/i.test(out)) {
    throw new Error(`Register ${regName} is not valid in the current context.\n\n${out}`);
  }
  return { kind: 'scalar', value: null };
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  const output = vscode.window.createOutputChannel('rocgdb Register Hover');
  const logger = new FileLogger(output);
  logger.info('activate');

  const spawnClient = new RocgdbMiClient(output, logger);
  const activeBackend = new ActiveCppdbgBackend(output, logger);

  const getBackend = () => {
    const cfg = vscode.workspace.getConfiguration('rocgdbHover');
    const backend = cfg.get('backend') || 'auto';
    if (backend === 'activeCppdbg') return activeBackend;
    if (backend === 'spawnRocgdb') return spawnClient;
    // auto: prefer active cppdbg session, else spawn
    if (activeBackend.isRunning()) return activeBackend;
    return spawnClient;
  };

  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusItem.text = 'rocgdbHover: stopped';
  statusItem.command = 'rocgdbHover.status';
  statusItem.show();
  context.subscriptions.push(statusItem, output);

  const updateStatus = () => {
    const b = getBackend();
    if (b === activeBackend) {
      statusItem.text = activeBackend.isRunning() ? 'rocgdbHover: cppdbg' : 'rocgdbHover: stopped';
    } else {
      statusItem.text = spawnClient.isRunning() ? 'rocgdbHover: rocgdb' : 'rocgdbHover: stopped';
    }
  };

  context.subscriptions.push(
    vscode.commands.registerCommand('rocgdbHover.start', async () => {
      try {
        const b = getBackend();
        if (b === activeBackend) {
          if (!activeBackend.isRunning()) {
            vscode.window.showWarningMessage('rocgdbHover: no active cppdbg session. Start debugging (cppdbg) first, or set rocgdbHover.backend=spawnRocgdb.');
          } else {
            vscode.window.showInformationMessage('rocgdbHover: using active cppdbg session');
          }
        } else {
          await spawnClient.start();
          vscode.window.showInformationMessage('rocgdbHover: rocgdb session started');
        }
        updateStatus();
      } catch (e) {
        output.appendLine(String(e && e.stack ? e.stack : e));
        vscode.window.showErrorMessage(`rocgdbHover start failed: ${e && e.message ? e.message : e}`);
      }
    }),
    vscode.commands.registerCommand('rocgdbHover.stop', async () => {
      try {
        await spawnClient.stop();
        updateStatus();
        vscode.window.showInformationMessage('rocgdbHover: stopped (spawned rocgdb only)');
      } catch (e) {
        output.appendLine(String(e && e.stack ? e.stack : e));
      }
    }),
    vscode.commands.registerCommand('rocgdbHover.status', async () => {
      const b = getBackend();
      if (b === activeBackend) {
        vscode.window.showInformationMessage(activeBackend.isRunning() ? 'rocgdbHover: using active cppdbg session' : 'rocgdbHover: no active cppdbg session');
      } else {
        vscode.window.showInformationMessage(spawnClient.isRunning() ? 'rocgdbHover: spawned rocgdb running' : 'rocgdbHover: spawned rocgdb stopped');
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('rocgdbHover.openLog', async () => {
      const cfg = vscode.workspace.getConfiguration('rocgdbHover');
      const logFile = cfg.get('logFile') || '';
      if (!logFile) {
        vscode.window.showWarningMessage('rocgdbHover.logFile is empty (file logging disabled).');
        return;
      }
      try {
        const uri = vscode.Uri.file(logFile);
        const doc = await vscode.workspace.openTextDocument(uri);
        await vscode.window.showTextDocument(doc, { preview: false });
      } catch (e) {
        vscode.window.showErrorMessage(`Failed to open log file: ${String(e && e.message ? e.message : e)}`);
      }
    })
  );

  const cache = new Map(); // key -> {ts, value}
  const cacheTtlMs = 150;
  const inFlight = new Map(); // cacheKey -> Promise<vscode.Hover|null>

  const hoverProvider = {
    provideHover: async (document, position, token) => {
      if (!isAsmLikeDocument(document)) return null;
      // VS Code may cancel hover requests very aggressively (e.g. small mouse moves),
      // which can lead to "we queried successfully but UI shows nothing" if we bail out
      // after starting debugger I/O. We only respect cancellation *before* starting work.
      if (token && token.isCancellationRequested) return null;

      try {
        const reg = extractRegisterAt(document, position);
        if (!reg) return null;
        if (token && token.isCancellationRequested) return null;

        logger.debug(`hover file=${document.uri.fsPath} line=${position.line} ch=${position.character} reg=${(reg.names||[]).join(',')}`);

        const b = getBackend();
        const backendIsReady = (b === activeBackend) ? activeBackend.isRunning() : spawnClient.isRunning();
        if (!backendIsReady) {
          const md = new vscode.MarkdownString();
          md.appendMarkdown(`**${reg.name}**\n\n`);
          md.appendMarkdown(`rocgdbHover backend is not ready.\n\n`);
          md.appendMarkdown(`- If you want **cppdbg integration**: start debugging with \`type: cppdbg\` and set \`miDebuggerPath\` to \`rocgdb\`.\n`);
          md.appendMarkdown(`- Or set \`rocgdbHover.backend\` to \`spawnRocgdb\` and run **"rocgdbHover: Start rocgdb session"**.`);
          md.isTrusted = false;
          return new vscode.Hover(md);
        }

        const key = `${reg.kind}:${reg.name}`;
        // Backward compat: older code used reg.name; now we store reg.names
        // Use a stable cache key for both single and range.
        const cacheKey = `${reg.kind}:${(reg.names || []).join(',')}`;
        const now = Date.now();
        const cached = cache.get(cacheKey);
        if (cached && now - cached.ts < cacheTtlMs) {
          return cached.value;
        }

        if (inFlight.has(cacheKey)) {
          const p = inFlight.get(cacheKey);
          try {
            return await p;
          } catch {
            // fall through: allow new attempt if the previous in-flight failed
          }
        }

        const p = (async () => {
          try {
            if (reg.kind === 'sgpr') {
              const names = reg.names || [];
              if (names.length === 1) {
                const val = await readSgpr(b, names[0]);
                const md = new vscode.MarkdownString();
                md.appendMarkdown(`**${names[0]}** = \`${val ?? 'N/A'}\``);
                const hover = new vscode.Hover(md);
                cache.set(cacheKey, { ts: Date.now(), value: hover });
                return hover;
              }

              // Range / multiple SGPRs
              const vals = await readSgprMany(b, names);
              const md = new vscode.MarkdownString();
              const title = reg.range ? `s[${reg.range.lo}:${reg.range.hi}]` : names.join(', ');
              md.appendMarkdown(`**${title}**\n\n`);
              md.appendCodeblock(
                names.map((n, i) => `${n} = ${vals[i] ?? 'N/A'}`).join('\n'),
                'text'
              );
              if (names.length === 2) {
                const combined = tryCombineSgprPair(vals[0], vals[1]);
                if (combined) {
                  md.appendMarkdown(`\nCombined 64-bit: \`${combined}\``);
                }
              }
              const hover = new vscode.Hover(md);
              cache.set(cacheKey, { ts: Date.now(), value: hover });
              return hover;
            }

            const names = reg.names || [];
            if (names.length === 1) {
              const r = await readVgpr(b, names[0]);
              const md = new vscode.MarkdownString();
              if (r && r.kind === 'vector') {
                md.appendMarkdown(`**${names[0]}** (lanes 0..${r.values.length - 1})\n\n`);
                md.appendCodeblock(
                  r.values.map((v, i) => `[${String(i).padStart(2, ' ')}] ${v ?? 'N/A'}`).join('\n'),
                  'text'
                );
              } else {
                md.appendMarkdown(`**${names[0]}** = \`${(r && r.value) ?? 'N/A'}\``);
              }
              const hover = new vscode.Hover(md);
              cache.set(cacheKey, { ts: Date.now(), value: hover });
              return hover;
            }

            // VGPR range: can be huge; keep it safe.
            if (names.length > 4) {
              const md = new vscode.MarkdownString();
              const title = reg.range ? `v[${reg.range.lo}:${reg.range.hi}]` : names.join(', ');
              md.appendMarkdown(`**${title}**\n\n`);
              md.appendMarkdown(`Range too large to display on hover (size=${names.length}). Hover a single register like \`v0\`.`);
              return new vscode.Hover(md);
            }

            const blocks = [];
            for (const n of names) {
              const r = await readVgpr(b, n);
              if (r && r.kind === 'vector') {
                blocks.push(
                  `${n}\n${r.values.map((v, i) => `[${String(i).padStart(2, ' ')}] ${v ?? 'N/A'}`).join('\n')}`
                );
              } else {
                blocks.push(`${n} = ${(r && r.value) ?? 'N/A'}`);
              }
            }
            const md = new vscode.MarkdownString();
            const title = reg.range ? `v[${reg.range.lo}:${reg.range.hi}]` : names.join(', ');
            md.appendMarkdown(`**${title}**\n\n`);
            md.appendCodeblock(blocks.join('\n\n'), 'text');
            const hover = new vscode.Hover(md);
            cache.set(cacheKey, { ts: Date.now(), value: hover });
            return hover;
          } catch (e) {
            // If the hover request got canceled, VS Code likely won't show the result anyway,
            // but returning null here can hide real errors during normal use. Keep the error hover.
            output.appendLine(String(e && e.stack ? e.stack : e));
            logger.error(String(e && e.stack ? e.stack : e));
            const md = new vscode.MarkdownString();
            md.appendMarkdown(`**${(reg.names && reg.names.length) ? reg.names.join(', ') : reg.name}**\n\n`);
            const msg = (e && e.message) ? e.message : String(e);
            if (String(msg).includes('\n')) {
              md.appendMarkdown(`Error querying rocgdb:\n\n`);
              md.appendCodeblock(String(msg).slice(0, 4000), 'text');
            } else {
              md.appendMarkdown(`Error querying rocgdb: \`${msg}\``);
            }
            return new vscode.Hover(md);
          } finally {
            inFlight.delete(cacheKey);
          }
        })();

        inFlight.set(cacheKey, p);
        return await p;
      } catch (e) {
        // Don't let unexpected errors (e.g. regex / parsing issues) kill hover silently.
        output.appendLine(String(e && e.stack ? e.stack : e));
        logger.error(String(e && e.stack ? e.stack : e));
        return null;
      }
    }
  };

  context.subscriptions.push(
    vscode.languages.registerHoverProvider(
      [
        { scheme: 'file', pattern: '**/*.{s,S}' },
        { scheme: 'file', pattern: '**/*.asm' }
      ],
      hoverProvider
    )
  );

  updateStatus();
}

function deactivate() {}

module.exports = {
  activate,
  deactivate
};

