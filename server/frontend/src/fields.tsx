// Shared form-field atoms: the amber "env" badge, labelled field headers,
// and the dotted-path env-override lookup. A bare "remote" override locks
// every remote.* path, and writing an overridden field is rejected by the
// backend with a 409 — so overridden fields render disabled.

import { Badge, Flex, Text } from "@radix-ui/themes";

export function isOverridden(overrides: readonly string[], path: string): boolean {
  return (
    overrides.includes(path) ||
    (path.startsWith("remote.") && overrides.includes("remote"))
  );
}

function EnvBadge() {
  return (
    <Badge color="amber" variant="soft">
      env
    </Badge>
  );
}

export function FieldLabel({ label, env }: { label: string; env: boolean }) {
  return (
    <Flex align="center" gap="2">
      <Text size="2" weight="medium">
        {label}
      </Text>
      {env ? <EnvBadge /> : null}
    </Flex>
  );
}
