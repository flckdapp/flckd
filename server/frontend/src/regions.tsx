// Region picker: searchable checkbox list with All/Clear, selection count,
// and the full-catalog resource warning. Emits ids in catalog order so
// dirty comparison stays stable.

import { useMemo, useState } from "react";
import {
  Badge,
  Button,
  Callout,
  Checkbox,
  Flex,
  ScrollArea,
  Text,
  TextField,
} from "@radix-ui/themes";
import { Info, Search, TriangleAlert } from "lucide-react";

import type { State } from "../../shared/contracts";

export function RegionPicker({
  catalog,
  selected,
  overridden,
  onChange,
}: {
  catalog: State["regions"];
  selected: readonly string[];
  overridden: boolean;
  onChange: (ids: string[]) => void;
}) {
  const [query, setQuery] = useState("");
  const order = useMemo(
    () => new Map(catalog.map((r, i) => [r.id, i] as const)),
    [catalog],
  );

  const setIds = (ids: string[]): void =>
    onChange([...ids].sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0)));

  const toggle = (id: string, on: boolean): void => {
    const set = new Set(selected);
    if (on) set.add(id);
    else set.delete(id);
    setIds([...set]);
  };

  const q = query.trim().toLowerCase();
  const visible =
    q === ""
      ? catalog
      : catalog.filter(
          (r) =>
            r.name.toLowerCase().includes(q) ||
            r.id.includes(q) ||
            r.iso3166_2.toLowerCase().includes(q),
        );
  const entire = catalog.length > 0 && selected.length === catalog.length;

  return (
    <Flex direction="column" gap="2">
      <Flex align="center" gap="2" wrap="wrap">
        <Text size="2" weight="medium">
          Catalog regions
        </Text>
        <Badge color="gray" variant="soft">
          {selected.length} of {catalog.length}
        </Badge>
        {overridden ? (
          <Badge color="amber" variant="soft">
            env
          </Badge>
        ) : null}
      </Flex>
      <Flex gap="2" wrap="wrap">
        <TextField.Root
          aria-label="Search states"
          size="1"
          placeholder="Search states…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          style={{ flexGrow: 1, minWidth: 140 }}
        >
          <TextField.Slot>
            <Search size={13} color="var(--muted)" />
          </TextField.Slot>
        </TextField.Root>
        <Button
          size="1"
          variant="soft"
          disabled={overridden || entire}
          onClick={() => setIds(catalog.map((r) => r.id))}
        >
          All
        </Button>
        <Button
          size="1"
          variant="soft"
          disabled={overridden || selected.length === 0}
          onClick={() => setIds([])}
        >
          Clear
        </Button>
      </Flex>
        <Callout.Root color={entire ? "amber" : "gray"} size="1">
          <Callout.Icon>
            {entire ? <TriangleAlert size={14} /> : <Info size={14} />}
          </Callout.Icon>
          <Callout.Text size="1">
            {entire
              ? "The whole country: several hours, and roughly 250 GB free while it runs (it keeps about 45 GB)."
              : "The map is cut down to what you pick before the graph is built, so a few states cost a fraction of the whole country."}{" "}
            Deselected states are removed from the next catalog.
          </Callout.Text>
        </Callout.Root>
      <ScrollArea type="auto" scrollbars="vertical" style={{ height: 240 }}>
        <Flex direction="column" gap="2" pr="2">
          {visible.map((r) => (
            <Text as="label" key={r.id} size="2">
              <Flex as="span" align="center" gap="2">
                <Checkbox
                  checked={selected.includes(r.id)}
                  onCheckedChange={(v) => toggle(r.id, v === true)}
                  disabled={overridden}
                />
                {r.name}
                <Text as="span" size="1" color="gray">
                  {r.iso3166_2}
                </Text>
              </Flex>
            </Text>
          ))}
          {visible.length === 0 ? (
            <Text size="2" color="gray">
              No states match “{query.trim()}”.
            </Text>
          ) : null}
        </Flex>
      </ScrollArea>
    </Flex>
  );
}
