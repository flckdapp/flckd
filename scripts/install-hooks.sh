#!/usr/bin/env bash
# Points this clone at the versioned hooks in scripts/githooks/.
# Run once after cloning. Safe to run again.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/githooks/*
git config core.hooksPath scripts/githooks
echo "hooks installed: core.hooksPath = scripts/githooks"
