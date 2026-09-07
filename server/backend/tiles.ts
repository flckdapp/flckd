import { realpath } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

export function tileHandler(directory: string): (request: Request) => Promise<Response> {
  const root = resolve(directory);
  return async (request) => {
    if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
    const path = new URL(request.url).pathname;
    if (path === "/health") return new Response(request.method === "HEAD" ? null : "ok\n", { headers: { "Cache-Control": "no-store" } });
    const publicPath = path === "/" ? "/index.html" : path;
    const immutable = /^\/v1\/packs\/[a-f0-9]{64}\/part-\d+\.tar$/.test(publicPath)
      || /^\/v1\/releases\/[a-zA-Z0-9_-]+\/manifest\.json$/.test(publicPath);
    if (!immutable && !["/index.html", "/logo.png", "/v1/manifest.json", "/v1/build-status.json"].includes(publicPath)) return new Response(null, { status: 404 });
    let filePath: string;
    try { filePath = await realpath(join(root, publicPath)); }
    catch (error) {
      if (error instanceof Error && "code" in error && ["ENOENT", "ENOTDIR"].includes(String(error.code))) return new Response(null, { status: 404 });
      return new Response(null, { status: 500 });
    }
    if (relative(await realpath(root), filePath).startsWith("..")) return new Response(null, { status: 404 });
    const file = Bun.file(filePath);
    const size = file.size;
    const etag = publicPath.endsWith(".json")
      ? `"${new Bun.CryptoHasher("sha256").update(await file.arrayBuffer()).digest("hex")}"`
      : `"${size.toString(16)}-${Math.floor(file.lastModified).toString(16)}"`;
    const modified = new Date(file.lastModified).toUTCString();
    const headers = new Headers({
      "Accept-Ranges": "bytes", ETag: etag, "Last-Modified": modified,
      "X-Content-Type-Options": "nosniff",
      "Content-Type": publicPath.endsWith(".tar") ? "application/octet-stream" : file.type,
      "Cache-Control": immutable ? "public, max-age=31536000, immutable, stale-if-error=2592000"
        : publicPath === "/v1/build-status.json" ? "no-store"
        : publicPath === "/v1/manifest.json" ? "public, max-age=60, stale-while-revalidate=600, stale-if-error=2592000"
        : "public, max-age=300",
    });
    const ifNone = request.headers.get("if-none-match");
    if (ifNone?.split(",").some((tag) => tag.trim().replace(/^W\//, "") === etag || tag.trim() === "*")
      || (!ifNone && request.headers.get("if-modified-since") && Date.parse(request.headers.get("if-modified-since") ?? "") >= Math.floor(file.lastModified / 1000) * 1000)) return new Response(null, { status: 304, headers });
    const range = request.headers.get("range");
    const ifRange = request.headers.get("if-range");
    if (range && (!ifRange || ifRange === etag || ifRange === modified)) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (match && (match[1] || match[2])) {
        const start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
        const end = match[1] && match[2] ? Math.min(size - 1, Number(match[2])) : size - 1;
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || start > end) {
          headers.set("Content-Range", `bytes */${size}`);
          return new Response(null, { status: 416, headers });
        }
        headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
        headers.set("Content-Length", String(end - start + 1));
        return new Response(request.method === "HEAD" ? null : file.slice(start, end + 1), { status: 206, headers });
      }
    }
    headers.set("Content-Length", String(size));
    return new Response(request.method === "HEAD" ? null : file, { headers });
  };
}
