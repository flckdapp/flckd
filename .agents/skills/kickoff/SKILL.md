---
name: kickoff
description: "Start working on a GitHub issue in flckdapp/flckd: fetches the issue, classifies the type (fix/feat/refactor/chore), and runs `aoe add` to create a worktree session in the Flocked group, then sends an investigation prompt."
user-invocable: true
args:
  - name: issue
    description: "GitHub issue number (e.g. 9)"
    required: true
---

# Kickoff — Start Work on a GitHub Issue

Given a GitHub issue number, fetch its metadata, classify the work type, create an `aoe` worktree session for this repo, start it, and send an investigation prompt so the agent begins researching before you look at it.

Repo: `flckdapp/flckd`. aoe group: `Flocked`. Single repo — no extra `--repo` workspaces.

## Procedure

### Step 1: Fetch the issue

```bash
gh issue view <ISSUE_NUMBER> --repo flckdapp/flckd --json title,labels
```

If this fails (issue doesn't exist, auth error), report the error and stop.

Save the issue title and labels for classification. You do NOT need the body — the agent will fetch it itself.

### Step 2: Assign the issue

```bash
gh issue edit <ISSUE_NUMBER> --repo flckdapp/flckd --add-assignee @me
```

If this fails (permissions error, already assigned), log a warning but continue — assignment is not blocking.

### Step 3: Classify the issue type

Determine the branch prefix using this priority order:

1. **Title prefix** (highest priority) — if the title starts with a conventional commit prefix, use it:
   - `fix(` or `fix:` → `fix`
   - `feat(` or `feat:` → `feat`
   - `refactor(` or `refactor:` → `refactor`
   - `chore(` or `chore:` → `chore`
   - `perf(` or `perf:` → `perf`
   - `docs(` or `docs:` → `docs`
   - `ci(` or `ci:` → `ci`
   - `test(` or `test:` → `test`
   - `build(` or `build:` → `build`

2. **Labels** (fallback if no title prefix matched):
   - `bug` → `fix`
   - `enhancement` → `feat`
   - `documentation` → `docs`

3. **Default** — if nothing matched: `feat`

### Step 4: Build the branch name

Format: `{type}/{issue_number}-{slug}`

The slug is 1-3 words describing the mechanism, taken from the title:
- Lowercase, hyphen-separated, ASCII only
- Strip the conventional commit prefix and any scope first
- Never a real place name, address, or road (see "Location privacy" in AGENTS.md)

Examples:
- Issue #9, label `bug`, title `Camera lookups send your exact position to Overpass; ...` → `fix/9-overpass-position`
- Issue #14 with title `feat(map): show camera direction cones` → `feat/14-direction-cones`
- Issue #21 with label `documentation`, title `Document the tile manifest format` → `docs/21-tile-manifest`

Save the full branch name as `{branch}` for the steps below.

### Step 5: Build the session title

Produce a short, human-readable session title from the issue:
- Strip the conventional commit prefix if present (e.g. `fix(map): ` → remove it)
- Take the first meaningful phrase (aim for 3-6 words)
- Lowercase, no trailing punctuation, no em-dashes or suffixes
- Never include a real place name, address, or road in the title, even if the issue does. Describe the mechanism instead (see "Location privacy" in AGENTS.md).

Examples:
- `Camera lookups send your exact position to Overpass; route planning sends origin and destination` → `"stop sending exact position to overpass"`
- `feat(map): show camera direction cones` → `"camera direction cones"`
- `refactor(routing): split pack loader from planner` → `"split pack loader from planner"`

### Step 6: Resolve the repo path

Run from inside the flckd checkout:

```bash
REPO_DIR="$(git rev-parse --show-toplevel)"
git -C "$REPO_DIR" remote get-url origin   # must contain flckdapp/flckd
```

If CWD is not inside a git repo whose `origin` points at `flckdapp/flckd`, report: "Run /kickoff from inside the flckd repo." and stop.

### Step 7: Run `aoe add`

Execute exactly this command (substituting the resolved path and computed values):

```bash
aoe add "$REPO_DIR" \
  -w "{branch}" \
  -b \
  -t "{title}" \
  -g Flocked \
  --tool opencode \
  --trust-hooks
```

**Flags (all required, never omit):**

| Flag | Purpose |
|------|---------|
| `-w "{branch}"` | Create the session in a git worktree on this branch |
| `-b` | Create a new branch off `main` (required with `-w`) |
| `-t "{title}"` | Session title |
| `-g Flocked` | Group the session under "Flocked" alongside the other flckd sessions |
| `--tool opencode` | Same agent as the rest of the Flocked group |
| `--trust-hooks` | Trust repo hooks and project-local MCP servers without prompting |

Do NOT add `-l` (it would switch the user's pane) and do NOT add `-y`/`--sandbox` without asking.

If `aoe add` fails, show full stderr and stop.

### Step 8: Start the session

```bash
aoe session start "{title}"
```

Wait a few seconds for the agent process to initialize.

### Step 9: Send the investigation prompt

Send a message to the running agent to begin researching the issue. Use single quotes or a heredoc so newlines survive:

```bash
aoe send "{title}" 'Look at GitHub issue #{issue_number} in flckdapp/flckd (use gh issue view). Read the full issue, any comments, linked PRs, and referenced commits. Then investigate the codebase: find all relevant files, understand the current implementation, identify the root cause or integration points, and map out what needs to change. Check whether the change touches anything PRIVACY.md makes claims about (network calls, what is sent, dependencies) or anything wrapped in #if DEBUG diagnostics, and say so.

Additionally, plan a red-to-green test strategy: identify what test(s) you would write FIRST that fail against the current code (proving the bug exists or the feature is missing), and what makes them pass after the fix. Tests must be red before implementation and green after — never write tests that pass trivially or test the happy path without exercising the actual defect/feature gap. Include the test file location, test name, and what assertion fails red. Any test that needs real map coordinates belongs in ios/YoureFlockedUITests/ (gitignored); never put a real place into tracked code or into your summary.

Do NOT make any changes — just research and summarize your findings including the test plan.'
```

### Step 10: Report result

After all commands succeed, report:
- Branch name: `{branch}`
- Session title
- Confirmation that the agent has been sent the investigation prompt
- Remind the user they can attach with: `aoe session attach "{title}"`

## Error Handling

- If `gh issue view` fails → report error, stop
- If `aoe add` fails → show full stderr, suggest checking if the branch already exists (`git branch -a | grep {type}/{issue_number}-`)
- If `aoe session start` fails → show error, suggest the session may already be running
- If `aoe send` fails → show error, suggest attaching manually with `aoe session attach "{title}"`
