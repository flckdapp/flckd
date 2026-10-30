import { join } from "node:path";
import type { RuntimeConfig } from "./config";
import type { Store } from "./db";
import type { EventBus } from "./events";
import type { JobRunner } from "./jobs";
import type { RegionCatalog } from "./regions";
import { effectiveSettings, ensureRemoteReady, validateSettings } from "./settings";
import { buildState } from "./state";

export function startScheduler(deps: {
  readonly store: Store; readonly config: RuntimeConfig; readonly runner: JobRunner;
  readonly events: EventBus; readonly regions: RegionCatalog;
}): () => void {
  const { store, config, runner, events, regions } = deps;
  let busy = false;
  const timer = setInterval(async () => {
    if (busy || store.activeJob() !== null) return;
    busy = true;
    try {
      const effective = effectiveSettings(store.settings(), store.credentials(), config);
      const cadence = effective.settings.cadence;
      store.schedule(cadence);
      const kind = isDue(store.nextDue()) ? "build" : isDue(store.camerasNextDue()) ? "cameras" : null;
      if (kind === null) return;
      // Advance first: missed runs coalesce, and a failure cannot create a retry storm.
      if (kind === "build") store.advanceSchedule(cadence);
      else store.advanceCameraSchedule(cadence);
      if (effective.settings.regions.length === 0) return;
      // Cameras attach to a published release; until the first build there is none.
      if (kind === "cameras" && !(await Bun.file(join(config.docroot, "v1", "manifest.json")).exists())) return;
      validateSettings(effective.settings, regions);
      if (effective.settings.remote.enabled) ensureRemoteReady(effective);
      runner.enqueue({ kind, settings: effective.settings, credentials: effective.credentials });
      events.state(await buildState(store, config, regions));
    } catch (error) {
      console.error("Scheduled job could not start:", error instanceof Error ? error.message : "unknown error");
    } finally { busy = false; }
  }, 1000);
  return () => clearInterval(timer);
}

function isDue(at: string | null): boolean {
  return at !== null && Date.parse(at) <= Date.now();
}
