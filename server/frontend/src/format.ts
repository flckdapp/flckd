// Shared formatting helpers (dates parsed as local time, like the public
// dashboard, so date-only strings never display a day early).

export function fmtBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "–";
  if (n >= 1073741824) return `${(n / 1073741824).toFixed(1)} GB`;
  if (n >= 1048576) return `${(n / 1048576).toFixed(1)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${n} B`;
}

function parseLocal(iso: string): Date | null {
  const s = /^\d{4}-\d{2}-\d{2}$/.test(iso) ? `${iso}T00:00:00` : iso;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function fmtDateTime(iso: string | null): string {
  if (iso === null || iso === "") return "–";
  const d = parseLocal(iso);
  return d === null
    ? iso
    : d.toLocaleString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      });
}
