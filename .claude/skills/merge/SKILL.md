---
description: "Merge PRs, verify post-merge version bump, and run post-merge actions (build, deploy, etc.)."
---

# /merge

Merge PRs, verify post-merge version bump, and run post-merge actions (build, deploy, etc.).

## Arguments

- `$ARGUMENTS` - PR numbers, `all`, or flags:
  - `123` or `123 456` — specific PR(s)
  - `all` — all open PRs targeting main
  - `--no-verify` — skip Phase 3's post-merge build and test of `main`
  - `--verify-only` — run Phase 3 against current `main` without merging anything
  - `--skip-version-check` — don't wait for auto-version CI

## Instructions

### Phase 0: Mandatory Review Gate

**CRITICAL: Every PR MUST be reviewed before merging, unless it matches an exception
written in the list below.** The gate is never a judgement call: "it's obvious",
"it's a one-liner", "I already read it", "it's low risk" are not exceptions and never
become one. An exception must be decidable from the diff's file paths alone. If the
list below says there are none, then there are none.

For each PR to be merged, check if `/full-review` has already been run:

```bash
# Check for existing review comments (agent-review posts a structured review)
gh api repos/${REPO}/issues/${PR_NUM}/comments --jq '[.[] | select(.body | test("Code Review|Review Comments Addressed"))] | length'
```

If no review exists, run `/full-review ${PR_NUM}` **before proceeding to merge**. For multiple PRs, run reviews in parallel (background agents), then merge sequentially after all reviews complete.

**Exception list — exhaustive. Anything not on it gets reviewed.**

1. The version-bump PR that **Phase 2b** opens, and only when its diff touches
   nothing but `CHANGELOG.md` and the `MARKETING_VERSION` line of `project.yml`.
   Note the second is a *line*, not a file: `project.yml` also carries target
   definitions, build settings and entitlement paths, so "the diff only touches
   `project.yml`" is not the test — every changed line in it must be
   `MARKETING_VERSION`, or the PR gets reviewed. Provenance is deliberately NOT the
   test: "the bump script produced it" is not checkable from a diff, and a hand-authored
   version-only PR must land on the same side of the gate as a scripted one.
   If the diff touches anything outside that list, it gets reviewed.
2. **None — every PR gets reviewed, including documentation.** There is no docs
   exemption here, and that is a decision made against evidence rather than out of
   caution. PR #122 was a documentation-only change to `docs/SAFETY.md`; an
   adversarial review of it found five confirmed defects, three of which were the
   exact defect class the PR existed to remove. `docs/SAFETY.md`, `docs/DESIGN.md`,
   `docs/ARCHITECTURE.md` and `docs/ADR/` are what an implementer builds the
   privileged helper against — `CLAUDE.md` points at them by name — so a wrong
   sentence in one produces a wrong firmware write just as surely as wrong Swift
   does.

### Phase 1: Pre-Merge Preparation

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

If the post-merge-only flag is set, skip to Phase 3.

Parse PR numbers from arguments. For `all`:

```bash
gh pr list --base main --state open --json number,title,headRefName,mergeStateStatus
```

For each PR, pre-check:

```bash
# CI status
gh pr checks ${PR_NUM}

# Merge state
gh pr view ${PR_NUM} --json mergeable,mergeStateStatus
```

Display summary table (no confirmation gate — user invoked the command explicitly):

```markdown
## Merge Queue ({N} PRs)

| # | PR | Title | CI | Merge State |
|---|-----|-------|----|-------------|
| 1 | #123 | feat: add feature | PASS | CLEAN |
```

### Phase 2: Merge Execution

#### Small batch (1-2 PRs): Direct merge

For each PR:

1. **Check CI** — if any checks are pending, poll every 30s up to 3 min. If failed, run `/fix-ci` once and retry.
2. **Check merge state** — if BLOCKED, first **re-read the gate at the CURRENT head**:
   `mergeStateStatus` is a function of the head SHA, so a block recorded before a push
   (yours, update-branch's, or fix-ci's) is often already gone — re-run
   `gh pr view ${PR_NUM} --json mergeable,mergeStateStatus` after every push and never
   escalate to the user (or propose an override) off a stale reading. `UNKNOWN` means
   GitHub is recomputing, not that a blocker exists — poll it. Treat contradictory
   readings with equal suspicion: `BLOCKED` + green CI + 0 unresolved threads means a
   reading is stale or a requirement is missing from your view (an unreported required
   check, a ruleset such as a pending Copilot review, required approvals) — re-derive
   each gate input at the current head instead of assuming. Then, if still BLOCKED,
   diagnose:

   | Error Pattern | Action | Max Retries |
   |---|---|---|
   | "not up to date" / "branch is behind" | `gh api repos/${REPO}/pulls/${PR_NUM}/update-branch -X PUT`, wait for CI, retry | 1 |
   | "status check" / "required status" | `/fix-ci`, retry | 1 |
   | "review" / "unresolved threads" | Resolve via GraphQL (see below), retry | 1 |
   | "conflict" / "not mergeable" | Skip, report conflict | 0 |
   | "already merged" | Skip silently | 0 |
   | Rate limit (403/429) | Back off 60s, retry | 2 |
   | Unknown | Log error, skip | 0 |

3. **Resolve review threads** if blocking merge:

   ```python
   # MUST use Python — bash corrupts Base64 thread IDs in GraphQL mutations
   python3 -c "
   import subprocess, json
   result = subprocess.run(['gh', 'api', 'graphql', '-f',
     'query={repository(owner:\"OWNER\",name:\"REPO\"){pullRequest(number:PR_NUM){reviewThreads(first:50){nodes{id,isResolved}}}}}'],
     capture_output=True, text=True)
   data = json.loads(result.stdout)
   for t in [x for x in data['data']['repository']['pullRequest']['reviewThreads']['nodes'] if not x['isResolved']]:
       mutation = 'mutation { resolveReviewThread(input: {threadId: \"' + t['id'] + '\"}) { thread { isResolved } } }'
       subprocess.run(['gh', 'api', 'graphql', '-f', f'query={mutation}'], capture_output=True, text=True)
   "
   ```

4. **Squash merge:**
   ```bash
   # Squash: `main` is one commit per PR. Branch protection requires a PR, so a
   # merged branch has no further use — delete it.
   gh pr merge ${PR_NUM} --squash --delete-branch
   ```

5. **Verify:** `gh pr view ${PR_NUM} --json state -q .state` should be `MERGED`

#### Large batch (3+ PRs): Delegate to /batch-merge

Run `/batch-merge ${PR_NUMS}` — it handles sequential merge with update-branch, CI waiting, Copilot gating, and conflict resolution. After delegation completes, continue to Phase 2b with the list of successfully merged PRs.

### Phase 2b: Version Verification

**Aeolus has no auto-version workflow and no bump script.** Two version numbers are
maintained by hand, and they are independent:

- **`MARKETING_VERSION`** in `project.yml` (`0.0.0` — the project is at milestone M0
  and has never shipped a build), mirrored into `CFBundleShortVersionString`.
- **`AeolusXPCVersion`** in `Sources/AeolusXPC` — the protocol version negotiated at
  connect time between a client and the privileged helper. This one is not cosmetic:
  a stale `fanctl` against a newer helper must fail loudly rather than silently
  mis-decode a fan command, so a protocol change that ships without a bump is a
  safety defect and not a bookkeeping slip.

So this phase is a **verification**, not a bump prompt. After merging, check both:

```bash
# Did the merged PR move the XPC protocol surface without bumping the version?
git diff HEAD~1 --name-only | grep -q '^Sources/AeolusXPC/' && \
  echo "AeolusXPC changed — confirm AeolusXPCVersion moved and CHANGELOG.md says so"

# Is the change recorded under CHANGELOG.md's [Unreleased]?
sed -n '/## \[Unreleased\]/,/^## \[/p' CHANGELOG.md
```

Report a mismatch; do not fix it silently, and do not treat it as blocking — the merge
has already happened by this point. Raise it with the user or file it.

If a `MARKETING_VERSION` bump *is* wanted (a release, not a routine merge):

**Stage explicit paths, and assert the branch first.** A hand edit can touch more than
the version files (a stray reformat, an editor's trailing-newline fix), and the working copy
is shared with concurrent sessions — so name the version files, do not sweep. `git status --short`
first, then `git add` those paths. Never `git add -A`, `git add .`, `git add -u`,
`git add <dir>/`, or `git commit -a`. `-u` is not the safe one: it restages every *tracked*
file whose worktree copy differs, including files a clean/smudge filter rewrote without you
touching them — that is how `git add -u` turned a tracked 21KB `.docx` into a git-lfs pointer
and committed it as an edit. And because HEAD is global to the working copy, re-check
`git branch --show-current` against the bump branch immediately before running the script and
again immediately before staging: a checkout from a minute ago proves nothing.

```bash
# No bump script exists — MARKETING_VERSION in project.yml and the CHANGELOG
# heading are edited by hand, then staged by name.
git checkout -b chore/bump-version main
# Derive it from the actual checkout — a duplicated literal drifts the moment
# someone customizes the branch name and misses one of the two places.
SESSION_BRANCH="$(git branch --show-current)"
assert_branch() {
  local now; now="$(git branch --show-current)"
  [ "${now}" = "${SESSION_BRANCH}" ] || {
    echo "STOP: on '${now}', expected '${SESSION_BRANCH}' — HEAD moved. Do not edit, do not stage." >&2
    return 1
  }
}

assert_branch || exit 1   # before anything is written
# Edit by hand: project.yml's MARKETING_VERSION, and promote CHANGELOG.md's
# [Unreleased] heading to the new version with a date.

assert_branch || exit 1   # again before staging
git status --short
git add project.yml CHANGELOG.md
NEXT=[the new MARKETING_VERSION]
git commit -m "chore: bump version to v${NEXT}"
git push -u origin chore/bump-version
gh pr create --title "chore: bump version to v${NEXT}" --body "Patch version bump."
```

Merge after CI passes — this is exception 1 in the Phase 0 list (script-generated
version-only diff), the one PR that may merge unreviewed by default.

If `--skip-version-check` is set, skip this phase.

### Phase 3: Post-Merge Actions

**Skip conditions:**
- Post-merge skip flag is set
- No PRs were merged (all skipped/blocked)
- Every merged PR touched only `docs/`, `.github/`, `.claude/`, `README.md` or
  `CHANGELOG.md` — nothing under `Sources/`, `Tests/`, `Package.swift`,
  `project.yml` or `Resources/catalog/`, so neither the build nor the suite can have
  changed behaviour

**Aeolus deploys nothing.** There is no release tag to move, no image to push, no
staging environment. The one post-merge action worth running is a check that `main`
is still green — a squash merge lands a commit combination CI never built, because
the required checks ran on the PR head and not on the squashed result.

That matters more here than in a repo that deploys: `main` is what every contributor
and every fresh worktree starts from, and a red `main` in a project whose central rule
is *safety before capability* costs more than the two minutes this takes.

#### Step 3a: Pull latest main

```bash
git checkout main
git pull --ff-only origin main
# If fast-forward fails (divergent from stale cherry-picks/worktrees):
# git reset --hard origin/main
```

Verify local version matches the auto-versioned remote:
```bash
echo "Marketing version: $(sed -n 's/.*MARKETING_VERSION: *"\(.*\)".*/\1/p' project.yml | head -1)"
echo "Head: $(git log --oneline -1)"
```

#### Step 3b: Verify `main` builds and its tests pass

```bash
swift build
swift test
```

Both must succeed. A failure here is a squash-merge interaction no PR check could have
caught — report it immediately and treat restoring `main` as the next task, ahead of
whatever was queued.

#### Step 3c: Regenerate the Xcode project, if it moved

Only when a merged PR touched `project.yml`. `Aeolus.xcodeproj` is generated and
gitignored, so a stale copy on disk silently diverges from what CI builds:

```bash
xcodegen generate
```

Do not commit the result — the project file is gitignored by design.

### Phase 4: Report

```markdown
## Merge Complete

| PR | Title | Status |
|----|-------|--------|
| #123 | feat: add feature | Merged |
| #456 | fix: resolve crash | Skipped (conflict) |

**Version:** v1.2.3 → v1.2.4
**Post-merge check:** `swift build` clean · `swift test` — N tests, N suites, green
**XPC protocol:** unchanged (or: bumped to vN, called out in CHANGELOG.md)
```

## Error Recovery

| Error | Recovery |
|---|---|
| CI failure on PR | Run `/fix-ci`, wait, retry merge |
| Unresolved review threads | Resolve via GraphQL Python script, retry |
| Merge conflict | Skip PR, report to user |
| Version bump timeout | Warn and continue to post-merge actions |
| Post-merge build failure | Report error, suggest manual intervention |
| Divergent local branches | `git reset --hard origin/main` |

## Critical Rules

1. **NEVER merge without /full-review** — every PR must be reviewed before merging. This is a hard gate. Run Phase 0 first.
2. **For 3+ PRs, delegate to /batch-merge** — don't reinvent sequential merge logic
3. **Version verification is informational** — never block post-merge actions on it
3. **GraphQL resolveReviewThread must use Python** — bash corrupts Base64 thread IDs
4. **Never use --admin** — respect branch protections
5. **Idempotent** — safe to re-run; already-merged PRs detected and skipped
6. **No attribution** — Zero Attribution Policy applies to all commits
7. **Never merge a PR that writes to the SMC before E5 is done** — the safety
   subsystem gates the write-path epics E3 and E4. `CLAUDE.md` states it, and no
   green CI run overrides it, because CI cannot verify a fan write at all: GitHub's
   macOS runners are VMs with no SMC.
8. **A change to `AeolusHelper`, the SPI-gated write path in `SMCCore`,
   `AeolusXPC`, `Configs/*.entitlements` or `Configs/LaunchDaemons/` gets the
   `reviewer` agent, not just Copilot.** A Copilot review is not the Phase 0 gate and
   never satisfies it on privileged code.
9. **Merge synchronously and verify `MERGED`.** Never `gh pr merge --auto` and never
   GitHub's merge queue: both check the gates at queue time rather than merge time,
   so a thread opened or a check re-run in between lands unreviewed.
10. **Required checks are `Build and test`, `Monitor app build` and `Lint and
    format`.** `Monitor app build` failing usually means the repo has grown a
    dependency on `Configs/Signing.xcconfig`, which is gitignored and absent both on
    CI and for every outside contributor — fix the dependency, never add the file.
