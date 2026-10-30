// Speed cameras panel: whether builds publish the national speed-camera file,
// and how often it is refreshed. Changes save immediately, apart from the
// build settings form.

import { Card, Flex, Heading, Select, Switch, Text } from "@radix-ui/themes";
import { Gauge } from "lucide-react";

import { FieldLabel } from "./fields";
import { fmtDateTime } from "./format";
import { CADENCES } from "./jobmeta";
import type { Settings, State } from "../../shared/contracts";
import { cadenceSchema } from "../../shared/contracts";

export function SpeedCamerasCard({
  state,
  cameras,
  saving,
  disabled,
  onChange,
}: {
  state: State;
  cameras: Settings["cameras"];
  saving: boolean;
  disabled: boolean;
  onChange: (next: Settings["cameras"]) => void;
}) {
  const label = CADENCES.find((c) => c.value === cameras.cadence)?.label ?? cameras.cadence;

  const scheduleText = saving
    ? "Saving…"
    : cameras.cadence === "manual"
      ? "Refreshed with each build, and when you choose Refresh speed cameras."
      : state.cameras_next_due_at === null
        ? label
        : `Next refresh ${fmtDateTime(state.cameras_next_due_at)}`;

  return (
    <Card size="3">
      <Flex direction="column" gap="4">
        <Flex align="center" gap="2">
          <Gauge size={16} color="var(--muted)" />
          <Heading size="4">Speed cameras</Heading>
        </Flex>

        <Text size="2" color="gray">
          Builds extract every speed and red-light camera mapped in OpenStreetMap
          into one file, published next to the region packs. It's nationwide and
          refreshes in minutes.
        </Text>

        <Flex align="center" gap="3">
          <Switch
            aria-label="Publish speed cameras"
            checked={cameras.enabled}
            disabled={disabled}
            onCheckedChange={(v) => onChange({ ...cameras, enabled: v })}
          />
          <FieldLabel label="Publish speed cameras" env={false} />
        </Flex>

        {cameras.enabled ? (
          <Flex direction="column" gap="2" style={{ maxWidth: 360 }}>
            <FieldLabel label="Refresh schedule" env={false} />
            <Select.Root
              value={cameras.cadence}
              disabled={disabled}
              onValueChange={(v) => onChange({ ...cameras, cadence: cadenceSchema.parse(v) })}
            >
              <Select.Trigger aria-label="Refresh schedule" variant="soft" />
              <Select.Content>
                {CADENCES.map((c) => (
                  <Select.Item key={c.value} value={c.value}>
                    {c.label}
                  </Select.Item>
                ))}
              </Select.Content>
            </Select.Root>
            <Text size="1" color="gray">
              {scheduleText}
            </Text>
          </Flex>
        ) : (
          <Text size="2" color="gray">
            {saving ? "Saving…" : "Off — releases won't include a speed-camera file."}
          </Text>
        )}
      </Flex>
    </Card>
  );
}
