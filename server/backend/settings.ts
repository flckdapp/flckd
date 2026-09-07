import type { State, Settings } from "../shared/contracts";
import type { Credentials, RuntimeConfig } from "./config";
import { defaultSettings } from "./config";
import { HttpStatusError } from "./errors";
import { validateRegionSelection, type RegionCatalog } from "./regions";

export type EffectiveSettings = {
  readonly settings: Settings;
  readonly credentials: Credentials;
  readonly credentialState: State["credentials"];
};

export function mergeSettings(saved: Settings | null, config: RuntimeConfig): Settings {
  const base = saved ?? defaultSettings;
  const envRemote = config.envSettings.remote;
  return {
    regions: config.envSettings.regions ?? base.regions,
    cadence: config.envSettings.cadence ?? base.cadence,
    threads: config.envSettings.threads ?? base.threads,
    remote: { ...base.remote, ...envRemote },
  };
}

export function effectiveSettings(storeSettings: Settings | null, savedCreds: Credentials, config: RuntimeConfig): EffectiveSettings {
  const settings = mergeSettings(storeSettings, config);
  const credentials = {
    accessKey: config.envCredentials.accessKey ?? savedCreds.accessKey,
    secretKey: config.envCredentials.secretKey ?? savedCreds.secretKey,
  };
  return {
    settings,
    credentials,
    credentialState: {
      access_key: credentialSource(config.envCredentials.accessKey, savedCreds.accessKey),
      secret_key: credentialSource(config.envCredentials.secretKey, savedCreds.secretKey),
    },
  };
}

export function validateSettings(settings: Settings, catalog: RegionCatalog): void {
  if (!validateRegionSelection(settings.regions, catalog)) throw new HttpStatusError(400, "invalid region selection");
  if (new Set(settings.regions).size !== settings.regions.length) throw new HttpStatusError(422, "Select each region only once");
  if (settings.cadence !== "manual" && settings.regions.length === 0) throw new HttpStatusError(422, "Select regions before scheduling builds");
  if (!endpointAllowed(settings.remote.endpoint)) throw new HttpStatusError(400, "invalid remote endpoint");
  if (!bucketAllowed(settings.remote.bucket)) throw new HttpStatusError(400, "invalid remote bucket");
  if (!/^[a-zA-Z0-9-]{0,64}$/.test(settings.remote.region)) throw new HttpStatusError(422, "Invalid bucket region");
}

export function ensureRemoteReady(effective: EffectiveSettings): void {
  if (!effective.settings.remote.enabled) throw new HttpStatusError(409, "remote publishing is disabled");
  if (!effective.settings.remote.endpoint || !effective.settings.remote.bucket) throw new HttpStatusError(422, "Set the endpoint and bucket before publishing");
  if (effective.credentials.accessKey === null || effective.credentials.secretKey === null) {
    throw new HttpStatusError(409, "remote credentials are not configured");
  }
}

export function rejectOverriddenSettings(next: Settings, current: Settings, overrides: readonly string[]): void {
  for (const override of overrides) {
    const changed = settingValue(next, override) !== settingValue(current, override);
    if (changed) throw new HttpStatusError(409, `${override} is controlled by the environment`);
  }
}

function credentialSource(envValue: string | null, savedValue: string | null): State["credentials"]["access_key"] {
  if (envValue !== null) return { configured: true, source: "environment" };
  if (savedValue !== null && savedValue.length > 0) return { configured: true, source: "saved" };
  return { configured: false, source: "unset" };
}

function endpointAllowed(endpoint: string): boolean {
  if (endpoint.length === 0) return true;
  const url = URL.parse(endpoint);
  if (url === null || url.username !== "" || url.password !== "" || url.pathname !== "/" || url.search !== "" || url.hash !== "") return false;
  if (url.protocol === "https:") return true;
  return url.protocol === "http:" && (
    ["localhost", "127.0.0.1", "[::1]", "host.docker.internal", "minio"].includes(url.hostname)
    || /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(url.hostname)
  );
}

export function preserveOverrides(next: Settings, saved: Settings | null, config: RuntimeConfig): Settings {
  const base = saved ?? defaultSettings;
  const remote = next.remote;
  const fromEnv = config.envSettings;
  return {
    regions: fromEnv.regions === undefined ? next.regions : base.regions,
    cadence: fromEnv.cadence === undefined ? next.cadence : base.cadence,
    threads: fromEnv.threads === undefined ? next.threads : base.threads,
    remote: {
      enabled: fromEnv.remote?.enabled === undefined ? remote.enabled : base.remote.enabled,
      endpoint: fromEnv.remote?.endpoint === undefined ? remote.endpoint : base.remote.endpoint,
      bucket: fromEnv.remote?.bucket === undefined ? remote.bucket : base.remote.bucket,
      region: fromEnv.remote?.region === undefined ? remote.region : base.remote.region,
      provider: fromEnv.remote?.provider === undefined ? remote.provider : base.remote.provider,
    },
  };
}

function bucketAllowed(bucket: string): boolean {
  return bucket.length === 0 || /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket);
}

function settingValue(settings: Settings, path: string): string | number | boolean | readonly string[] {
  switch (path) {
    case "regions":
      return settings.regions.join(",");
    case "cadence":
      return settings.cadence;
    case "threads":
      return settings.threads;
    case "remote.endpoint":
      return settings.remote.endpoint;
    case "remote.bucket":
      return settings.remote.bucket;
    case "remote.enabled":
      return settings.remote.enabled;
    case "remote.region":
      return settings.remote.region;
    case "remote.provider":
      return settings.remote.provider;
    default:
      return "";
  }
}
