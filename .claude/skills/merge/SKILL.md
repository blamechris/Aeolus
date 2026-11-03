---
description: "Merge authorized PRs through verified review/CI gates, record delivery, and run authorized post-merge actions."
---

# /merge

Merge authorized PRs through verified review/CI gates, record delivery, and run authorized post-merge actions. The same gated merge authority applies in ordinary and prime-directive runs.

## Arguments

- `$ARGUMENTS` - PR numbers, `all`, or flags:
  - `123` or `123 456` — specific PR(s)
  - `all` — all open PRs targeting main, only when the user explicitly requests this scope
  - `--no-verify` — skip Phase 3's post-merge build and test of `main`
  - `--verify-only` — run Phase 3 against current `main` without merging anything
  - `--skip-version-check` — don't wait for auto-version CI

## Instructions

### Phase 0: Authority and Mandatory Review Gate

Delegated implementation includes merging its PRs once the gates pass. Honor explicit user holds, required human approvals and unavailable permissions; no extra merge confirmation is needed because the user is present. This does not authorize unrelated existing PRs or turn a review-only request into a merge request. Use the PR set recorded by the delivery workflow, or PRs explicitly selected by the user. Do not infer `all` from an empty argument.

**CRITICAL: Every PR MUST be reviewed before merging.** Run `/full-review` for this PR or verify existing evidence covering its current head. Documentation and version-only PRs follow the same gate; a small diff is not a review exemption.

A review-comment count, a prior CLEAN label or resolved threads alone is insufficient. Verify the reviewed SHA, independent reviewer, inline and general-summary dispositions, and any subsequent fix-delta review. If changes are not covered, run the missing review before proceeding. For multiple PRs, independent reviews may run in parallel within the workflow-agent cap; merge sequentially in dependency order and recheck each dependent PR after its prerequisite lands.

For delegated implementation, continue from an accepted review through the merge gate and ledger. A clean review does not waive final-head CI, thread resolution, required approvals or an explicit hold.

### Phase 1: Pre-Merge Preparation

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

If the post-merge-only flag is set, skip to Phase 3.

Parse the authorized PR set. For explicitly requested `all`:

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

Display a concise summary table, then proceed within the authority already granted:

```markdown
## Merge Queue ({N} PRs)

| # | PR | Title | CI | Merge State |
|---|-----|-------|----|-------------|
| 1 | #123 | feat: add feature | PASS | CLEAN |
```

### Phase 2: Merge Execution

#### Small batch (1-2 PRs): Direct merge

For each PR:

1. **Check current-head gates** — read `headRefOid`, CI, review evidence and `mergeStateStatus`. ALL CI checks must be green on the final commit, `/full-review` must be clean for that head, ALL review threads must have supported resolved dispositions, and repository protection must be satisfied. Use the host's supported status/continuation mechanism for pending checks; never substitute polling prohibited by the host.
2. **Recover a failed gate** — use `/merge-gate` to identify the actual missing requirement. A push, update-branch or prerequisite merge invalidates stale head/base readings. `UNKNOWN` needs a fresh supported status check. Handle CI fixes, owned-branch conflicts and review findings within delegated authority and the shared repair allowance; preserve unrelated changes. Ask only for a verified owner-reserved prerequisite, and keep independent authorized work moving.
3. **Resolve only supported review dispositions** — run `/check-pr` step 6b with the triage record. Its paginated GraphQL `resolveReviewThread` procedure resolves eligible threads and verifies the result. Do not resolve every unresolved thread wholesale. The Python helper passes IDs as GraphQL variables; the existing rule remains: `resolveReviewThread must use Python`. Recheck inline and general findings at the current head before declaring the review clean.
4. **Capture the checked head and merge synchronously** — first verify that the repository permits a synchronous merge. If it requires a merge queue, report that policy dependency; do not silently enqueue or use `--admin` to bypass it. Set `CHECKED_HEAD` to the full SHA whose review, CI and thread gates just passed:
   ```bash
   # Squash: `main` is one commit per PR. Branch protection requires a PR, so a
   # merged branch has no further use — delete it.
   gh pr merge ${PR_NUM} --squash --delete-branch --match-head-commit "${CHECKED_HEAD}"
   ```
   If the head moved, recheck the gates for its new SHA. Never use `gh pr merge --auto`, GitHub auto-merge or a protection override.
5. **Verify and record immediately** — query `gh pr view ${PR_NUM} --json state,mergeCommit,mergedAt`; require `MERGED`. Append the delivered outcome, PR, accepted review, checked head/CI and merge SHA to the ledger before starting another feature or writing the final report.

#### Large batch (3+ PRs): Delegate to /batch-merge

Run `/batch-merge ${PR_NUMS}` with the authorized PR set, dependency order, shared limits and the gates above. Delegation does not waive current-head review, CI or supported thread dispositions. Verify and record each successful merge, then continue to Phase 2b with that list.

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

Apply the repository's established version policy within the delegated release authority. If no bump is required, record the current version and continue. Ask only for an indispensable choice or release action reserved to the owner; do not invent an optional version decision that blocks the completed feature's handoff.

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

When a bump is required and authorized:

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

Run `/full-review` on the version PR, verify final-head CI and all other merge gates, then merge and record it. Version-only changes do not skip the review gate.

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
# If fast-forward fails, inspect and preserve local changes; use a clean owned
# worktree or reconcile deliberately. Never reset away unrelated work.
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

Report verified merged PRs and exact blockers from the ledger. For ordinary development, complete the bounded feature's delivery, then invoke `/session-lifecycle` for the uniform concise status and verified seed instructing the user to start a fresh session. In prime-directive mode, checkpoint the ledger and continue the authorized mission through supported host continuation/compaction; do not stop merely because a PR merged.

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
| Unresolved review threads | `/check-pr`: triage, resolve supported dispositions, recheck gates |
| Merge conflict | Resolve within owned scope and repair limits; recheck review and CI |
| Version bump timeout | Warn and continue to post-merge actions |
| Post-merge build failure | Diagnose and repair within scope; report only a genuine remaining dependency |
| Divergent local branches | Preserve local work; use an owned clean worktree or reconcile deliberately |

## Critical Rules

1. **NEVER merge without /full-review** — every PR must be reviewed before merging. This is a hard gate. Run Phase 0 first.
2. **For 3+ PRs, delegate to /batch-merge** — don't reinvent sequential merge logic
3. **Version verification is informational** — never block post-merge actions on it
4. **GraphQL resolveReviewThread must use Python** — pass thread IDs as GraphQL variables
5. **Never use --admin** — respect branch protections. Never use `gh pr merge --auto` or GitHub auto-merge; check the final head and merge synchronously.
6. **Idempotent** — safe to re-run; already-merged PRs detected and skipped
7. **No attribution** — Zero Attribution Policy applies to all commits
8. **Never merge a PR that writes to the SMC before E5 is done** — the safety
   subsystem gates the write-path epics E3 and E4. `CLAUDE.md` states it, and no
   green CI run overrides it, because CI cannot verify a fan write at all: GitHub's
   macOS runners are VMs with no SMC.
9. **A change to `AeolusHelper`, the SPI-gated write path in `SMCCore`,
   `AeolusXPC`, `Configs/*.entitlements` or `Configs/LaunchDaemons/` gets the
   `reviewer` agent, not just Copilot.** A Copilot review is not the Phase 0 gate and
   never satisfies it on privileged code.
10. **Merge synchronously and verify `MERGED`.** Never `gh pr merge --auto` and never
    GitHub's merge queue: both check the gates at queue time rather than merge time,
    so a thread opened or a check re-run in between lands unreviewed.
11. **Required checks are `Build and test`, `Monitor app build` and `Lint and
    format`.** `Monitor app build` failing usually means the repo has grown a
    dependency on `Configs/Signing.xcconfig`, which is gitignored and absent both on
    CI and for every outside contributor — fix the dependency, never add the file.
