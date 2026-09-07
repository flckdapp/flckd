import { resolve } from "node:path";

process.chdir(resolve(import.meta.dir, ".."));
const env = { ...process.env, FLCKD_CONTROL_PORT: "8090", VITE_TILE_URL: `http://localhost:${process.env["FLCKD_TILE_PORT"] ?? "8080"}` };
async function docker(args: readonly string[]): Promise<void> {
  const child = Bun.spawn(["docker", ...args], { env, stdout: "inherit", stderr: "inherit" });
  if (await child.exited !== 0) throw new Error(`Docker command failed. Make sure Docker Desktop or OrbStack is running.`);
}
console.log("Starting the builder and tile server. The first run downloads the native tools; later runs use the cache.");
await docker(["info", "--format", "Docker {{.ServerVersion}}"]);
await docker(["compose", "-p", "flckd-dev", "up", "--build", "--wait"]);
console.log(`Builder: http://localhost:${process.env["FLCKD_UI_PORT"] ?? "8642"}\nPublic tiles: ${env.VITE_TILE_URL}\nPress Ctrl+C to stop development services.`);
const vite = Bun.spawn(["bun", "x", "vite"], { env, stdout: "inherit", stderr: "inherit" });
let stopping = false;
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  vite.kill();
  await docker(["compose", "-p", "flckd-dev", "stop"]);
}
process.on("SIGINT", () => { void stop(); });
process.on("SIGTERM", () => { void stop(); });
await vite.exited;
await stop();
