// App: owns server state, the settings form (dirty state survives SSE
// events), job selection, and the log fetch with a generation guard so a
// slow response for a previously-selected job can't clobber the current one.
// The activity sidebar and the settings/actions/log column are laid out
// side by side by .app-shell in styles.css.

import { useCallback, useEffect, useRef, useState } from "react";
import { Button, Callout, Flex, Spinner, Text } from "@radix-ui/themes";
import { Ban, Play, RefreshCw, TriangleAlert, Upload } from "lucide-react";

import {
  errText,
  getLogs,
  getState,
  postCancel,
  postJob,
  postPublish,
  putSettings,
} from "./api";
import { useEvents, useLogBuffer } from "./events";
import { JobPanel } from "./activity";
import { ActivitySidebar } from "./sidebar";
import { BucketCard } from "./bucket";
import { SettingsCard } from "./settings";
import { isLive } from "./jobmeta";
import { ErrorBanner, Header, Page } from "./shell";
import { settingsSchema } from "../../shared/contracts";
import type { Settings, State } from "../../shared/contracts";

function settingsEqual(a: Settings, b: Settings): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function latestJobId(s: State): string {
  const sorted = [...s.jobs].sort((a, b) => b.created_at.localeCompare(a.created_at));
  return s.active_job_id ?? sorted[0]?.id ?? "";
}

export function App() {
  const [state, setState] = useState<State | null>(null);
  const [form, setForm] = useState<Settings | null>(null);
  const baselineRef = useRef<Settings | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState<null | "save" | "build" | "publish" | "cancel">(null);
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [resyncTick, setResyncTick] = useState(0);

  const applyState = useCallback((s: State) => {
    setState(s);
    setSelectedJobId((prev) => prev || latestJobId(s));
    const baseline = baselineRef.current;
    setForm((f) =>
      f !== null && baseline !== null && !settingsEqual(f, baseline) ? f : s.settings,
    );
    baselineRef.current = s.settings;
  }, []);

  const refresh = useCallback(async () => {
    try {
      applyState(await getState());
      setFatal(null);
    } catch (e) {
      setFatal(errText(e));
    }
  }, [applyState]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const logBuffer = useLogBuffer(`${selectedJobId ?? "none"}:${resyncTick}`);

  useEffect(() => {
    const jobId = selectedJobId;
    if (!jobId) return;
    let cancelled = false;
    void (async () => {
      try {
        const logs = await getLogs(jobId);
        if (!cancelled) logBuffer.apply(logs.entries, logs.truncated);
      } catch (e) {
        if (cancelled) return;
        setActionError(errText(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedJobId, resyncTick, logBuffer.apply]);

  const connected = useEvents({
    onState: applyState,
    onLog: (jobId, entry) => {
      if (jobId === selectedJobId) logBuffer.apply([entry], logBuffer.truncated);
    },
    onResync: () => {
      setResyncTick((t) => t + 1);
      void refresh();
    },
  });

  const dirty =
    form !== null && state !== null && !settingsEqual(form, state.settings);

  function handleError(e: unknown): void {
    setActionError(errText(e));
  }

  async function save(): Promise<void> {
    if (form === null || state === null || !dirty || busy !== null) return;
    const checked = settingsSchema.safeParse(form);
    if (!checked.success) {
      setActionError(
        `Settings are not valid: ${checked.error.issues[0]?.message ?? "unknown issue"}`,
      );
      return;
    }
    setBusy("save");
    setActionError(null);
    try {
      await putSettings(checked.data);
      await refresh();
    } catch (e) {
      handleError(e);
    } finally {
      setBusy(null);
    }
  }

  async function start(kind: "build" | "publish"): Promise<void> {
    if (busy !== null || (kind === "build" && dirty)) return;
    setBusy(kind);
    setActionError(null);
    try {
      const job = kind === "build" ? await postJob() : await postPublish();
      setSelectedJobId(job.id);
      await refresh();
    } catch (e) {
      handleError(e);
    } finally {
      setBusy(null);
    }
  }

  async function cancel(): Promise<void> {
    if (busy !== null || state === null) return;
    const activeJob = state.jobs.find((j) => j.id === state.active_job_id) ?? null;
    if (activeJob === null || !isLive(activeJob)) return;
    setBusy("cancel");
    setActionError(null);
    try {
      await postCancel(activeJob.id);
      await refresh();
    } catch (e) {
      handleError(e);
    } finally {
      setBusy(null);
    }
  }

  if (fatal !== null)
    return (
      <Page>
        <Callout.Root color="red">
          <Callout.Icon>
            <TriangleAlert size={16} />
          </Callout.Icon>
          <Callout.Text size="2">{fatal}</Callout.Text>
        </Callout.Root>
        <div>
          <Button variant="soft" onClick={() => void refresh()}>
            <RefreshCw size={13} /> Retry
          </Button>
        </div>
      </Page>
    );

  if (state === null || form === null)
    return (
      <Flex align="center" justify="center" style={{ minHeight: "100vh" }}>
        <Spinner size="3" />
      </Flex>
    );

  const activeJob = state.jobs.find((j) => j.id === state.active_job_id) ?? null;
  const running = activeJob !== null && isLive(activeJob);

  return (
    <Page>
      <Header
        connected={connected}
      />
      {actionError !== null ? (
        <ErrorBanner text={actionError} onDismiss={() => setActionError(null)} />
      ) : null}
      <div className="app-shell">
        <ActivitySidebar
          state={state}
          selectedJobId={selectedJobId}
          onSelectJob={setSelectedJobId}
        />
        <div className="app-main">
          <SettingsCard
            state={state}
            form={form}
            onChange={setForm}
            dirty={dirty}
            saving={busy === "save"}
            onSave={() => void save()}
          />
          <BucketCard
            state={state}
            form={form}
            onChange={setForm}
            dirty={dirty}
            onSync={() => void refresh()}
          />
          <Flex gap="3" wrap="wrap" align="center">
            <Button
              onClick={() => void start("build")}
              disabled={dirty || running || busy !== null || state.settings.regions.length === 0}
            >
              {busy === "build" ? <Spinner size="1" /> : <Play size={13} />}
              Build now
            </Button>
            <Button
              variant="soft"
              onClick={() => void start("publish")}
              disabled={dirty || running || busy !== null || !state.settings.remote.enabled}
            >
              {busy === "publish" ? <Spinner size="1" /> : <Upload size={13} />}
              Publish existing site
            </Button>
            {activeJob !== null && isLive(activeJob) ? (
              <Button
                color="red"
                variant="soft"
                onClick={() => void cancel()}
                disabled={busy !== null}
              >
                {busy === "cancel" ? <Spinner size="1" /> : <Ban size={13} />}
                Cancel build
              </Button>
            ) : null}
            {dirty ? (
              <Text size="2" color="gray">
                Save settings first — builds use saved settings.
              </Text>
            ) : null}
          </Flex>
          <JobPanel
            state={state}
            selectedJobId={selectedJobId}
            logs={logBuffer.entries}
            logsTruncated={logBuffer.truncated}
          />
        </div>
      </div>
      <Text as="div" size="1" color="gray" style={{ textAlign: "center" }}>
        The builder keeps pipeline logs only — no request logs, ever.
      </Text>
    </Page>
  );
}
