export class Redactor {
  readonly #secrets: readonly string[];
  #carry = "";
  readonly #decoder = new TextDecoder();

  constructor(secrets: readonly string[]) {
    this.#secrets = secrets.filter((secret) => secret.length > 0).sort((left, right) => right.length - left.length);
  }

  push(chunk: Uint8Array): string {
    const text = this.#carry + this.#decoder.decode(chunk, { stream: true });
    const keep = Math.max(0, Math.max(...this.#secrets.map((secret) => secret.length), 1) - 1);
    let safeLength = Math.max(0, text.length - keep);
    for (const secret of this.#secrets) {
      let position = text.indexOf(secret);
      while (position >= 0) {
        if (position < safeLength && position + secret.length > safeLength) safeLength = position;
        position = text.indexOf(secret, position + 1);
      }
    }
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
