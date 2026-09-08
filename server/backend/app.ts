import { existsSync } from "node:fs";
import { join, normalize, relative } from "node:path";
import { Hono } from "hono";
import type { Context } from "hono";
import { streamSSE } from "hono/streaming";
import { ZodError } from "zod";
import { jobSchema, settingsSchema } from "../shared/contracts";
import type { Job } from "../shared/contracts";
import { loadConfig, type RuntimeConfig } from "./config";
import { Store } from "./db";
import { EventBus, type ServerEvent } from "./events";
import { HttpStatusError } from "./errors";
import { JobRunner } from "./jobs";
import { loadRegions, type RegionCatalog } from "./regions";
import { credentialsInputSchema, manifestSchema } from "./schemas";
import { buildState } from "./state";
import { effectiveSettings, ensureRemoteReady, preserveOverrides, rejectOverriddenSettings, validateSettings } from "./settings";
import { startScheduler } from "./scheduler";

type AppDeps = {
  readonly config: RuntimeConfig;
  readonly store: Store;
  readonly events: EventBus;
  readonly regions: RegionCatalog;
  readonly runner: JobRunner;
  readonly stopScheduler: () => void;
};

export async function createApp(env: NodeJS.ProcessEnv = process.env): Promise<{ readonly app: Hono; readonly deps: AppDeps }> {
  const config = await loadConfig(env);
  const store = new Store(config.dbPath);
  await store.secure();
  store.markInterruptedOnStartup();
  const events = new EventBus();
  const regions = await loadRegions(config.regionSet);
  // A region can leave the catalog between releases. Saved settings naming one
  // would otherwise fail validation on every write, and the offending id has no
  // checkbox left to clear it with.
  const saved = store.settings();
  if (saved !== null) {
    const known = new Set(regions.map((region) => region.id));
    const kept = saved.regions.filter((id) => known.has(id));
    if (kept.length !== saved.regions.length) store.saveSettings({ ...saved, regions: kept });
  }
  const runner = new JobRunner(store, config, events);
  const stopScheduler = startScheduler({ config, store, events, regions, runner });
  const deps = { config, store, events, regions, runner, stopScheduler };
  store.schedule(effectiveSettings(store.settings(), store.credentials(), config).settings.cadence);
  const app = new Hono();

  app.onError((error, c) => {
    if (error instanceof HttpStatusError) return c.json({ detail: error.publicMessage }, error.status);
    if (error instanceof ZodError) return c.json({ detail: error.issues.map((issue) => ({ msg: issue.message })) }, 422);
    if (error instanceof SyntaxError) return c.json({ detail: "Invalid JSON request" }, 400);
    return c.json({ detail: "internal server error" }, 500);
  });

  app.use("*", async (c, next) => {
    guardHost(c.req.header("host"), config);
    if (c.req.path.startsWith("/api/")) {
      c.header("Cache-Control", "no-store");
    }
    if (["POST", "PUT", "PATCH", "DELETE"].includes(c.req.method)) guardMutation(c.req.header("x-flckd-request"), c.req.header("origin"), c.req.header("host"), c.req.header("sec-fetch-site"));
    await next();
  });

  app.get("/health", (c) => c.json({ ok: true }));

  app.get("/api/state", async (c) => c.json(await buildState(store, config, regions)));
  app.put("/api/settings", async (c) => {
    const next = settingsSchema.parse(await c.req.json());
    const current = effectiveSettings(store.settings(), store.credentials(), config).settings;
    validateSettings(next, regions);
    rejectOverriddenSettings(next, current, config.overrides);
    store.saveSettings(preserveOverrides(next, store.settings(), config));
    store.schedule(next.cadence);
    events.state(await buildState(store, config, regions));
    return c.json(await buildState(store, config, regions));
  });
  app.put("/api/credentials", async (c) => {
    const input = credentialsInputSchema.parse(await c.req.json());
    if ((input.access_key !== undefined && config.envCredentials.accessKey !== null) || (input.secret_key !== undefined && config.envCredentials.secretKey !== null)) throw new HttpStatusError(409, "Credentials supplied by the environment cannot be changed in the app");
    const saved = store.credentials();
    const next = { accessKey: applySecretEdit(saved.accessKey, input.access_key), secretKey: applySecretEdit(saved.secretKey, input.secret_key) };
    store.saveCredentials(next);
    events.state(await buildState(store, config, regions));
    return c.json(await buildState(store, config, regions));
  });
  app.post("/api/jobs", async (c) => c.json(jobSchema.parse(startJob("build", deps)), 202));
  app.post("/api/publish", async (c) => {
    await requireManifest(config.docroot);
    return c.json(jobSchema.parse(startJob("publish", deps)), 202);
  });
  app.post("/api/jobs/:id/cancel", async (c) => {
    const cancelled = runner.cancel(c.req.param("id"));
    events.state(await buildState(store, config, regions));
    return c.json(jobSchema.parse(cancelled), 202);
  });
  app.get("/api/jobs/:id/logs", (c) => {
    if (!store.jobs().some((job) => job.id === c.req.param("id"))) throw new HttpStatusError(404, "job not found");
    return c.json(store.logs(c.req.param("id")));
  });
  app.get("/api/events", async (c) => streamSSE(c, async (stream) => {
    c.header("X-Accel-Buffering", "no");
    await stream.writeSSE({ event: "message", data: JSON.stringify({ type: "state", state: await buildState(store, config, regions) } satisfies ServerEvent) });
    let pending = 0;
    const send = (event: ServerEvent) => {
      if (++pending > 64) { stream.abort(); return; }
      void stream.writeSSE({ event: "message", data: JSON.stringify(event) }).catch(() => stream.abort()).finally(() => { pending--; });
    };
    const remove = events.add({ send });
    const heartbeat = setInterval(() => {
      void stream.writeSSE({ event: "heartbeat", data: "{}" }).catch(() => stream.abort());
    }, 15_000);
    await new Promise<void>((resolve) => stream.onAbort(() => {
      clearInterval(heartbeat);
      remove();
      resolve();
    }));
  }));

  app.get("/logo.png", async (c) => staticFile(c, join(config.siteDir, "logo.png")));
  app.get("*", async (c) => staticFile(c, safeStaticPath(config.frontendDir, c.req.path) ?? join(config.frontendDir, "index.html")));
  return { app, deps };
}

function startJob(kind: "build" | "publish", deps: AppDeps): Job {
  const effective = effectiveSettings(deps.store.settings(), deps.store.credentials(), deps.config);
  validateSettings(effective.settings, deps.regions);
  if (kind === "build" && effective.settings.regions.length === 0) throw new HttpStatusError(422, "Select at least one region");
  if (kind === "publish") ensureRemoteReady(effective);
  if (effective.settings.remote.enabled) ensureRemoteReady(effective);
  return deps.runner.enqueue({ kind, settings: effective.settings, credentials: effective.credentials });
}

async function requireManifest(docroot: string): Promise<void> {
  const manifest = Bun.file(join(docroot, "v1", "manifest.json"));
  if (!(await manifest.exists())) throw new HttpStatusError(409, "no published site manifest found");
  manifestSchema.parse(await manifest.json());
}

function applySecretEdit(current: string | null, edit: string | undefined): string | null {
  if (edit === undefined) return current;
  return edit.length === 0 ? null : edit;
}

function guardHost(host: string | undefined, config: RuntimeConfig): void {
  const hostname = host?.startsWith("[") ? host.slice(0, host.indexOf("]") + 1) : host?.split(":")[0] ?? "";
  const allowed = ["localhost", "127.0.0.1", "[::1]", ...config.allowedHosts];
  if (!allowed.includes(hostname)) throw new HttpStatusError(403, "host is not allowed");
}

function guardMutation(requestHeader: string | undefined, origin: string | undefined, host: string | undefined, fetchSite: string | undefined): void {
  if (requestHeader !== "1") throw new HttpStatusError(403, "mutation header required");
  if (origin !== undefined && host !== undefined && origin !== `http://${host}` && origin !== `https://${host}`) throw new HttpStatusError(403, "origin is not allowed");
  if (fetchSite !== undefined && fetchSite !== "same-origin" && fetchSite !== "none") throw new HttpStatusError(403, "cross-site mutation rejected");
}

async function staticFile(_c: Context, path: string): Promise<Response> {
  const asset = Bun.file(path);
  if (!(await asset.exists())) return new Response("not found", { status: 404 });
  return new Response(asset);
}

function safeStaticPath(root: string, requestPath: string): string | null {
  const normalized = normalize(requestPath).replace(/^\/+/, "");
  const candidate = join(root, normalized === "" ? "index.html" : normalized);
  if (relative(root, candidate).startsWith("..")) return null;
  return existsSync(candidate) ? candidate : null;
}
