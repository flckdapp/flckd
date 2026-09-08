import { afterEach, describe, expect, it } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createApp } from "./app";
import { defaultSettings } from "./config";
import { emptyLine, renderChunk } from "./jobs";
import { Redactor } from "./redact";
import { stateSchema } from "../shared/contracts";
import { Store } from "./db";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })));
  roots.length = 0;
});

describe("backend boundaries", () => {
  it("redacts every split boundary without damaging UTF-8", () => {
    const bytes = new TextEncoder().encode("hello café secret-value end");
    for (let i = 0; i <= bytes.length; i++) {
      const redactor = new Redactor(["secret-value"]);
      expect(redactor.push(bytes.subarray(0, i)) + redactor.push(bytes.subarray(i)) + redactor.flush()).toBe("hello café [REDACTED] end");
    }
  });

  it("renders a meter as a terminal would, across the chunks it arrives in", () => {
    const render = (chunks: readonly string[]): { lines: string[]; partial: string } => {
      let state = emptyLine;
      const lines: string[] = [];
      for (const chunk of chunks) {
        const next = renderChunk(state, chunk);
        lines.push(...next.completed);
        state = next.state;
      }
      return { lines, partial: state.line };
    };

    expect(render(["plain text\nsecond line\n"]).lines).toEqual(["plain text\n", "second line\n"]);
    expect(render(["windows\r\nline\r\n"]).lines).toEqual(["windows\n", "line\n"]);

    // One write per redraw is how curl and rclone emit a meter.
    const meter = render(["meter 25%\r", "meter 50%\r", "meter 100%\r", "\ndone\n"]);
    expect(meter.lines).toEqual(["meter 100%\n", "done\n"]);
    expect(meter.partial).toBe("");

    // A shorter redraw leaves the tail of the longer line, exactly as a terminal does.
    expect(render(["100%\r", "7%"]).partial).toBe("7%0%");
    expect(render(["abc", "\rZ"]).partial).toBe("Zbc");
  });

  it("cancels a running job and records it as cancelled rather than failed", async () => {
    const fixture = await makeFixture({});
    const { app, deps } = await createApp(fixture.env);
    const headers = { host: "127.0.0.1", "X-FLCKD-Request": "1", "Content-Type": "application/json" };
    try {
      deps.store.saveSettings({ ...defaultSettings, regions: ["oklahoma"] });
      expect((await app.request("/api/jobs", { method: "POST", headers })).status).toBe(202);
      const started = deps.store.activeJob();
      expect(started).not.toBeNull();
      expect((await app.request(`/api/jobs/${started?.id ?? ""}/cancel`, { method: "POST", headers })).status).toBe(202);
      const deadline = Date.now() + 5000;
      while (deps.store.activeJob() !== null && Date.now() < deadline) await Bun.sleep(30);
      expect(deps.store.jobs()[0]?.status).toBe("cancelled");
      expect((await app.request(`/api/jobs/${started?.id ?? ""}/cancel`, { method: "POST", headers })).status).toBe(409);
    } finally { deps.stopScheduler(); await deps.runner.shutdown(); deps.store.close(); }
  });

  it("redacts split secrets without stranding the end of a line", () => {
    const secret = "R2SECRET".repeat(5);
    const enc = (s: string): Uint8Array => new TextEncoder().encode(s);

    // A line holding no secret must arrive whole, not minus a trailing window.
    const plain = new Redactor([secret]);
    const line = '2026/09/08 05:48:43 NOTICE: Config file "/.rclone.conf" not found\n';
    expect(plain.push(enc(line))).toBe(line);
    expect(plain.flush()).toBe("");

    // A secret split across chunks is still caught.
    const split = new Redactor([secret]);
    const first = split.push(enc(`key=${secret.slice(0, 12)}`));
    const second = split.push(enc(`${secret.slice(12)} done\n`));
    expect(first + second + split.flush()).toBe("key=[REDACTED] done\n");
    expect(first + second).not.toContain(secret.slice(0, 12));
  });

  it("drops saved regions that have left the catalog", async () => {
    const fixture = await makeFixture({});
    const first = await createApp(fixture.env);
    try {
      first.deps.store.saveSettings({ ...defaultSettings, regions: ["oklahoma", "atlantis"] });
    } finally { first.deps.stopScheduler(); first.deps.store.close(); }

    const { app, deps } = await createApp(fixture.env);
    const headers = { host: "127.0.0.1", "X-FLCKD-Request": "1", "Content-Type": "application/json" };
    try {
      expect(deps.store.settings()?.regions).toEqual(["oklahoma"]);
      const body = JSON.stringify({ ...defaultSettings, regions: ["oklahoma"] });
      expect((await app.request("/api/settings", { method: "PUT", headers, body })).status).toBe(200);
    } finally { deps.stopScheduler(); deps.store.close(); }
  });

  it("opens locally without login but rejects foreign browser mutations", async () => {
    const fixture = await makeFixture({});
    const { app, deps } = await createApp(fixture.env);
    const headers = { host: "127.0.0.1", "X-FLCKD-Request": "1", "Content-Type": "application/json" };
    try {
      expect((await app.request("/api/state", { headers })).status).toBe(200);
      expect((await app.request("/api/credentials", { method: "PUT", headers: { ...headers, origin: "https://foreign.invalid" }, body: "{}" })).status).toBe(403);
      expect((await app.request("/api/credentials", { method: "PUT", headers: { host: "127.0.0.1" }, body: "{}" })).status).toBe(403);
      expect((await app.request("/api/state", { headers: { host: "foreign.invalid" } })).status).toBe(403);
    } finally { deps.stopScheduler(); deps.store.close(); }
  });

  it("coalesces missed schedule intervals into one job", async () => {
    const fixture = await makeFixture({});
    const { deps } = await createApp(fixture.env);
    try {
      deps.store.saveSettings({ ...defaultSettings, regions: ["oklahoma"], cadence: "daily" });
      deps.store.schedule("daily", 0);
      const deadline = Date.now() + 5000;
      while (deps.store.jobs().length === 0 && Date.now() < deadline) await Bun.sleep(30);
      expect(deps.store.jobs()).toHaveLength(1);
      expect(Date.parse(deps.store.nextDue() ?? "")).toBeGreaterThan(Date.now());
      while (deps.store.activeJob() !== null && Date.now() < deadline) await Bun.sleep(30);
      expect(deps.store.jobs()).toHaveLength(1);
      expect(deps.store.jobs()[0]?.status).toBe("succeeded");
    } finally { deps.stopScheduler(); await deps.runner.shutdown(); deps.store.close(); }
  });

  it("persists schedule anchors without moving them on unchanged settings", async () => {
    const root = await mkdtemp(join(import.meta.dir, ".tmp-"));
    roots.push(root);
    const store = new Store(join(root, "test.sqlite"));
    store.schedule("daily", 0);
    store.schedule("daily", 5000);
    expect(store.nextDue()).toBe("1970-01-02T00:00:00.000Z");
    store.advanceSchedule("daily", 86400_000 * 7);
    expect(store.nextDue()).toBe("1970-01-09T00:00:00.000Z");
    store.schedule("manual");
    expect(store.nextDue()).toBeNull();
    store.close();
  });

  it("preserves saved remote fields when just one field is overridden", async () => {
    const fixture = await makeFixture({ S3_REGION: "override-region" });
    const { app, deps } = await createApp(fixture.env);
    try {
      deps.store.saveSettings({ ...defaultSettings, remote: { ...defaultSettings.remote, endpoint: "https://saved.example", bucket: "saved-bucket" } });
      const response = await app.request("/api/state", { headers: { host: "127.0.0.1" } });
      const state = stateSchema.parse(await response.json());
      expect(state.settings.remote.endpoint).toBe("https://saved.example");
      expect(state.settings.remote.bucket).toBe("saved-bucket");
      expect(state.settings.remote.region).toBe("override-region");
    } finally { deps.stopScheduler(); deps.store.close(); }
  });

  it("runs one fixture job through HTTP and persists redacted logs", async () => {
    const fixture = await makeFixture({ S3_ACCESS_KEY_ID: "fixture-key", S3_SECRET_ACCESS_KEY: "fixture-secret" });
    const { app, deps } = await createApp(fixture.env);
    const headers = { host: "127.0.0.1", "X-FLCKD-Request": "1", "Content-Type": "application/json" };
    try {
      const bad = await app.request("/api/settings", { method: "PUT", headers, body: "{}" });
      expect(bad.status).toBe(422);
      const settings = { ...defaultSettings, regions: ["oklahoma"], remote: { enabled: true, endpoint: "https://fail.invalid", bucket: "fixture-bucket", provider: "Other", region: "auto" } };
      expect((await app.request("/api/settings", { method: "PUT", headers, body: JSON.stringify(settings) })).status).toBe(200);
      expect((await app.request("/api/jobs", { method: "POST", headers })).status).toBe(202);
      expect((await app.request("/api/jobs", { method: "POST", headers })).status).toBe(409);
      const deadline = Date.now() + 5000;
      while (deps.store.activeJob() !== null && Date.now() < deadline) await Bun.sleep(30);
      const job = deps.store.jobs()[0];
      expect(job?.status).toBe("succeeded");
      expect(job?.local_published).toBe(true);
      const logs = deps.store.logs(job?.id ?? "").entries.map((e) => e.text).join("");
      expect(logs).not.toContain("fixture-secret");
      expect(logs).toContain("[REDACTED]");
      expect(deps.store.jobs()).toHaveLength(1);
    } finally { deps.stopScheduler(); await deps.runner.shutdown(); deps.store.close(); }
  });
  it("redacts a secret split across chunks", () => {
    // Given
    const redactor = new Redactor(["secret-value"]);

    // When
    const first = redactor.push(new TextEncoder().encode("before secret"));
    const second = redactor.push(new TextEncoder().encode("-value after")) + redactor.flush();

    // Then
    expect(`${first}${second}`).toBe("before [REDACTED] after");
  });

  it("persists settings while environment overrides remain authoritative", async () => {
    // Given
    const fixture = await makeFixture({ S3_BUCKET: "env-bucket", S3_SECRET_ACCESS_KEY: "env-secret" });
    const { app, deps } = await createApp(fixture.env);
    const saved = { ...defaultSettings, regions: ["oklahoma"], remote: { ...defaultSettings.remote, enabled: false, bucket: "saved-bucket" } };

    // When
    deps.store.saveSettings(saved);
    const response = await app.request("/api/state", { headers: { host: "127.0.0.1" } });
    const state = await response.json();

    // Then
    expect(state.settings.remote.bucket).toBe("env-bucket");
    expect(state.credentials.secret_key.source).toBe("environment");
    expect(state.overrides).toContain("remote.bucket");
    deps.stopScheduler();
    deps.store.close();
  });
});

async function makeFixture(extraEnv: Record<string, string>): Promise<{ readonly env: NodeJS.ProcessEnv }> {
  const root = await mkdtemp(join(import.meta.dir, ".tmp-"));
  roots.push(root);
  const dataDir = join(root, "data");
  const docroot = join(root, "site");
  const frontend = join(root, "frontend");
  const regions = join(root, "regions.json");
  await mkdir(join(docroot, "v1"), { recursive: true });
  await mkdir(frontend, { recursive: true });
  await writeFile(join(frontend, "index.html"), "<main>fixture</main>");
  await writeFile(regions, JSON.stringify({ packs: [{ id: "oklahoma", name: "Oklahoma", iso3166_2: "US-OK" }] }));
  return {
    env: {
      DATA_DIR: dataDir,
      DOCROOT: docroot,
      BIN_DIR: join(import.meta.dir, "fixtures"),
      REGION_SET: regions,
      SITE_DIR: frontend,
      FRONTEND_DIR: frontend,
      ...extraEnv,
    },
  };
}
