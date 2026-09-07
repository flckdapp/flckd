import { statfs } from "node:fs/promises";
import type { State } from "../shared/contracts";
import type { RuntimeConfig } from "./config";
import type { Store } from "./db";
import type { RegionCatalog } from "./regions";
import { effectiveSettings } from "./settings";

export async function buildState(store: Store, config: RuntimeConfig, regions: RegionCatalog): Promise<State> {
  const active = store.activeJob();
  const effective = effectiveSettings(store.settings(), store.credentials(), config);
  return {
    settings: effective.settings,
    regions,
    jobs: [...store.jobs()],
    next_due_at: store.nextDue(),
    active_job_id: active?.id ?? null,
    storage: { free_bytes: await freeBytes(config.dataDir), site_path: config.docroot },
    credentials: effective.credentialState,
    overrides: [...config.overrides],
  };
}

async function freeBytes(path: string): Promise<number> {
  const stats = await statfs(path);
  return stats.bavail * stats.bsize;
}
