import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { tileHandler } from "./tiles";

let root: string;
let server: ReturnType<typeof Bun.serve>;
const pack = `/v1/packs/${"a".repeat(64)}/part-0000.tar`;
beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), "flckd-tiles-"));
  await mkdir(join(root, "v1", "packs", "a".repeat(64)), { recursive: true });
  await Bun.write(join(root, pack), "0123456789");
  await Bun.write(join(root, "index.html"), "<main>Public site</main>");
  await Bun.write(join(root, "control.sqlite"), "PRIVATE");
  server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: tileHandler(root) });
});
afterAll(async () => { server.stop(true); await rm(root, { recursive: true }); });

test("serves byte ranges and conditional requests through Bun", async () => {
  const response = await fetch(new URL(pack, server.url), { headers: { Range: "bytes=2-5" } });
  expect(response.status).toBe(206);
  expect(response.headers.get("content-range")).toBe("bytes 2-5/10");
  expect(await response.text()).toBe("2345");
  expect(response.headers.get("cache-control")).toContain("immutable");
  const cached = await fetch(new URL(pack, server.url), { headers: { "If-None-Match": response.headers.get("etag") ?? "" } });
  expect(cached.status).toBe(304);
  const invalid = await fetch(new URL(pack, server.url), { headers: { Range: "bytes=90-100" } });
  expect(invalid.status).toBe(416);
});

test("never serves private files or builder API paths", async () => {
  for (const path of ["/api/state", "/control.sqlite", "/v1/packs/COMPLETE", "/.env"]) {
    expect((await fetch(new URL(path, server.url))).status).toBe(404);
  }
  expect((await fetch(new URL("/", server.url))).status).toBe(200);
});
