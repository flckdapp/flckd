export type HttpStatus = 400 | 401 | 403 | 404 | 409 | 422 | 500;

export class HttpStatusError extends Error {
  readonly name = "HttpStatusError";

  constructor(
    readonly status: HttpStatus,
    readonly publicMessage: string,
  ) {
    super(publicMessage);
  }
}

export class ProcessRunError extends Error {
  readonly name = "ProcessRunError";

  constructor(
    readonly jobId: string,
    readonly exitCode: number | null,
  ) {
    super(`job ${jobId} exited unsuccessfully`);
  }
}
