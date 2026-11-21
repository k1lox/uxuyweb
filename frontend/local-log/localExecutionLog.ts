/** Local execution messages only. Never reads identity/private-key files or sends data. */
type LogBlob = { size: number; lastModified: number; arrayBuffer(): Promise<ArrayBuffer> };
type LogFile = {
  isSameEntry?(other: LogFile): Promise<boolean>;
  getFile(): Promise<LogBlob>;
  createWritable(options: { mode: "exclusive" }): Promise<{
    write(text: string): Promise<void>;
    close(): Promise<void>;
    abort(): Promise<void>;
  }>;
};
export type ExecutionLogDirectory = {
  name: string;
  isSameEntry?(other: ExecutionLogDirectory): Promise<boolean>;
  getFileHandle(name: string, options?: { create?: boolean }): Promise<LogFile>;
};
export type ExecutionLogSnapshot = {
  filename: string; text: string; ready: boolean; saving: boolean; error: string; pending: number;
};
type Entry = { id: string; time: string; source: string; message: string };
type Archive = { version: 1; legacyText: string; entries: Entry[] };
type Target = {
  directory: ExecutionLogDirectory; authorized: boolean; history: string; lines: string;
  queue: Entry[]; initialized: boolean; error: string;
  verified?: { handle: LogFile; size: number; modified: number };
  prefix?: { count: number; digest: string };
};
const FILE = "logs.json";
const LEGACY = "logs.txt";
const VIEW_CHARS = 256 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const SAVE_ERROR = "日志未能写入并回查，请检查目录权限和可用空间后重试";
class ArchiveError extends Error {}
let fallbackLock: Promise<unknown> = Promise.resolve();
function fileLock<T>(work: () => Promise<T>): Promise<T> {
  if (globalThis.navigator?.locks) return navigator.locks.request("botai-execution-log-file", work);
  const next = fallbackLock.then(work, work);
  fallbackLock = next.catch(() => {});
  return next;
}
function tail(text: string) {
  if (text.length <= VIEW_CHARS) return text;
  const start = text.indexOf("\n", text.length - VIEW_CHARS);
  return text.slice(start >= 0 ? start + 1 : -VIEW_CHARS);
}
function redact(text: string) {
  return text
    .replace(/-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/g, "[已隐藏]")
    .replace(/((?:mnemonic(?:[ _-]?phrase)?|seed[ _-]?phrase|recovery[ _-]?phrase|助记词|恢复短语)["']?\s*[:=：]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,，;；\r\n}"']+)/gi, "$1[已隐藏]")
    .replace(/((?:private[ _-]?key|私钥|(?:access|auth|session)[ _-]?token|authorization|credential|pass(?:word|phrase)|密码|口令|api[ _-]?key)["']?\s*[:=：]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:Bearer\s+)?[^\s,;"'}]+)/gi, "$1[已隐藏]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/g, "Bearer [已隐藏]");
}
function display(entry: Entry) {
  const stamp = new Date(Date.parse(entry.time) + 8 * 3600_000).toISOString().replace("T", " ").replace("Z", " UTC+8");
  return `${stamp} [${entry.source.replace(/[\r\n\[\]]/g, " ")}] ${entry.message}\n`;
}
function render(archive: Archive, preview: boolean) {
  const legacy = archive.legacyText;
  if (!preview) return legacy + (legacy && !legacy.endsWith("\n") ? "\n" : "") + archive.entries.map(display).join("");
  const lines: string[] = [];
  let size = 0;
  for (let i = archive.entries.length - 1; i >= 0 && size < VIEW_CHARS; --i) {
    const line = display(archive.entries[i]);
    size += line.length;
    lines.push(line);
  }
  const prefix = size < VIEW_CHARS ? tail(legacy) + (legacy && !legacy.endsWith("\n") ? "\n" : "") : "";
  return tail(prefix + lines.reverse().join(""));
}
async function existing(directory: ExecutionLogDirectory, name: string) {
  try { return await directory.getFileHandle(name); } catch (error) {
    if ((error as Error)?.name !== "NotFoundError") throw error;
    return undefined;
  }
}
function parseArchive(contents: string): Archive {
  const invalid = () => new ArchiveError("logs.json 格式异常，已保留原文件，请检查后重试");
  let archive: Archive;
  try { archive = JSON.parse(contents); } catch { throw invalid(); }
  if (archive?.version !== 1 || typeof archive.legacyText !== "string" || !Array.isArray(archive.entries)) throw invalid();
  const ids = new Set<string>();
  for (const entry of archive.entries) {
    if (!entry || typeof entry.id !== "string" || !entry.id || ids.has(entry.id) ||
        typeof entry.time !== "string" || !Number.isFinite(Date.parse(entry.time)) ||
        typeof entry.source !== "string" || typeof entry.message !== "string") throw invalid();
    ids.add(entry.id);
  }
  return archive;
}
async function readText(blob: LogBlob) {
  try { return decoder.decode(await blob.arrayBuffer()); }
  catch (error) {
    if (error instanceof TypeError) throw new ArchiveError("日志文件的 UTF-8 编码无效，请检查原文件后重试");
    throw error;
  }
}
async function verifyContents(directory: ExecutionLogDirectory, handle: LogFile, expected: string) {
  const current = await directory.getFileHandle(FILE);
  const file = await current.getFile();
  if ((handle.isSameEntry && !await handle.isSameEntry(current)) || await readText(file) !== expected) {
    throw new ArchiveError("日志文件内容已变更，请检查后重试");
  }
  return file;
}
async function persist(directory: ExecutionLogDirectory, handle: LogFile, original: string, contents: string) {
  const output = await handle.createWritable({ mode: "exclusive" });
  try {
    await output.write(contents);
    await verifyContents(directory, handle, original);
    await output.close();
  } catch (error) {
    try { await output.abort(); } catch { /* close may already have committed. */ }
    throw error;
  }
  return verifyContents(directory, handle, contents);
}
// A valid replacement JSON can still omit earlier records. Remember the verified
// prefix while the folder is open, so retry never blesses such a rollback.
async function prefixDigest(archive: Archive, count: number) {
  const rows = archive.entries.slice(0, count).map(({ id, time, source, message }) => [id, time, source, message]);
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(JSON.stringify([archive.legacyText, rows])));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
}

export class LocalExecutionLog {
  private listeners = new Set<() => void>();
  private targets: Target[] = [];
  private active?: Target;
  private unbound: Entry[] = [];
  private unboundText = "";
  private timer?: ReturnType<typeof setTimeout>;
  private flight?: Promise<void>;
  private attaching = 0;
  private state: ExecutionLogSnapshot = { filename: FILE, text: "", ready: false, saving: false, error: "", pending: 0 };
  constructor(private delay = 500) {}
  snapshot = () => this.state;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private update(saving = this.state.saving) {
    const target = this.active;
    this.state = {
      filename: FILE, text: target ? tail(target.history + target.lines) : this.unboundText,
      ready: !!target?.authorized && target.initialized && !target.error, saving,
      error: target?.error || "",
      pending: this.unbound.length + this.targets.reduce((count, item) => count + item.queue.length, 0),
    };
    this.listeners.forEach(listener => listener());
  }
  record(source: string, message: string, time?: Date | number) {
    const date = new Date(time instanceof Date ? time.getTime() : time ?? Date.now());
    const entry: Entry = { id: crypto.randomUUID(), time: (Number.isFinite(date.getTime()) ? date : new Date()).toISOString(),
      source: redact(source), message: redact(message) };
    const target = this.active;
    if (target) {
      target.queue.push(entry);
      target.lines = tail(target.lines + display(entry));
    } else {
      this.unbound.push(entry);
      this.unboundText = tail(this.unboundText + display(entry));
    }
    this.update(); this.schedule();
  }
  /** A null directory suspends disk writes, retaining pending entries for that folder. */
  async attach(directory: ExecutionLogDirectory | null, authorized = true) {
    const revision = ++this.attaching;
    if (!directory) {
      if (this.active) this.active.authorized = false;
      this.active = undefined;
      this.update(); return;
    }
    let target = this.targets.find(item => item.directory === directory);
    if (!target && directory.isSameEntry) {
      for (const item of this.targets) {
        try { if (await directory.isSameEntry(item.directory)) { target = item; break; } } catch { /* Removed folder. */ }
      }
    }
    if (revision !== this.attaching) return;
    if (!target) {
      target = { directory, authorized, history: "", lines: "",
        queue: [], initialized: false, error: "" };
      this.targets.push(target);
    }
    this.active = target; target.authorized = authorized;
    if (authorized) await this.sync(target);
    this.update(); this.schedule();
  }
  private schedule() {
    if (this.timer || this.flight || !this.targets.some(target => target.authorized && !target.error && target.queue.length)) return;
    this.timer = setTimeout(() => { this.timer = undefined; void this.flush(); }, this.delay);
  }
  flush(): Promise<void> {
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (this.flight) return this.flight;
    this.update(true);
    this.flight = (async () => {
      for (const target of [...this.targets]) {
        if (target.authorized && !target.error && target.queue.length) await this.sync(target);
      }
    })().finally(() => {
      this.flight = undefined;
      this.targets = this.targets.filter(target => target === this.active || target.queue.length > 0);
      this.update(false); this.schedule();
    });
    return this.flight;
  }
  async retry() {
    for (const target of this.targets) if (target.authorized && target.error) await this.sync(target);
    await this.flush();
  }
  async flushActive() {
    const target = this.active;
    if (!target?.authorized) throw new Error("日志目录未授权");
    do {
      await this.sync(target);
      if (!target.authorized || target.error) throw new Error(target.error || "日志目录未授权");
    } while (target === this.active && (target.queue.length || this.unbound.length));
  }
  async readHistory(): Promise<string> {
    const target = this.active;
    if (!target?.authorized) throw new Error("日志目录未授权");
    const history = await this.sync(target, true);
    if (!target.authorized || history === undefined) throw new Error(target.error || "日志目录未授权");
    return history;
  }
  private async sync(target: Target, fullHistory = false) {
    try {
      return await fileLock(async () => {
        if (!target.authorized) return;
        const directory = target.directory;
        let handle = await existing(directory, FILE);
        let file = handle && await handle.getFile();
        const verified = target.verified;
        const sameFile = !!(file && verified && file.lastModified === verified.modified && file.size === verified.size &&
          handle?.isSameEntry && await handle.isSameEntry(verified.handle));
        const unboundCount = target === this.active ? this.unbound.length : 0;
        if (sameFile && !fullHistory && !target.error && !target.queue.length && !unboundCount) return;
        let archive: Archive;
        const original = file ? await readText(file) : "";
        if (original) {
          archive = parseArchive(original);
        } else {
          if (target.initialized) throw new ArchiveError("logs.json 已被移除或清空，请恢复原文件后重试");
          const legacy = await existing(directory, LEGACY);
          archive = { version: 1, legacyText: legacy ? redact(await readText(await legacy.getFile())) : "", entries: [] };
          handle ??= await directory.getFileHandle(FILE, { create: true });
        }
        const previous = target.prefix;
        if (previous && (archive.entries.length < previous.count ||
            await prefixDigest(archive, previous.count) !== previous.digest)) {
          throw new ArchiveError("日志文件缺少或改动了已核验的历史，请恢复原文件后重试");
        }
        // Keep all previously observed rows as a minimum even if this write or
        // its readback fails after another tab has extended the history.
        const originalCount = archive.entries.length;
        if (!previous || previous.count !== originalCount) {
          target.prefix = { count: originalCount, digest: await prefixDigest(archive, originalCount) };
        }
        // A failed first connection must not strand unassigned events in the
        // rejected folder. Claim them only after the destination verifies.
        const queuedCount = target.queue.length;
        const pending = this.unbound.slice(0, unboundCount).concat(target.queue);
        let changed = !file?.size;
        if (pending.length) {
          const saved = new Map(archive.entries.map(entry => [entry.id, entry]));
          for (const entry of pending) {
            const prior = saved.get(entry.id);
            if (prior) {
              // A write may have committed even if close or verification failed.
              if (prior.time !== entry.time || prior.source !== entry.source || prior.message !== entry.message) {
                throw new ArchiveError("日志记录与待保存内容不一致，请检查原文件后重试");
              }
            } else {
              archive.entries.push(entry);
              changed = true;
            }
          }
        }
        if (changed) {
          file = await persist(directory, handle!, original, JSON.stringify(archive, null, 2) + "\n");
        } else if (pending.length) {
          file = await verifyContents(directory, handle!, original);
        }
        if (archive.entries.length !== originalCount) {
          target.prefix = { count: archive.entries.length, digest: await prefixDigest(archive, archive.entries.length) };
        }
        target.verified = { handle: handle!, size: file!.size, modified: file!.lastModified };
        target.queue.splice(0, queuedCount);
        if (unboundCount) {
          this.unbound.splice(0, unboundCount);
          this.unboundText = tail(this.unbound.map(display).join(""));
        }
        target.history = render(archive, true);
        target.lines = tail(target.queue.map(display).join(""));
        target.initialized = true; target.error = "";
        if (fullHistory) return render(archive, false);
      });
    } catch (error) {
      target.error = error instanceof ArchiveError ? error.message : SAVE_ERROR;
    } finally { this.update(); }
  }
}

export const localExecutionLog = new LocalExecutionLog();
