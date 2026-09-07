import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { Job, Settings } from "../shared/contracts";
import type { Credentials, RuntimeConfig } from "./config";
import type { Store } from "./db";
import type { EventBus } from "./events";
import { HttpStatusError, ProcessRunError } from "./errors";
import { Redactor } from "./redact";
import { statusFileSchema } from "./schemas";

type RunningChild = ReturnType<typeof Bun.spawn>;

type JobRequest = {
  readonly kind: "build" | "publish";
  readonly settings: Settings;
  readonly credentials: Credentials;
};

export class JobRunner {
  readonly #store: Store;
  readonly #config: RuntimeConfig;
  readonly #events: EventBus;
  #running: Job | null = null;
  #child: RunningChild | null = null;
  #completion: Promise<void> | null = null;
  #stopping = false;
  #cancelled = false;
  #sequences = new Map<string, number>();

  constructor(store: Store, config: RuntimeConfig, events: EventBus) {
    this.#store = store;
    this.#config = config;
    this.#events = events;
  }

  enqueue(request: JobRequest): Job {
    if (this.#stopping || this.#running !== null || this.#store.activeJob() !== null) throw new HttpStatusError(409, "a job is already running or the service is stopping");
    this.#cancelled = false;
    const now = new Date().toISOString();
    const job: Job = {
      id: `${now.replace(/[-:.]/g, "")}-${crypto.randomUUID().slice(0, 8)}`,
      kind: request.kind,
      status: "queued",
      stage: "queued",
      detail: "waiting to start",
      progress: null,
      created_at: now,
      started_at: null,
      finished_at: null,
      regions: request.settings.regions,
      local_published: false,
      remote_published: false,
      remote_enabled: request.settings.remote.enabled,
      exit_code: null,
    };
    this.#store.createJob(job, request.settings);
    this.#running = job;
    this.#completion = this.run(job, request);
    return job;
  }

  cancel(jobId: string): Job {
    const running = this.#running;
    if (running === null || running.id !== jobId) throw new HttpStatusError(409, "that job is not running");
    if (this.#cancelled) return running;
    this.#cancelled = true;
    this.append(jobId, "Cancelling on request — stopping the build process.\n");
    const child = this.#child;
    if (child !== null) {
      signalGroup(child.pid, "SIGTERM");
      void (async () => {
        await Promise.race([this.#completion, Bun.sleep(5000)]);
        if (this.#child === child) signalGroup(child.pid, "SIGKILL");
      })();
    }
    return running;
  }

  async shutdown(): Promise<void> {
    this.#stopping = true;
    const child = this.#child;
    if (child !== null) {
      signalGroup(child.pid, "SIGTERM");
      await Promise.race([this.#completion, Bun.sleep(3000)]);
      signalGroup(child.pid, "SIGKILL");
    }
    await this.#completion;
  }

  private async run(initial: Job, request: JobRequest): Promise<void> {
    let job: Job = { ...initial, status: "running", started_at: new Date().toISOString(), stage: "starting", detail: "starting" };
    const secrets = [request.credentials.accessKey, request.credentials.secretKey].filter((value) => value !== null);
    const redactor = new Redactor(secrets);
    this.#store.updateJob(job);
    this.#events.state(await this.emitState());
    try {
      await mkdir(join(this.#config.workDir, "jobs", job.id), { recursive: true, mode: 0o700 });
      if (this.#stopping) throw new ProcessRunError(job.id, null);
      const result = await this.spawn(job, request, secrets);
      job = { ...job, ...result, status: this.finalStatus(result.exitCode), progress: null, exit_code: result.exitCode, finished_at: new Date().toISOString() };
      this.#store.updateJob(job);
      if (result.exitCode !== 0 && !this.#cancelled) throw new ProcessRunError(job.id, result.exitCode);
    } catch (error) {
      if (error instanceof ProcessRunError) {
        this.append(job.id, redactor.clean(`${error.message}\n`));
      } else {
        this.append(job.id, "Build process could not complete. Check available disk, tools and source configuration.\n");
        job = { ...job, status: "failed", stage: "failed", detail: "job failed", progress: null, finished_at: new Date().toISOString() };
        this.#store.updateJob(job);
      }
    } finally {
      this.#child = null;
      this.#running = null;
      this.#events.state(await this.emitState());
    }
  }

  private finalStatus(exitCode: number | null): Job["status"] {
    if (this.#stopping) return "interrupted";
    if (this.#cancelled) return "cancelled";
    return exitCode === 0 ? "succeeded" : "failed";
  }

  private async spawn(job: Job, request: JobRequest, secrets: readonly string[]): Promise<{ readonly exitCode: number | null; readonly stage: string; readonly detail: string; readonly local_published: boolean; readonly remote_published: boolean }> {
    const statusFile = join(this.#config.workDir, "jobs", job.id, "status.json");
    const cmd = request.kind === "build" ? [join(this.#config.binDir, "run-build.sh"), ...request.settings.regions] : [join(this.#config.binDir, "push-r2.sh"), this.#config.docroot];
    const env = this.jobEnv(job, request, statusFile);
    const child = Bun.spawn(["bash", ...cmd], { stdout: "pipe", stderr: "pipe", env, cwd: this.#config.workDir, detached: true });
    this.#child = child;
    const redactor = new Redactor(secrets);
    const readers = [this.drain(job.id, child.stdout, new Redactor(secrets)), this.drain(job.id, child.stderr, new Redactor(secrets)), this.watchStatus(job, statusFile, redactor)];
    const exitCode = await child.exited;
    signalGroup(child.pid, "SIGKILL");
    this.#child = null;
    await Promise.all(readers);
    const status = await this.readStatus(statusFile, redactor);
    const manifest = await Bun.file(join(this.#config.docroot, "v1", "manifest.json")).text().catch(() => "");
    const local = request.kind === "publish" ? manifest.length > 0 : manifest.includes(`"${job.id}"`);
    if (this.#cancelled) return { exitCode, stage: "cancelled", detail: "cancelled by request", local_published: status.local_published || local, remote_published: status.remote_published };
    return { exitCode, stage: exitCode === 0 ? "done" : "failed", detail: status.detail, local_published: status.local_published || local, remote_published: status.remote_published || (exitCode === 0 && request.settings.remote.enabled) };
  }

  private jobEnv(job: Job, request: JobRequest, statusFile: string): Record<string, string> {
    const env: Record<string, string> = {
      PATH: process.env["PATH"] ?? "/usr/bin:/bin",
      DATA_DIR: this.#config.workDir,
      DOCROOT: this.#config.docroot,
      STATUS_FILE: statusFile,
      BUILD_ID: job.id,
      THREADS: String(request.settings.threads),
      REGION_SET: this.#config.regionSet,
      WWW_DIR: this.#config.siteDir,
      R2_PRUNE: "0",
      PYTHONUNBUFFERED: "1",
    };
    for (const key of ["PBF_URL", "PBF_NAME", "KEEP_RELEASES", "PART_BYTES", "MAX_CACHE_MB", "SKIP_PBF_UPDATE", "SKIP_TIMEZONES", "HOME", "TMPDIR"]) {
      const value = process.env[key];
      if (value !== undefined && value !== "") env[key] = value;
    }
    if (request.settings.remote.enabled) {
      env["S3_ENDPOINT"] = request.settings.remote.endpoint;
      env["S3_BUCKET"] = request.settings.remote.bucket;
      env["S3_REGION"] = request.settings.remote.region;
      env["S3_PROVIDER"] = request.settings.remote.provider;
      env["S3_ACCESS_KEY_ID"] = request.credentials.accessKey ?? "";
      env["S3_SECRET_ACCESS_KEY"] = request.credentials.secretKey ?? "";
    }
    return env;
  }

  private async drain(jobId: string, stream: ReadableStream<Uint8Array>, redactor: Redactor): Promise<void> {
    const pen = { state: emptyLine, open: null as number | null };
    for await (const chunk of stream) {
      for (let offset = 0; offset < chunk.length; offset += 4096) this.consume(jobId, pen, redactor.push(chunk.subarray(offset, offset + 4096)));
    }
    this.consume(jobId, pen, redactor.flush());
  }

  // The unterminated line keeps one sequence and is rewritten in place, so a
  // meter updates a single log entry instead of appending one per redraw.
  private consume(jobId: string, pen: { state: LineState; open: number | null }, text: string): void {
    if (text.length === 0) return;
    const { completed, state } = renderChunk(pen.state, text);
    pen.state = state;
    let pending = completed;
    if (pen.open !== null && pending.length > 0) {
      this.write(jobId, pen.open, pending[0] ?? "");
      pen.open = null;
      pending = pending.slice(1);
    }
    if (pending.length > 0) this.write(jobId, null, pending.join(""));
    if (state.line.length > 0) pen.open = this.write(jobId, pen.open, state.line);
  }

  private append(jobId: string, text: string): void {
    if (text.length === 0) return;
    this.write(jobId, null, text);
  }

  private write(jobId: string, sequence: number | null, text: string): number {
    let seq = sequence;
    if (seq === null) {
      seq = (this.#sequences.get(jobId) ?? 0) + 1;
      this.#sequences.set(jobId, seq);
    }
    this.#store.appendLog(jobId, seq, text);
    this.#events.log(jobId, seq, text);
    return seq;
  }

  private async watchStatus(job: Job, path: string, redactor: Redactor): Promise<void> {
    let last = "";
    while (this.#child !== null) {
      await Bun.sleep(500);
      const status = await this.readStatus(path, redactor);
      const next = { ...job, stage: status.stage, detail: status.detail, progress: status.progress, local_published: status.local_published, remote_published: status.remote_published };
      const serialized = JSON.stringify(next);
      if (serialized !== last) {
        last = serialized;
        this.#store.updateJob(next);
        this.#events.state(await this.emitState());
      }
    }
  }

  private async readStatus(path: string, redactor: Redactor): Promise<{ readonly stage: string; readonly detail: string; readonly progress: number | null; readonly local_published: boolean; readonly remote_published: boolean }> {
    const status = statusFileSchema.safeParse(await Bun.file(path).json().catch(() => ({ build_id: "", stage: "running", detail: "" })));
    if (!status.success) return { stage: "running", detail: "", progress: null, local_published: false, remote_published: false };
    return { stage: status.data.stage, detail: redactor.clean(status.data.detail), progress: status.data.progress, local_published: status.data.local_published, remote_published: status.data.remote_published };
  }

  private async emitState(): Promise<import("../shared/contracts").State> {
    const { buildState } = await import("./state");
    const { loadRegions } = await import("./regions");
    return buildState(this.#store, this.#config, await loadRegions(this.#config.regionSet));
  }
}

export type LineState = { readonly line: string; readonly col: number };
export const emptyLine: LineState = { line: "", col: 0 };

// A progress meter redraws one line with carriage returns, one write per update,
// so the redraws arrive in separate chunks and only a cursor carried between them
// renders what a terminal would actually be showing.
export function renderChunk(state: LineState, text: string): { readonly completed: readonly string[]; readonly state: LineState } {
  const completed: string[] = [];
  let line = state.line;
  let col = state.col;
  for (const ch of text) {
    if (ch === "\n") {
      completed.push(`${line}\n`);
      line = "";
      col = 0;
    } else if (ch === "\r") {
      col = 0;
    } else if (col === line.length) {
      line += ch;
      col += 1;
    } else {
      line = line.slice(0, col) + ch + line.slice(col + 1);
      col += 1;
    }
  }
  return { completed, state: { line, col } };
}

function signalGroup(pid: number, signal: NodeJS.Signals): void {
  try { process.kill(-pid, signal); }
  catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error;
  }
}
