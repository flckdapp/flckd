// API client: one generic zod-guarded request function, ky underneath.
// Mutations carry X-FLCKD-Request: 1. Hono errors ({detail: string | array})
// are surfaced as readable messages, never [object Object].

import ky, { HTTPError, TimeoutError } from "ky";
import { z } from "zod";
import {
  jobSchema,
  logSchema,
  settingsSchema,
  stateSchema,
} from "../../shared/contracts";
import type { Job, Settings, State } from "../../shared/contracts";

const client = ky.create({ retry: 0, timeout: 10_000 });

export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export function errText(e: unknown): string {
  return e instanceof ApiError ? e.message : "Unexpected error";
}

const errorBodySchema = z.object({
  detail: z.union([
    z.string().min(1),
    z.array(z.union([z.string(), z.object({ msg: z.string() })])).min(1),
  ]),
});

function detailText(detail: string | (string | { msg: string })[]): string {
  return typeof detail === "string"
    ? detail
    : detail.map((item) => (typeof item === "string" ? item : item.msg)).join("; ");
}

type Method = "GET" | "PUT" | "POST";

export async function api<S extends z.ZodType>(
  method: Method,
  path: string,
  schema: S,
  body?: unknown,
): Promise<z.output<S>> {
  let response: Response;
  try {
    response = await client(path, {
      method,
      ...(body === undefined ? {} : { json: body }),
      ...(method === "GET" ? {} : { headers: { "X-FLCKD-Request": "1" } }),
    });
  } catch (e) {
    if (e instanceof HTTPError) {
      const parsed = errorBodySchema.safeParse(
        await e.response.json().catch(() => undefined),
      );
      if (parsed.success) throw new ApiError(detailText(parsed.data.detail), e.response.status);
      throw new ApiError(
        `Request failed (${e.response.status} ${e.response.statusText})`.trim(),
        e.response.status,
      );
    }
    if (e instanceof TimeoutError) throw new ApiError("Request timed out", 0);
    throw new ApiError("Network error — is the builder running?", 0);
  }
  const text = await response.text();
  let data: unknown;
  try {
    data = text === "" ? undefined : JSON.parse(text);
  } catch {
    throw new ApiError(`Invalid JSON from ${path}`, 0);
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new ApiError(`Unexpected response from ${path}`, 0);
  return parsed.data;
}

export type Logs = z.infer<typeof logSchema>;

export const getState = (): Promise<State> => api("GET", "/api/state", stateSchema);

export const putSettings = (settings: Settings): Promise<unknown> =>
  api("PUT", "/api/settings", z.unknown(), settingsSchema.parse(settings));

export const putCredentials = (body: {
  access_key?: string;
  secret_key?: string;
}): Promise<unknown> => api("PUT", "/api/credentials", z.unknown(), body);

export const postJob = (): Promise<Job> => api("POST", "/api/jobs", jobSchema, {});

export const postPublish = (): Promise<Job> => api("POST", "/api/publish", jobSchema, {});

export const postCancel = (jobId: string): Promise<Job> =>
  api("POST", `/api/jobs/${encodeURIComponent(jobId)}/cancel`, jobSchema, {});

export const getLogs = (jobId: string): Promise<Logs> =>
  api("GET", `/api/jobs/${encodeURIComponent(jobId)}/logs`, logSchema);
