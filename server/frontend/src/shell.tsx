import { Callout, Flex, Heading, IconButton, Text } from "@radix-ui/themes";
import type { ReactNode } from "react";
import { ExternalLink, TriangleAlert, X } from "lucide-react";

const tileUrl = typeof import.meta.env.VITE_TILE_URL === "string"
  ? import.meta.env.VITE_TILE_URL : `http://${window.location.hostname}:8080`;

export function Page({ children }: { children: ReactNode }) {
  return <Flex direction="column" align="center" px="4" py={{ initial: "5", sm: "8" }} style={{ minHeight: "100vh" }}>
    <Flex direction="column" gap="4" style={{ width: "100%", maxWidth: 1280 }}>{children}</Flex>
  </Flex>;
}

export function Header({ connected }: { connected: boolean }) {
  return <Flex align="center" justify="between" gap="4" wrap="wrap">
    <Flex align="center" gap="3">
      <img src="/logo.png" alt="FLCKD logo" width={44} height={44} />
      <Flex direction="column">
        <Heading size="6" className="brand-title">You're <span className="accent">Flocked</span></Heading>
        <Text size="1" color="gray">Tile Builder · local control panel</Text>
      </Flex>
    </Flex>
    <Flex align="center" gap="4">
      <a className="brand-link" href={tileUrl} target="_blank" rel="noreferrer"><Flex as="span" align="center" gap="1"><ExternalLink size={13} /> Public site</Flex></a>
      <Text size="1" color="gray">{connected ? "live" : "reconnecting"}</Text>
    </Flex>
  </Flex>;
}

export function ErrorBanner({ text, onDismiss }: { text: string; onDismiss: () => void }) {
  return <Flex gap="2" align="stretch">
    <Callout.Root role="alert" color="red" size="1" style={{ flexGrow: 1 }}>
      <Callout.Icon><TriangleAlert size={14} /></Callout.Icon><Callout.Text size="2">{text}</Callout.Text>
    </Callout.Root>
    <IconButton aria-label="Dismiss error" variant="soft" color="gray" onClick={onDismiss}><X size={14} /></IconButton>
  </Flex>;
}
