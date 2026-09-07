// Bucket publishing panel: the remote switch, provider-aware connection
// fields, and credentials all in one place. The stored contract keeps a raw
// endpoint, but the UI derives it per provider — an R2 account id or an AWS
// region — instead of asking for one. Env-overridden endpoint/region fields
// stay read-only: writing them is rejected by the backend with a 409.

import {
  Badge,
  Card,
  Flex,
  Grid,
  Heading,
  Select,
  Separator,
  Switch,
  Text,
  TextField,
} from "@radix-ui/themes";
import { CloudUpload } from "lucide-react";

import { CredentialsFields } from "./credentials";
import { FieldLabel, isOverridden } from "./fields";
import type { Settings, State } from "../../shared/contracts";
import { remoteSchema } from "../../shared/contracts";

const PROVIDERS: { value: Settings["remote"]["provider"]; label: string }[] = [
  { value: "Cloudflare", label: "Cloudflare R2" },
  { value: "AWS", label: "AWS S3" },
  { value: "Other", label: "Other S3-compatible" },
];

const CRED_LABELS: Record<Settings["remote"]["provider"], { access: string; secret: string }> = {
  Cloudflare: { access: "R2 access key ID", secret: "R2 secret access key" },
  AWS: { access: "AWS access key ID", secret: "AWS secret access key" },
  Other: { access: "Access key ID", secret: "Secret access key" },
};

const R2_ENDPOINT = /^https:\/\/([a-z0-9]+)\.r2\.cloudflarestorage\.com$/;

function r2AccountId(endpoint: string): string {
  return R2_ENDPOINT.exec(endpoint)?.[1] ?? "";
}

// The field reads its value back out of the derived endpoint, so a character the
// endpoint cannot hold would erase what was just typed. Normalising keeps it total.
function r2Endpoint(typed: string): string {
  const id = typed.toLowerCase().replace(/[^a-z0-9]/g, "");
  return id === "" ? "" : `https://${id}.r2.cloudflarestorage.com`;
}

function awsEndpoint(region: string): string {
  return region === "" ? "" : `https://s3.${region}.amazonaws.com`;
}

export function BucketCard({
  state,
  form,
  onChange,
  dirty,
  onSync,
}: {
  state: State;
  form: Settings;
  onChange: (next: Settings) => void;
  dirty: boolean;
  onSync: () => void;
}) {
  const overridden = (path: string): boolean =>
    isOverridden(state.overrides, path);
  const remote = form.remote;
  const endpointEnv = overridden("remote.endpoint");
  const regionEnv = overridden("remote.region");
  const labels = CRED_LABELS[remote.provider];

  function patchRemote(patch: Partial<Settings["remote"]>): void {
    onChange({ ...form, remote: { ...remote, ...patch } });
  }

  function onProviderChange(v: string): void {
    const provider = remoteSchema.shape.provider.parse(v);
    const next: Settings["remote"] = { ...remote, provider };
    if (!regionEnv) {
      if (provider === "Cloudflare") next.region = "auto";
      else if (provider === "AWS" && next.region === "auto") next.region = "";
    }
    if (provider === "AWS" && !endpointEnv) next.endpoint = awsEndpoint(next.region);
    onChange({ ...form, remote: next });
  }

  return (
    <Card size="3">
      <Flex direction="column" gap="4">
        <Flex align="center" gap="2">
          <CloudUpload size={16} color="var(--muted)" />
          <Heading size="4">Bucket publishing</Heading>
          {dirty ? (
            <Badge color="amber" variant="soft">
              unsaved
            </Badge>
          ) : null}
        </Flex>

        <Flex align="center" gap="3">
          <Switch
            aria-label="Publish to bucket"
            checked={remote.enabled}
            onCheckedChange={(v) => patchRemote({ enabled: v })}
            disabled={overridden("remote.enabled")}
          />
          <FieldLabel label="Publish to bucket" env={overridden("remote.enabled")} />
        </Flex>

        {remote.enabled ? (
          <Flex direction="column" gap="4">
            <Grid columns={{ initial: "1", sm: "2" }} gap="4">
              <Flex direction="column" gap="2">
                <FieldLabel label="Provider" env={overridden("remote.provider")} />
                <Select.Root
                  value={remote.provider}
                  onValueChange={onProviderChange}
                  disabled={overridden("remote.provider")}
                >
                  <Select.Trigger aria-label="Provider" variant="soft" />
                  <Select.Content>
                    {PROVIDERS.map((p) => (
                      <Select.Item key={p.value} value={p.value}>
                        {p.label}
                      </Select.Item>
                    ))}
                  </Select.Content>
                </Select.Root>
              </Flex>

              <Flex direction="column" gap="2">
                <FieldLabel label="Bucket" env={overridden("remote.bucket")} />
                <TextField.Root
                  aria-label="Bucket"
                  placeholder="flckd-tiles"
                  value={remote.bucket}
                  disabled={overridden("remote.bucket")}
                  onChange={(e) => patchRemote({ bucket: e.target.value })}
                />
              </Flex>

              {endpointEnv ? (
                <Flex direction="column" gap="2">
                  <FieldLabel label="Endpoint" env />
                  <TextField.Root
                    aria-label="Endpoint"
                    value={remote.endpoint}
                    disabled
                  />
                </Flex>
              ) : remote.provider === "Cloudflare" ? (
                <Flex direction="column" gap="2">
                  <FieldLabel label="Account ID" env={false} />
                  <TextField.Root
                    aria-label="Account ID"
                    placeholder="32 hex characters"
                    value={r2AccountId(remote.endpoint)}
                    onChange={(e) => patchRemote({ endpoint: r2Endpoint(e.target.value) })}
                  />
                  <Text size="1" color="gray">
                    Endpoint: {remote.endpoint === "" ? "—" : remote.endpoint}
                  </Text>
                </Flex>
              ) : null}

              {remote.provider === "AWS" ? (
                <Flex direction="column" gap="2">
                  <FieldLabel label="Region" env={regionEnv} />
                  <TextField.Root
                    aria-label="Region"
                    placeholder="us-east-1"
                    value={remote.region}
                    disabled={regionEnv}
                    onChange={(e) => {
                      const region = e.target.value;
                      patchRemote(
                        endpointEnv ? { region } : { region, endpoint: awsEndpoint(region) },
                      );
                    }}
                  />
                  {endpointEnv ? null : (
                    <Text size="1" color="gray">
                      Endpoint: {remote.endpoint === "" ? "—" : remote.endpoint}
                    </Text>
                  )}
                </Flex>
              ) : null}

              {remote.provider === "Other" && !endpointEnv ? (
                <Flex direction="column" gap="2">
                  <FieldLabel label="Endpoint" env={false} />
                  <TextField.Root
                    aria-label="Endpoint"
                    placeholder="https://s3.example.com"
                    value={remote.endpoint}
                    onChange={(e) => patchRemote({ endpoint: e.target.value })}
                  />
                </Flex>
              ) : null}

              {remote.provider === "Other" ? (
                <Flex direction="column" gap="2">
                  <FieldLabel label="Region" env={regionEnv} />
                  <TextField.Root
                    aria-label="Region"
                    placeholder="auto"
                    value={remote.region}
                    disabled={regionEnv}
                    onChange={(e) => patchRemote({ region: e.target.value })}
                  />
                </Flex>
              ) : null}
            </Grid>

            <Separator size="4" />

            <CredentialsFields
              credentials={state.credentials}
              onSync={onSync}
              accessLabel={labels.access}
              secretLabel={labels.secret}
            />
          </Flex>
        ) : null}
      </Flex>
    </Card>
  );
}
