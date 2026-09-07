// Bucket credential fields, rendered inline by the bucket panel (labels are
// provider-aware). Existing secrets are never shown and never persisted in
// the browser: inputs start blank, "Save" sends only the fields the user
// typed (blanks are omitted so saved values are preserved), and "Clear" is
// the explicit empty-both request. Env-sourced keys are locked.

import { useState } from "react";
import { Badge, Button, Flex, Text, TextField } from "@radix-ui/themes";
import { KeyRound, ShieldCheck, TriangleAlert } from "lucide-react";

import { errText, putCredentials } from "./api";
import type { State } from "../../shared/contracts";

type Credentials = State["credentials"];

function SourceBadge({ keyState }: { keyState: Credentials["access_key"] }) {
  if (keyState.source === "environment")
    return (
      <Badge color="amber" variant="soft">
        env
      </Badge>
    );
  if (keyState.source === "saved")
    return (
      <Badge color="green" variant="soft">
        saved
      </Badge>
    );
  return (
    <Badge color="gray" variant="soft">
      not set
    </Badge>
  );
}

export function CredentialsFields({
  credentials,
  onSync,
  accessLabel,
  secretLabel,
}: {
  credentials: Credentials;
  onSync: () => void;
  accessLabel: string;
  secretLabel: string;
}) {
  const [accessKey, setAccessKey] = useState("");
  const [secretKey, setSecretKey] = useState("");
  const [busy, setBusy] = useState<null | "save" | "clear">(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const accessLocked = credentials.access_key.source === "environment";
  const secretLocked = credentials.secret_key.source === "environment";
  const canSave =
    busy === null &&
    ((!accessLocked && accessKey !== "") || (!secretLocked && secretKey !== ""));
  const canClear =
    busy === null &&
    (credentials.access_key.source === "saved" ||
      credentials.secret_key.source === "saved");

  async function save(): Promise<void> {
    setBusy("save");
    setError(null);
    setNote(null);
    try {
      const body: { access_key?: string; secret_key?: string } = {};
      if (!accessLocked && accessKey !== "") body.access_key = accessKey;
      if (!secretLocked && secretKey !== "") body.secret_key = secretKey;
      await putCredentials(body);
      setAccessKey("");
      setSecretKey("");
      setNote("Credentials saved on the server.");
      onSync();
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(null);
    }
  }

  async function clear(): Promise<void> {
    setBusy("clear");
    setError(null);
    setNote(null);
    try {
      await putCredentials({ ...(accessLocked ? {} : { access_key: "" }), ...(secretLocked ? {} : { secret_key: "" }) });
      setAccessKey("");
      setSecretKey("");
      setNote("Saved credentials cleared.");
      onSync();
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <Flex direction="column" gap="3">
      <Flex align="center" gap="2">
        <KeyRound size={14} color="var(--muted)" />
        <Text size="2" weight="medium">
          Credentials
        </Text>
      </Flex>
      <Text as="div" size="1" color="gray">
        Stored on the server and never displayed back to the browser. Blank
        fields keep saved values.
      </Text>

      <Flex direction="column" gap="2">
        <Flex align="center" gap="2">
          <Text size="2" weight="medium">
            {accessLabel}
          </Text>
          <SourceBadge keyState={credentials.access_key} />
          {accessLocked ? (
            <Text size="1" color="gray">
              set by environment
            </Text>
          ) : null}
        </Flex>
        <TextField.Root
          aria-label={accessLabel}
          type="password"
          placeholder={accessLocked ? "managed by environment" : "Leave blank to keep"}
          value={accessLocked ? "" : accessKey}
          onChange={(e) => setAccessKey(e.target.value)}
          disabled={accessLocked}
          autoComplete="off"
        />
      </Flex>

      <Flex direction="column" gap="2">
        <Flex align="center" gap="2">
          <Text size="2" weight="medium">
            {secretLabel}
          </Text>
          <SourceBadge keyState={credentials.secret_key} />
          {secretLocked ? (
            <Text size="1" color="gray">
              set by environment
            </Text>
          ) : null}
        </Flex>
        <TextField.Root
          aria-label={secretLabel}
          type="password"
          placeholder={secretLocked ? "managed by environment" : "Leave blank to keep"}
          value={secretLocked ? "" : secretKey}
          onChange={(e) => setSecretKey(e.target.value)}
          disabled={secretLocked}
          autoComplete="off"
        />
      </Flex>

      {error !== null ? (
        <Flex align="center" gap="2">
          <TriangleAlert size={14} color="var(--err)" />
          <Text size="2" color="red">
            {error}
          </Text>
        </Flex>
      ) : null}
      {note !== null ? (
        <Flex align="center" gap="2">
          <ShieldCheck size={14} color="var(--green-9)" />
          <Text size="2" color="gray">
            {note}
          </Text>
        </Flex>
      ) : null}

      <Flex gap="3" wrap="wrap">
        <Button onClick={() => void save()} disabled={!canSave}>
          {busy === "save" ? "Saving…" : "Save credentials"}
        </Button>
        <Button
          color="red"
          variant="soft"
          onClick={() => void clear()}
          disabled={!canClear}
        >
          {busy === "clear" ? "Clearing…" : "Clear saved credentials"}
        </Button>
      </Flex>
    </Flex>
  );
}
