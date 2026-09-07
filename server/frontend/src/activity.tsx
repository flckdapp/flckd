// Right-column job panel: the live stage pipeline with the backend-counted
// progress fraction (never an invented ETA), the selected job's summary
// badges, and the bounded stick-to-bottom log view. Job selection itself
// lives in the activity sidebar.

import { useEffect, useRef } from "react";
import {
  Badge,
  Card,
  Flex,
  Heading,
  Progress,
  Separator,
  Spinner,
  Text,
} from "@radix-ui/themes";
import { Activity, Check } from "lucide-react";

import { fmtBytes, fmtDateTime } from "./format";
import { STAGES, STATUS_COLOR, isLive } from "./jobmeta";
import type { LogEntry } from "./events";
import type { Job, State } from "../../shared/contracts";

function StageProgress({ job }: { job: Job }) {
  const idx = STAGES.findIndex((s) => s === job.stage);
  const live = isLive(job);
  const bar = !live ? null : (
    <Flex align="center" gap="2">
      {job.progress === null ? (
        <div
          className="progress-working"
          style={{ flexGrow: 1 }}
          role="progressbar"
          aria-label="Working, no countable steps in this stage"
        />
      ) : (
        <Progress size="1" value={job.progress * 100} style={{ flexGrow: 1 }} />
      )}
      <Text size="1" color="gray" style={{ flexShrink: 0 }}>
        {job.progress === null ? "working" : `${Math.round(job.progress * 100)}%`}
      </Text>
    </Flex>
  );
  if (idx === -1)
    return (
      <Flex direction="column" gap="2">
        <Text size="2" weight="medium">Stage: {job.stage}</Text>
        {bar}
        <Text size="2" color="gray">{job.detail}</Text>
      </Flex>
    );
  return (
    <Flex direction="column" gap="2">
      <Flex gap="4" wrap="wrap">
        {STAGES.map((stage, i) => {
          if (i < idx)
            return (
              <Flex key={stage} align="center" gap="1">
                <Check size={13} color="var(--green-9)" />
                <Text size="1" color="gray">{stage}</Text>
              </Flex>
            );
          if (i === idx)
            return (
              <Flex key={stage} align="center" gap="1">
                {live ? <Spinner size="1" /> : null}
                <Text size="1" weight="medium" color="teal">{stage}</Text>
              </Flex>
            );
          return (
            <Text key={stage} size="1" color="gray" style={{ opacity: 0.55 }}>
              {stage}
            </Text>
          );
        })}
      </Flex>
      {bar}
      <Text size="2" color="gray">{job.detail}</Text>
    </Flex>
  );
}

function OutcomeBadges({ job }: { job: Job }) {
  const finished = job.status !== "queued" && job.status !== "running";
  const local = job.local_published ? (
    <Badge color="green" variant="soft">Local site written</Badge>
  ) : (
    <Badge color="gray" variant="soft">{finished ? "No local output" : "Local pending"}</Badge>
  );
  const remote = !job.remote_enabled ? (
    <Badge color="gray" variant="soft">Bucket skipped</Badge>
  ) : job.remote_published ? (
    <Badge color="green" variant="soft">Bucket uploaded</Badge>
  ) : finished ? (
    <Badge color="red" variant="soft">Bucket failed</Badge>
  ) : (
    <Badge color="gray" variant="soft">Bucket pending</Badge>
  );
  return <Flex gap="2" wrap="wrap">{local}{remote}</Flex>;
}

export function JobPanel({
  state,
  selectedJobId,
  logs,
  logsTruncated,
}: {
  state: State;
  selectedJobId: string | null;
  logs: readonly LogEntry[];
  logsTruncated: boolean;
}) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const stick = useRef(true);

  useEffect(() => {
    const host = hostRef.current;
    if (host !== null && stick.current) host.scrollTop = host.scrollHeight;
  }, [logs]);

  const jobs = [...state.jobs].sort((a, b) => b.created_at.localeCompare(a.created_at));
  const activeJob = state.jobs.find((j) => j.id === state.active_job_id) ?? null;
  const running = activeJob !== null && isLive(activeJob);
  const selected = jobs.find((j) => j.id === selectedJobId) ?? activeJob ?? jobs[0] ?? null;

  return (
    <Card size="3">
      <Flex direction="column" gap="4">
        <Flex align="center" justify="between" gap="2" wrap="wrap">
          <Flex align="center" gap="2">
            <Activity size={16} color="var(--muted)" />
            <Heading size="4">Job details</Heading>
          </Flex>
          <Text size="1" color="gray">
            Site: {state.storage.site_path} · {fmtBytes(state.storage.free_bytes)} free
          </Text>
        </Flex>

        {activeJob !== null && running ? (
          <>
            <StageProgress job={activeJob} />
            <Text size="1" color="gray">
              Started {fmtDateTime(activeJob.started_at)} · settings snapshotted at start
            </Text>
            <Separator size="4" />
          </>
        ) : null}

        {selected !== null ? (
          <Flex direction="column" gap="2">
            <Flex gap="2" wrap="wrap" align="center">
              <Badge color={STATUS_COLOR[selected.status]} variant="soft">
                {selected.status}
              </Badge>
              <Badge color="gray" variant="soft">{selected.kind}</Badge>
              <Text size="1" color="gray">
                {selected.regions.length} regions
                {selected.exit_code !== null ? ` · exit ${selected.exit_code}` : ""}
              </Text>
            </Flex>
            <OutcomeBadges job={selected} />
            <Text size="1" color="gray">
              Created {fmtDateTime(selected.created_at)} · started{" "}
              {fmtDateTime(selected.started_at)} · finished{" "}
              {fmtDateTime(selected.finished_at)}
            </Text>
            {selected.id !== activeJob?.id || !running ? (
              <Text size="2" color="gray">
                Last stage: {selected.stage} — {selected.detail}
              </Text>
            ) : null}
          </Flex>
        ) : (
          <Text size="2" color="gray">
            No jobs yet — press Build now to start one.
          </Text>
        )}

        <Flex direction="column" gap="2">
          <Flex align="center" gap="2" wrap="wrap">
            <Text size="2" weight="medium">Logs</Text>
            {logsTruncated ? (
              <Text size="1" color="gray">
                Older lines were truncated by the server (1 MiB cap).
              </Text>
            ) : null}
          </Flex>
          <div
            ref={hostRef}
            className="log-scroll"
            style={{ height: 300, padding: "8px 10px" }}
            onScroll={(e) => {
              const host = e.currentTarget;
              stick.current =
                host.scrollHeight - host.scrollTop - host.clientHeight < 48;
            }}
          >
            {logs.length === 0 ? (
              <Text size="2" color="gray">
                No log output{selected !== null ? " for this job" : ""} yet.
              </Text>
            ) : (
              <div className="log-view">{logs.map((e) => e.text).join("")}</div>
            )}
          </div>
        </Flex>
      </Flex>
    </Card>
  );
}
