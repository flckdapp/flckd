// Job metadata shared by the sidebar and the job panel: stage pipeline
// order, status badge colours (including "cancelled"), job liveness, and
// the cadence labels used by the schedule indicator.

import type { Job, Settings } from "../../shared/contracts";

const BUILD_STAGES = ["update-pbf", "cameras", "build-graph", "cut-packs", "publish", "upload"] as const;
const CAMERA_STAGES = ["update-pbf", "cameras", "publish", "upload"] as const;

export function stagesFor(kind: Job["kind"]): readonly string[] {
  return kind === "cameras" ? CAMERA_STAGES : BUILD_STAGES;
}

export const KIND_LABEL: Record<Job["kind"], string> = {
  build: "build",
  publish: "publish",
  cameras: "speed cameras",
};

export const STATUS_COLOR: Record<Job["status"], "gray" | "teal" | "green" | "red" | "amber" | "orange"> = {
  queued: "gray",
  running: "teal",
  succeeded: "green",
  failed: "red",
  interrupted: "amber",
  cancelled: "orange",
};

export function isLive(job: Job): boolean {
  return job.status === "queued" || job.status === "running";
}

export const CADENCES: { value: Settings["cadence"]; label: string }[] = [
  { value: "manual", label: "Manual" },
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "every_30_days", label: "Every 30 days" },
];
