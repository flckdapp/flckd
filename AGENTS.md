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

- Don't add AI attribution trailers or co-author lines to commit messages.
- Don't commit or push unless asked. The owner does both.
