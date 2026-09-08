export class Redactor {
  readonly #secrets: readonly string[];
  #carry = "";
  readonly #decoder = new TextDecoder();

  constructor(secrets: readonly string[]) {
    this.#secrets = secrets.filter((secret) => secret.length > 0).sort((left, right) => right.length - left.length);
  }

  push(chunk: Uint8Array): string {
    const text = this.#carry + this.#decoder.decode(chunk, { stream: true });
    // Hold back only a trailing run that could still grow into a secret.
    // Holding a fixed window instead would strand the end of the last line
    // until more output arrived, which during a quiet stage is never.
    let hold = 0;
    for (const secret of this.#secrets) {
      for (let length = Math.min(secret.length - 1, text.length); length > hold; length--) {
        if (text.endsWith(secret.slice(0, length))) {
          hold = length;
          break;
        }
      }
    }
    const safeLength = text.length - hold;
    this.#carry = text.slice(safeLength);
    return this.clean(text.slice(0, safeLength));
  }

  flush(): string {
    const text = this.clean(this.#carry + this.#decoder.decode());
    this.#carry = "";
    return text;
  }

  clean(value: string): string {
    return this.#secrets.reduce((text, secret) => text.split(secret).join("[REDACTED]"), value);
  }
}
