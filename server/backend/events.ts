import type { State, eventSchema } from "../shared/contracts";
import type { z } from "zod";

export type ServerEvent = z.infer<typeof eventSchema>;

type Listener = {
  readonly send: (event: ServerEvent) => void;
};

export class EventBus {
  readonly #listeners = new Set<Listener>();

  add(listener: Listener): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  state(state: State): void {
    this.emit({ type: "state", state });
  }

  log(jobId: string, sequence: number, text: string): void {
    this.emit({ type: "log", job_id: jobId, sequence, text });
  }

  private emit(event: ServerEvent): void {
    for (const listener of this.#listeners) listener.send(event);
  }
}
