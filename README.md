# You're Flocked

**FLCKD** — [flckd.app](https://flckd.app)

An iOS app that warns you when you're near an ALPR (automated licence plate
reader) camera or other surveillance equipment. Camera locations come from
OpenStreetMap, contributed by people who spotted them.

Inspired by [DeFlock](https://deflock.me).

## What it does

- Warns you when you enter a camera's detection zone, including while your
  phone is in your pocket
- Shows cameras on a map: ALPR, speed cameras, and other surveillance
- Lets you add cameras you find, straight to OpenStreetMap
- Plans routes that pass fewer cameras, entirely on your phone

## Platforms

| Platform | Stack | Status |
|---|---|---|
| iOS | SwiftUI, MapKit, CoreLocation, SwiftData (iOS 17+) | Active |
| Android | Kotlin, Jetpack Compose, Room | Planned |

## Privacy

There are no accounts, no analytics, no tracking, and no telemetry. Proximity
warnings are computed on your phone, and no location history is stored
anywhere.

Routing runs on your device. You download road data for a region once, and
after that route planning is a calculation over a file in your phone's
storage. Your start point and destination are never sent anywhere because
there's no routing server to send them to. Route planning works in airplane
mode.

That road data is downloaded once per region. The default source,
`tiles.flckd.app`, is a Cloudflare R2 bucket of static files: there's no
server of mine behind it, so nothing of mine sees the request. Cloudflare
sees your IP address and which state you asked for, and nothing else: no
position, no route, no destination. You can point the app at your own copy
instead. See [docs/on-device-routing.md](docs/on-device-routing.md).

The app is not fully offline. Camera lookups go to DeFlock and OpenStreetMap,
and map imagery comes from Apple, and those requests do contain location
information. [PRIVACY.md](PRIVACY.md) lists exactly what leaves your device,
to whom, and when, along with the command to check that the list is
complete.

## Building

You need Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen

cd ios
cp Example.xcconfig Local.xcconfig   # then put your own Team ID in it
xcodegen generate                    # creates YoureFlocked.xcodeproj from project.yml
open YoureFlocked.xcodeproj
```

`Local.xcconfig` is gitignored and holds your Apple Team ID for code
signing. Nothing in the tracked project names a team, so anyone can build
with their own account.

The `.xcodeproj` is generated and isn't tracked in git. `ios/project.yml` is
the source of truth, so run `xcodegen generate` after a fresh clone and after
any change to it.

Also run `scripts/install-hooks.sh` once. It enables a pre-commit hook that
refuses anything that could reveal a real place: local test fixtures, GPX
routes, and coordinate-precision numbers outside the state boundary tables.
See [AGENTS.md](AGENTS.md) for the rule it enforces.

## Repository

| Path | What |
|---|---|
| [`ios/`](ios/) | the app |
| [`server/`](server/README.md) | builds and serves the road data for on-device routing |
| [`docs/`](docs/) | design notes |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | how the app is put together, and why |
| [`PRIVACY.md`](PRIVACY.md) | what the app sends, and to whom |

You don't have to use the default bucket. `server/` is a complete recipe
for building the packs and serving them yourself, and the app has a setting
to point at it. A private
instance reachable only by your own devices over
[Tailscale](server/README.md#private-instance-over-tailscale) works well.

## AI disclosure

A large share of this code is written by an AI coding agent.
[AGENTS.md](AGENTS.md) is the instruction file it works from, and it's in
version control alongside everything else.

I review and am accountable for every change. What the app sends is
determined by the code, not by who typed it. [PRIVACY.md](PRIVACY.md)
documents every network call and includes the command to verify that list is
complete. The codebase is small, every dependency is named, and it's all
open.

## Contributing

Read [ARCHITECTURE.md](ARCHITECTURE.md) first.

One rule matters more than the rest: if a change adds a network call, changes
what is sent, or adds a dependency, update [PRIVACY.md](PRIVACY.md) in the
same commit. A privacy policy that's out of date is worse than not having
one.
