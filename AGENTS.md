# AGENTS.md

Working instructions for AI coding agents in this repository. Human
contributors should read [ARCHITECTURE.md](ARCHITECTURE.md) instead.

## Location privacy

This app exists to keep people away from surveillance. Nothing in this
repository may reveal where its author, its users, or its testers live,
work, or drive.

- Never commit a test, fixture, comment, document, screenshot, or sample
  request that contains a real start point, destination, address, street,
  store, neighbourhood, or city used by a real person.
- UI tests that drive routing need real map coordinates. They live in
  `ios/YoureFlockedUITests/`, which is gitignored on purpose. Keep them
  local. Don't add a `.gitignore` exception, and don't copy their coordinates
  into tracked code.
- When a routing problem is reported from a real place, reproduce it
  locally, fix the algorithm, and describe the mechanism in the commit, not
  the place.
- Debug request dumps and engine traces are for local diagnosis only. Never
  commit them or paste them into an issue.

If you're unsure whether something identifies a place, leave it out.

A pre-commit hook (`scripts/githooks/pre-commit`, installed by
`scripts/install-hooks.sh`) enforces this: it refuses staged files under
`ios/YoureFlockedUITests/`, any `.gpx`, a `.gitignore` that drops the UITests
rule, and coordinate-precision numbers outside `USStateBounds.swift` and
`us-states.json`. Never bypass it with `--no-verify` or `git add -f`. If it
flags a number that isn't a real place, add `geo-ok` to that line with a note
saying what the number is. Run `scripts/githooks/pre-commit --all` to check
the whole tree.

## Privacy policy

[PRIVACY.md](PRIVACY.md) makes specific claims about what leaves the device.
If a change adds a network call, changes what is sent, or adds a dependency,
update PRIVACY.md in the same commit.

## Diagnostics stay out of shipped builds

The routing latency HUD, the reroute probe, and the metrics store exist to
answer performance questions during development. They record how long route
planning takes and write a report the developer can share by hand. That is
fine on a development device and would not be fine on a user's: the report
carries timestamps, speed and remaining distance, which together describe a
trip, and the region pack size resolves to a state against the public tile
manifest.

So they are wrapped in `#if DEBUG` and are absent from any Release build,
including TestFlight. Rules:

- Don't remove or widen a `#if DEBUG` around diagnostics to make something
  compile. If Release fails to build because it reached diagnostic code, the
  call site is in the wrong place. Move the call, not the guard.
- Don't add a runtime flag that switches diagnostics on in a Release build.
  A compile-time gate is the whole point.
- A Release build asserts that the binary doesn't contain
  `FLCKD_DIAGNOSTICS_PRESENT_DO_NOT_SHIP`. Don't delete that build phase and
  don't rename the sentinel on one side only. If it fails, something is
  reachable that shouldn't be; fix that rather than the check.
- If diagnostics ever grow a network call, stop. That would make PRIVACY.md
  false, and nothing here is worth that.

## Documentation

Docs in this repository are written for people. Keep them plain and direct.
Research output, scratch notes, and anything addressed to an agent rather
than a reader belong in `ai-docs/`, which is gitignored.

## Before writing code

- Read the current documentation for the API you're about to use. MapKit,
  CoreLocation, and SwiftUI's `Map` change between iOS versions, and
  Overpass has rate limits and query quirks.
- Check the DeFlock sources for prior art:
  [FoggedLens/deflock](https://github.com/FoggedLens/deflock) (MIT) and
  [FoggedLens/deflock-app](https://github.com/FoggedLens/deflock-app)
  (AGPL-3.0).
- Verify OSM tags against the
  [wiki](https://wiki.openstreetmap.org/wiki/Tag:man_made=surveillance)
  before relying on them.

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org): a
  `type(scope): summary` subject, such as `fix(builder): report the failing
  stage`. Types in use are `feat`, `fix`, `docs`, `refactor`, `chore`,
  `test`, `build` and `ci`.
- Keep messages short. A subject line is usually the whole commit. Add a
  body only when the reason isn't obvious from the diff, and keep it to a
  sentence or two.
- Group related changes into one commit; don't bundle unrelated ones.
- Don't add AI attribution trailers or co-author lines to commit messages.
- Don't commit or push unless asked. The owner does both.
