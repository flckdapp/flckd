import { createApp } from "./app";
import { tileHandler } from "./tiles";

const control = process.env["BUILDER_ENABLED"] === "false" ? null : await createApp();
const tiles = Bun.serve({
  hostname: process.env["TILE_BIND"] ?? "0.0.0.0",
  port: Number(process.env["TILE_PORT"] ?? 8080),
  idleTimeout: 60,
  fetch: tileHandler(process.env["DOCROOT"] ?? "/site"),
});

const server = control === null ? null : Bun.serve({
  idleTimeout: 60,
  hostname: control.deps.config.bind,
  port: control.deps.config.port,
  fetch: control.app.fetch,
});

let stopping = false;
async function shutdown(): Promise<void> {
  if (stopping) return;
  stopping = true;
  server?.stop(true);
  tiles.stop(true);
  if (control !== null) {
    control.deps.stopScheduler();
    await control.deps.runner.shutdown();
    control.deps.store.close();
  }
  process.exit(0);
}
process.on("SIGTERM", () => { void shutdown(); });
process.on("SIGINT", () => { void shutdown(); });
