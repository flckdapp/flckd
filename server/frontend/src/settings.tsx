// Build settings card: regions, schedule, threads, and the save action.
// Env-overridden fields are disabled and badged "env". The form is owned by
// the app so dirty state survives SSE state events; bucket publishing lives
// in its own panel.

import { useEffect, useState } from "react";
import {
  Badge,
  Button,
  Card,
  Flex,
  Grid,
  Heading,
  Select,
  Separator,
  Text,
  TextField,
} from "@radix-ui/themes";
import { Settings2 } from "lucide-react";

import { FieldLabel, isOverridden } from "./fields";
import { fmtDateTime } from "./format";
import { CADENCES } from "./jobmeta";
import { RegionPicker } from "./regions";
import type { Settings, State } from "../../shared/contracts";
import { settingsSchema } from "../../shared/contracts";

export function SettingsCard({
  state,
  form,
  onChange,
  dirty,
  saving,
  onSave,
}: {
  state: State;
  form: Settings;
  onChange: (next: Settings) => void;
  dirty: boolean;
  saving: boolean;
  onSave: () => void;
}) {
  const [threadsText, setThreadsText] = useState(String(form.threads));

  const overridden = (path: string): boolean =>
    isOverridden(state.overrides, path);

  useEffect(() => {
    setThreadsText(String(form.threads));
  }, [form.threads]);

  const credsReady =
    state.credentials.access_key.configured &&
    state.credentials.secret_key.configured;
  const saveGated = form.remote.enabled && !credsReady;
  const cadenceLabel =
    CADENCES.find((c) => c.value === form.cadence)?.label ?? form.cadence;

  return (
    <Card size="3">
      <Flex direction="column" gap="4">
        <Flex align="center" gap="2">
          <Settings2 size={16} color="var(--muted)" />
          <Heading size="4">Build settings</Heading>
          {dirty ? (
            <Badge color="amber" variant="soft">
              unsaved
            </Badge>
          ) : null}
        </Flex>

        <RegionPicker
          catalog={state.regions}
          selected={form.regions}
          overridden={overridden("regions")}
          onChange={(regions) => onChange({ ...form, regions })}
        />

        <Separator size="4" />

        <Grid columns={{ initial: "1", sm: "2" }} gap="4">
          <Flex direction="column" gap="2">
            <FieldLabel label="Schedule" env={overridden("cadence")} />
            <Select.Root
              value={form.cadence}
              onValueChange={(v) =>
                onChange({ ...form, cadence: settingsSchema.shape.cadence.parse(v) })
              }
              disabled={overridden("cadence")}
            >
              <Select.Trigger aria-label="Schedule" variant="soft" />
              <Select.Content>
                {CADENCES.map((c) => (
                  <Select.Item key={c.value} value={c.value}>
                    {c.label}
                  </Select.Item>
                ))}
              </Select.Content>
            </Select.Root>
            <Text size="1" color="gray">
              {form.cadence === "manual"
                ? "Manual — no scheduled builds"
                : state.next_due_at === null
                  ? `${cadenceLabel} — starts one interval after saving`
                  : `Next build due ${fmtDateTime(state.next_due_at)}`}
            </Text>
          </Flex>

          <Flex direction="column" gap="2">
            <FieldLabel label="Threads" env={overridden("threads")} />
            <TextField.Root
              aria-label="Threads"
              type="number"
              min={1}
              max={64}
              value={overridden("threads") ? String(form.threads) : threadsText}
              disabled={overridden("threads")}
              onChange={(e) => {
                setThreadsText(e.target.value);
                const n = Number.parseInt(e.target.value, 10);
                if (
                  e.target.value !== "" &&
                  Number.isInteger(n) &&
                  n >= 1 &&
                  n <= 64
                )
                  onChange({ ...form, threads: n });
              }}
            />
            <Text size="1" color="gray">
              The memory dial — ~1.5 GB per thread.
            </Text>
          </Flex>
        </Grid>

        <Separator size="4" />

        <Flex align="center" gap="3" wrap="wrap">
          <Button onClick={onSave} disabled={!dirty || saving || saveGated}>
            {saving ? "Saving…" : "Save settings"}
          </Button>
          {saveGated ? (
            <Text size="2" color="amber">
              Save bucket credentials first — remote publishing needs them.
            </Text>
          ) : dirty ? (
            <Text size="2" color="gray">
              Unsaved changes — builds use saved settings.
            </Text>
          ) : null}
        </Flex>
      </Flex>
    </Card>
  );
}
