// Activity sidebar: the collapsible job-history rail plus the schedule
// indicator. Wide screens keep it beside the main column (~280px, ~48px
// collapsed into an icon rail); below Radix's sm breakpoint it becomes a
// full-width collapsible section stacked above the main column, so mobile
// never squeezes two columns.

import { useEffect, useState } from "react";
import {
  Badge,
  Card,
  Flex,
  Heading,
  IconButton,
  ScrollArea,
  Separator,
  Spinner,
  Text,
} from "@radix-ui/themes";
import {
  Activity,
  CalendarClock,
  History,
  PanelLeftClose,
  PanelLeftOpen,
  Play,
  Upload,
} from "lucide-react";

import { fmtDateTime } from "./format";
import { CADENCES, STATUS_COLOR, isLive } from "./jobmeta";
import type { Job, State } from "../../shared/contracts";

const DESKTOP = "(min-width: 768px)";

function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const mql = window.matchMedia(query);
    const onChange = (): void => setMatches(mql.matches);
    onChange();
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, [query]);
  return matches;
}

function scheduleText(state: State): string {
  if (state.settings.cadence === "manual") return "No scheduled builds";
  const label =
    CADENCES.find((c) => c.value === state.settings.cadence)?.label ??
    state.settings.cadence;
  if (state.next_due_at === null) return `${label} — starts one interval after saving`;
  return `${label} · next ${fmtDateTime(state.next_due_at)}`;
}

function JobRow({
  job,
  selected,
  onSelect,
}: {
  job: Job;
  selected: boolean;
  onSelect: (id: string) => void;
}) {
  return (
    <div
      role="button"
      tabIndex={0}
      className={`job-row${selected ? " selected" : ""}`}
      onClick={() => onSelect(job.id)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect(job.id);
        }
      }}
    >
      <Flex align="center" justify="between" gap="2">
        <Flex align="center" gap="2" minWidth="0">
          {job.kind === "build" ? <Play size={13} /> : <Upload size={13} />}
          <Text size="2" weight={selected ? "medium" : "regular"} truncate>
            {job.kind}
          </Text>
        </Flex>
        <Flex align="center" gap="2" style={{ flexShrink: 0 }}>
          {isLive(job) ? <Spinner size="1" /> : null}
          <Badge color={STATUS_COLOR[job.status]} variant="soft">
            {job.status}
          </Badge>
        </Flex>
      </Flex>
      <Text size="1" color="gray">
        {fmtDateTime(job.created_at)}
      </Text>
    </div>
  );
}

function JobIconRow({
  job,
  selected,
  onSelect,
}: {
  job: Job;
  selected: boolean;
  onSelect: (id: string) => void;
}) {
  return (
    <div
      role="button"
      tabIndex={0}
      title={`${job.kind} · ${fmtDateTime(job.created_at)} · ${job.status}`}
      className={`job-icon${selected ? " selected" : ""}`}
      onClick={() => onSelect(job.id)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect(job.id);
        }
      }}
    >
      {isLive(job) ? (
        <Spinner size="1" />
      ) : job.kind === "build" ? (
        <Play size={14} />
      ) : (
        <Upload size={14} />
      )}
    </div>
  );
}

export function ActivitySidebar({
  state,
  selectedJobId,
  onSelectJob,
}: {
  state: State;
  selectedJobId: string | null;
  onSelectJob: (id: string) => void;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const desktop = useMediaQuery(DESKTOP);
  const rail = collapsed && desktop;
  const jobs = [...state.jobs].sort((a, b) => b.created_at.localeCompare(a.created_at));
  const schedule = scheduleText(state);
  const selectedId = selectedJobId ?? state.active_job_id ?? jobs[0]?.id ?? null;

  return (
    <div className={`app-sidebar${collapsed ? " collapsed" : ""}`}>
      <Card size={rail ? "1" : "2"}>
        <Flex direction="column" gap="3">
          <Flex align="center" justify="between" gap="2">
            {rail ? null : (
              <Flex align="center" gap="2">
                <Activity size={16} color="var(--muted)" />
                <Heading size="4">Activity</Heading>
              </Flex>
            )}
            <IconButton
              variant="ghost"
              size="1"
              aria-label={collapsed ? "Expand activity sidebar" : "Collapse activity sidebar"}
              onClick={() => setCollapsed((c) => !c)}
            >
              {collapsed ? <PanelLeftOpen size={14} /> : <PanelLeftClose size={14} />}
            </IconButton>
          </Flex>

          {collapsed ? (
            <span title={schedule} className="sidebar-icon-hint">
              <CalendarClock size={16} color="var(--muted)" />
            </span>
          ) : (
            <Flex align="center" gap="2">
              <CalendarClock size={14} color="var(--muted)" />
              <Text size="1" color="gray">
                {schedule}
              </Text>
            </Flex>
          )}

          {collapsed && !desktop ? null : (
            <>
              <Separator size="2" />
              {jobs.length === 0 ? (
                rail ? (
                  <span title="No jobs yet" className="sidebar-icon-hint">
                    <History size={16} color="var(--muted)" />
                  </span>
                ) : (
                  <Text size="2" color="gray">
                    No jobs yet — press Build now to start one.
                  </Text>
                )
              ) : (
                <ScrollArea type="auto" scrollbars="vertical" style={{ height: 360 }}>
                  <Flex direction="column" gap="1" {...(rail ? {} : { pr: "2" as const })}>
                    {jobs.map((job) =>
                      rail ? (
                        <JobIconRow
                          key={job.id}
                          job={job}
                          selected={job.id === selectedId}
                          onSelect={onSelectJob}
                        />
                      ) : (
                        <JobRow
                          key={job.id}
                          job={job}
                          selected={job.id === selectedId}
                          onSelect={onSelectJob}
                        />
                      ),
                    )}
                  </Flex>
                </ScrollArea>
              )}
            </>
          )}
        </Flex>
      </Card>
    </div>
  );
}
