import { mkdir } from "node:fs/promises";
import { join, resolve, relative } from "node:path";
import type { Settings } from "../shared/contracts";
import { appEnvSchema } from "./schemas";

export type RuntimeConfig = {
  readonly dataDir: string;
  readonly dbPath: string;
  readonly workDir: string;
  readonly docroot: string;
  readonly binDir: string;
  readonly regionSet: string;
  readonly siteDir: string;
  readonly frontendDir: string;
  readonly bind: string;
  readonly port: number;
  readonly allowedHosts: readonly string[];
  readonly envSettings: Partial<Omit<Settings, "remote">> & { readonly remote?: Partial<Settings["remote"]> };
  readonly overrides: readonly string[];
  readonly envCredentials: Credentials;
};

export type Credentials = {
  readonly accessKey: string | null;
  readonly secretKey: string | null;
};

export const defaultSettings: Settings = {
  regions: [],
  cadence: "manual",
  threads: 2,
  remote: { enabled: false, endpoint: "", bucket: "", region: "auto", provider: "Cloudflare" },
};

export async function loadConfig(env: NodeJS.ProcessEnv = process.env): Promise<RuntimeConfig> {
  const parsed = appEnvSchema.parse(Object.fromEntries(Object.entries(env).filter(([, value]) => value !== "")));
  const dataDir = resolve(parsed.DATA_DIR);
  const privateRelative = relative(resolve(parsed.DOCROOT), dataDir);
  if (!privateRelative.startsWith("..") && !privateRelative.startsWith("/")) throw new Error("DATA_DIR must be outside DOCROOT");
  const endpoint = parsed.S3_ENDPOINT ?? r2Endpoint(parsed.R2_ACCOUNT_ID);
  const bucket = parsed.S3_BUCKET ?? parsed.R2_BUCKET;
  const envSettings = buildEnvSettings(parsed, endpoint, bucket);
  const overrides = buildOverrides(parsed, endpoint, bucket);
  await mkdir(join(dataDir, "control"), { recursive: true, mode: 0o700 });
  await mkdir(join(dataDir, "work"), { recursive: true, mode: 0o700 });
  return {
    dataDir,
    dbPath: join(dataDir, "control", "control.sqlite"),
    workDir: join(dataDir, "work"),
    docroot: resolve(parsed.DOCROOT),
    binDir: resolve(parsed.BIN_DIR),
    regionSet: resolve(parsed.REGION_SET),
    siteDir: resolve(parsed.SITE_DIR),
    frontendDir: resolve(parsed.FRONTEND_DIR),
    bind: parsed.BUILDER_BIND,
    port: parsed.BUILDER_PORT,
    allowedHosts: parseCsv(parsed.BUILDER_ALLOWED_HOSTS),
    envSettings,
    overrides,
    envCredentials: {
      accessKey: parsed.S3_ACCESS_KEY_ID ?? parsed.R2_ACCESS_KEY_ID ?? null,
      secretKey: parsed.S3_SECRET_ACCESS_KEY ?? parsed.R2_SECRET_ACCESS_KEY ?? null,
    },
  };
}

function buildEnvSettings(
  parsed: ReturnType<typeof appEnvSchema.parse>,
  endpoint: string | undefined,
  bucket: string | undefined,
): RuntimeConfig["envSettings"] {
  const regions = parsed.BUILD_REGIONS === undefined ? undefined : [...parseCsv(parsed.BUILD_REGIONS)];
  const remote =
    endpoint === undefined && bucket === undefined && parsed.S3_REGION === undefined && parsed.S3_PROVIDER === undefined
      ? undefined
      : {
          ...(bucket === undefined ? {} : { enabled: true, bucket }),
          ...(endpoint === undefined ? {} : { endpoint }),
          ...(parsed.S3_REGION === undefined ? {} : { region: parsed.S3_REGION }),
          ...(parsed.S3_PROVIDER === undefined ? {} : { provider: parsed.S3_PROVIDER }),
        };
  return {
    ...(regions === undefined ? {} : { regions }),
    ...(parsed.BUILD_CADENCE === undefined ? {} : { cadence: parsed.BUILD_CADENCE }),
    ...(parsed.THREADS === undefined ? {} : { threads: parsed.THREADS }),
    ...(remote === undefined ? {} : { remote }),
  };
}

function buildOverrides(
  parsed: ReturnType<typeof appEnvSchema.parse>,
  endpoint: string | undefined,
  bucket: string | undefined,
): readonly string[] {
  const overrides: string[] = [];
  if (parsed.BUILD_REGIONS !== undefined) overrides.push("regions");
  if (parsed.BUILD_CADENCE !== undefined) overrides.push("cadence");
  if (parsed.THREADS !== undefined) overrides.push("threads");
  if (endpoint !== undefined) overrides.push("remote.endpoint");
  if (bucket !== undefined) overrides.push("remote.bucket", "remote.enabled");
  if (parsed.S3_REGION !== undefined) overrides.push("remote.region");
  if (parsed.S3_PROVIDER !== undefined) overrides.push("remote.provider");
  return overrides;
}

function parseCsv(value: string | undefined): readonly string[] {
  return value?.split(",").map((part) => part.trim()).filter((part) => part.length > 0) ?? [];
}

function r2Endpoint(accountId: string | undefined): string | undefined {
  return accountId === undefined ? undefined : `https://${accountId}.r2.cloudflarestorage.com`;
}
