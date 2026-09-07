// SSE wiring: /api/events with the default 'message' event, plus a bounded
// per-job log buffer. Log lines are deduped by sequence so an initial
// /api/jobs/:id/logs fetch racing the SSE stream never shows a line twice;
// the newest ~1 MiB is kept for the DOM.

import { useCallback, useEffect, useRef, useState } from "react";

import { eventSchema } from "../../shared/contracts";
import type { State } from "../../shared/contracts";

export interface LogEntry {
  sequence: number;
  text: string;
}

const MAX_LOG_CHARS = 1_048_576;
const FLUSH_MS = 150;

export function useLogBuffer(jobKey: string): {
  entries: LogEntry[];
  truncated: boolean;
  apply: (incoming: readonly LogEntry[], truncated: boolean) => void;
} {
  const store = useRef(new Map<number, string>());
  const pending = useRef<LogEntry[]>([]);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastTruncated = useRef(false);
  const [snapshot, setSnapshot] = useState<{ entries: LogEntry[]; truncated: boolean }>({
    entries: [],
    truncated: false,
  });

  const flush = useCallback(() => {
    timer.current = null;
    const map = store.current;
    const incoming = pending.current;
    pending.current = [];
    for (const entry of incoming) map.set(entry.sequence, entry.text);
    let total = 0;
    for (const text of map.values()) total += text.length;
    while (total > MAX_LOG_CHARS && map.size > 1) {
      let min: number | null = null;
      for (const key of map.keys()) if (min === null || key < min) min = key;
      if (min === null) break;
      total -= map.get(min)?.length ?? 0;
      map.delete(min);
    }
    const entries = [...map.entries()]
      .sort(([a], [b]) => a - b)
      .map(([sequence, text]) => ({ sequence, text }));
    setSnapshot({ entries, truncated: lastTruncated.current });
  }, []);

  const apply = useCallback(
    (incoming: readonly LogEntry[], truncated: boolean) => {
      lastTruncated.current = truncated;
      pending.current.push(...incoming);
      if (timer.current === null) timer.current = setTimeout(flush, FLUSH_MS);
    },
    [flush],
  );

  useEffect(() => {
    store.current = new Map();
    pending.current = [];
    lastTruncated.current = false;
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
    setSnapshot({ entries: [], truncated: false });
  }, [jobKey]);

  useEffect(
    () => () => {
      if (timer.current !== null) clearTimeout(timer.current);
    },
    [],
  );

  return { entries: snapshot.entries, truncated: snapshot.truncated, apply };
}

export function useEvents(handlers: {
  onState: (state: State) => void;
  onLog: (jobId: string, entry: LogEntry) => void;
  onResync: () => void;
}): boolean {
  const [connected, setConnected] = useState(false);
  const ref = useRef(handlers);
  useEffect(() => {
    ref.current = handlers;
  });

  useEffect(() => {
    let source: EventSource | null = null;
    let retry: ReturnType<typeof setTimeout> | null = null;
    let hadSession = false;
    let disposed = false;

    const connect = (): void => {
      if (disposed) return;
      source = new EventSource("/api/events");
      source.onopen = () => {
        setConnected(true);
        if (hadSession) ref.current.onResync();
        hadSession = true;
      };
      source.onerror = () => {
        setConnected(false);
        // Browsers close the source for good on HTTP error statuses (e.g.
        // the 401 before login) instead of retrying; recreate it ourselves.
        if (source !== null && source.readyState === EventSource.CLOSED) {
          source.close();
          source = null;
          retry = setTimeout(connect, 3000);
        }
      };
      source.onmessage = (ev: MessageEvent<string>) => {
        try {
          const parsed = eventSchema.safeParse(JSON.parse(ev.data));
          if (!parsed.success) return;
          if (parsed.data.type === "state") ref.current.onState(parsed.data.state);
          else
            ref.current.onLog(parsed.data.job_id, {
              sequence: parsed.data.sequence,
              text: parsed.data.text,
            });
        } catch {
          // Ignore malformed frames; the reconnect resync recovers.
        }
      };
    };

    connect();
    return () => {
      disposed = true;
      if (retry !== null) clearTimeout(retry);
      source?.close();
    };
  }, []);

  return connected;
}
