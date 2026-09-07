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
      store.schedule(effective.settings.cadence);
      const due = store.nextDue();
      if (due === null || Date.parse(due) > Date.now()) return;
      // Advance first: missed runs coalesce, and a failure cannot create a retry storm.
      store.advanceSchedule(effective.settings.cadence);
      validateSettings(effective.settings, regions);
      if (effective.settings.remote.enabled) ensureRemoteReady(effective);
      if (effective.settings.regions.length > 0) runner.enqueue({ kind: "build", settings: effective.settings, credentials: effective.credentials });
      events.state(await buildState(store, config, regions));
    } catch (error) {
      console.error("Scheduled build could not start:", error instanceof Error ? error.message : "unknown error");
    } finally { busy = false; }
  }, 1000);
  return () => clearInterval(timer);
}
