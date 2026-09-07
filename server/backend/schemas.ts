import { z } from "zod";
import { credentialSchema } from "../shared/contracts";

export const appEnvSchema = z.object({
  DATA_DIR: z.string().default("/data"),
  DOCROOT: z.string().default("/site"),
  BIN_DIR: z.string().default("/opt/flckd/bin"),
  REGION_SET: z.string().default("/opt/flckd/regions/us-states.json"),
  SITE_DIR: z.string().default("/opt/flckd/site"),
  FRONTEND_DIR: z.string().default("/opt/flckd/frontend"),
  BUILDER_BIND: z.string().default("127.0.0.1"),
  BUILDER_PORT: z.coerce.number().int().min(1).max(65535).default(8642),
  BUILDER_ALLOWED_HOSTS: z.string().optional(),
  THREADS: z.coerce.number().int().min(1).max(64).optional(),
  BUILD_REGIONS: z.string().optional(),
  BUILD_CADENCE: z.enum(["manual", "daily", "weekly", "every_30_days"]).optional(),
  S3_ENDPOINT: z.string().optional(),
  S3_BUCKET: z.string().optional(),
  S3_REGION: z.string().optional(),
  S3_PROVIDER: z.enum(["Cloudflare", "AWS", "Other"]).optional(),
  S3_ACCESS_KEY_ID: z.string().optional(),
  S3_SECRET_ACCESS_KEY: z.string().optional(),
  R2_BUCKET: z.string().optional(),
  R2_ACCOUNT_ID: z.string().optional(),
  R2_ACCESS_KEY_ID: z.string().optional(),
  R2_SECRET_ACCESS_KEY: z.string().optional(),
});

export const regionFileSchema = z.object({
  packs: z.array(z.object({ id: z.string(), name: z.string(), iso3166_2: z.string() })),
});

export const credentialsInputSchema = credentialSchema;
export const statusFileSchema = z.object({
  build_id: z.string(),
  stage: z.string(),
  detail: z.string().optional().default(""),
  progress: z.number().min(0).max(1).nullable().optional().default(null),
  local_published: z.boolean().optional().default(false),
  remote_published: z.boolean().optional().default(false),
});

export const manifestSchema = z.object({ build_id: z.string() }).passthrough();
