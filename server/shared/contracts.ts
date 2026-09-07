import { z } from "zod";

export const remoteSchema = z.object({
  enabled: z.boolean(),
  endpoint: z.string().max(2048),
  bucket: z.string().max(63),
  region: z.string().max(64),
  provider: z.enum(["Cloudflare", "AWS", "Other"]),
});
export const settingsSchema = z.object({
  regions: z.array(z.string().regex(/^[a-z-]+$/)).max(53),
  cadence: z.enum(["manual", "daily", "weekly", "every_30_days"]),
  threads: z.number().int().min(1).max(64),
  remote: remoteSchema,
}).strict();
export type Settings = z.infer<typeof settingsSchema>;
export const jobSchema = z.object({
  id: z.string(),
  kind: z.enum(["build", "publish"]),
  status: z.enum(["queued", "running", "succeeded", "failed", "interrupted", "cancelled"]),
  stage: z.string(),
  detail: z.string(),
  // Counted work units done in this stage, 0..1. Null where nothing is countable — never an ETA.
  progress: z.number().min(0).max(1).nullable(),
  created_at: z.string(),
  started_at: z.string().nullable(),
  finished_at: z.string().nullable(),
  regions: z.array(z.string()),
  local_published: z.boolean(),
  remote_published: z.boolean(),
  remote_enabled: z.boolean(),
  exit_code: z.number().nullable(),
});
export type Job = z.infer<typeof jobSchema>;
export const stateSchema = z.object({
  settings: settingsSchema,
  regions: z.array(z.object({ id: z.string(), name: z.string(), iso3166_2: z.string() })),
  jobs: z.array(jobSchema),
  next_due_at: z.string().nullable(),
  active_job_id: z.string().nullable(),
  storage: z.object({ free_bytes: z.number(), site_path: z.string() }),
  credentials: z.object({
    access_key: z.object({ configured: z.boolean(), source: z.enum(["environment", "saved", "unset"]) }),
    secret_key: z.object({ configured: z.boolean(), source: z.enum(["environment", "saved", "unset"]) }),
  }),
  overrides: z.array(z.string()),
});
export type State = z.infer<typeof stateSchema>;
export const credentialSchema = z.object({
  access_key: z.string().max(512).optional(),
  secret_key: z.string().max(2048).optional(),
}).strict();
export const eventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("state"), state: stateSchema }),
  z.object({ type: z.literal("log"), job_id: z.string(), sequence: z.number(), text: z.string() }),
]);
export const logSchema = z.object({
  entries: z.array(z.object({ sequence: z.number(), text: z.string() })),
  truncated: z.boolean(),
});
