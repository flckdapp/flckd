import { chmod } from "node:fs/promises";
import { Database } from "bun:sqlite";
import { jobSchema, settingsSchema, type Job, type Settings } from "../shared/contracts";
import { z } from "zod";
import type { Credentials } from "./config";

type JobRow = Omit<Job, "regions"> & { readonly regions_json: string };
type LogRow = { readonly sequence: number; readonly text: string };
type KvRow = { readonly value: string };
type ColumnRow = { readonly name: string };

const JOB_COLUMNS = "id, kind, status, stage, detail, progress, created_at, started_at, finished_at, regions_json, local_published, remote_published, remote_enabled, exit_code";

export class Store {
  readonly #db: Database;

  constructor(readonly path: string) {
    this.#db = new Database(path, { create: true, strict: true });
    this.#db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
    this.#db.exec(`CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, stage TEXT NOT NULL, detail TEXT NOT NULL, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, regions_json TEXT NOT NULL, local_published INTEGER NOT NULL, remote_published INTEGER NOT NULL, remote_enabled INTEGER NOT NULL, exit_code INTEGER, snapshot_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS job_log (job_id TEXT NOT NULL, sequence INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(job_id, sequence));`);
    if (!this.#db.query<ColumnRow, []>("PRAGMA table_info(jobs)").all().some((column) => column.name === "progress")) {
      this.#db.exec("ALTER TABLE jobs ADD COLUMN progress REAL");
    }
  }

  async secure(): Promise<void> {
    await chmod(this.path, 0o600);
  }

  close(): void {
    this.#db.close();
  }

  settings(): Settings | null {
    const row = this.#db.query<KvRow, [string]>("SELECT value FROM kv WHERE key = ?").get("settings");
    return row === null ? null : settingsSchema.parse(JSON.parse(row.value));
  }

  saveSettings(settings: Settings): void {
    this.#db.query("INSERT INTO kv(key, value) VALUES('settings', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(JSON.stringify(settings));
  }

  credentials(): Credentials {
    const row = this.#db.query<KvRow, [string]>("SELECT value FROM kv WHERE key = ?").get("credentials");
    if (row === null) return { accessKey: null, secretKey: null };
    return z.object({ accessKey: z.string().nullable(), secretKey: z.string().nullable() }).parse(JSON.parse(row.value));
  }

  saveCredentials(credentials: Credentials): void {
    this.#db.query("INSERT INTO kv(key, value) VALUES('credentials', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(JSON.stringify(credentials));
  }

  createJob(job: Job, snapshot: Settings): void {
    this.#db.query(`INSERT INTO jobs(${JOB_COLUMNS}, snapshot_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(job.id, job.kind, job.status, job.stage, job.detail, job.progress, job.created_at, job.started_at, job.finished_at, JSON.stringify(job.regions), Number(job.local_published), Number(job.remote_published), Number(job.remote_enabled), job.exit_code, JSON.stringify(snapshot));
    this.#db.transaction(() => {
      this.#db.exec("DELETE FROM jobs WHERE id NOT IN (SELECT id FROM jobs ORDER BY created_at DESC LIMIT 100)");
      this.#db.exec("DELETE FROM job_log WHERE job_id NOT IN (SELECT id FROM jobs)");
    })();
  }

  updateJob(job: Job): void {
    this.#db.query(`UPDATE jobs SET status=?, stage=?, detail=?, progress=?, started_at=?, finished_at=?, local_published=?, remote_published=?, exit_code=? WHERE id=?`)
      .run(job.status, job.stage, job.detail, job.progress, job.started_at, job.finished_at, Number(job.local_published), Number(job.remote_published), job.exit_code, job.id);
  }

  jobs(): readonly Job[] {
    return this.#db.query<JobRow, []>(`SELECT ${JOB_COLUMNS} FROM jobs ORDER BY created_at DESC LIMIT 100`).all().map(rowToJob);
  }

  activeJob(): Job | null {
    const row = this.#db.query<JobRow, []>(`SELECT ${JOB_COLUMNS} FROM jobs WHERE status IN ('queued','running') ORDER BY created_at LIMIT 1`).get();
    return row === null ? null : rowToJob(row);
  }

  appendLog(jobId: string, sequence: number, text: string): void {
    this.#db.query("INSERT INTO job_log(job_id, sequence, text) VALUES (?, ?, ?) ON CONFLICT(job_id, sequence) DO UPDATE SET text = excluded.text").run(jobId, sequence, text);
    this.#db.query("DELETE FROM job_log WHERE job_id = ? AND sequence NOT IN (SELECT sequence FROM (SELECT sequence, SUM(length(CAST(text AS BLOB))) OVER (ORDER BY sequence DESC) AS bytes FROM job_log WHERE job_id = ?) WHERE bytes <= 1048576)").run(jobId, jobId);
  }

  logs(jobId: string): { readonly entries: readonly LogRow[]; readonly truncated: boolean } {
    const entries = this.#db.query<LogRow, [string]>("SELECT sequence, text FROM job_log WHERE job_id = ? ORDER BY sequence").all(jobId);
    return { entries, truncated: (entries[0]?.sequence ?? 1) > 1 };
  }

  nextDue(): string | null {
    return this.#db.query<KvRow, []>("SELECT value FROM kv WHERE key='next_due'").get()?.value || null;
  }

  schedule(cadence: Settings["cadence"], now = Date.now()): void {
    const previous = this.#db.query<KvRow, []>("SELECT value FROM kv WHERE key='cadence'").get()?.value;
    if (previous === cadence) return;
    this.#db.query("INSERT OR REPLACE INTO kv VALUES ('cadence', ?)").run(cadence);
    this.advanceSchedule(cadence, now);
  }

  advanceSchedule(cadence: Settings["cadence"], now = Date.now()): void {
    const days = { manual: 0, daily: 1, weekly: 7, every_30_days: 30 }[cadence];
    const due = days === 0 ? "" : new Date(now + days * 86400_000).toISOString();
    this.#db.query("INSERT OR REPLACE INTO kv VALUES ('next_due', ?)").run(due);
  }

  markInterruptedOnStartup(): void {
    const now = new Date().toISOString();
    this.#db.query("UPDATE jobs SET status='interrupted', finished_at=?, detail='interrupted by restart' WHERE status IN ('queued','running')").run(now);
  }
}

function rowToJob(row: JobRow): Job {
  return jobSchema.parse({
    id: row.id,
    kind: row.kind,
    status: row.status,
    stage: row.stage,
    detail: row.detail,
    progress: row.progress,
    created_at: row.created_at,
    started_at: row.started_at,
    finished_at: row.finished_at,
    regions: JSON.parse(row.regions_json),
    local_published: Boolean(row.local_published),
    remote_published: Boolean(row.remote_published),
    remote_enabled: Boolean(row.remote_enabled),
    exit_code: row.exit_code,
  });
}
