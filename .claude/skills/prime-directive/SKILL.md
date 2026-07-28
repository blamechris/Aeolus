---
description: "A reload-resilient north star for an unattended, multi-wave backlog-clearing marathon — a compact, self-contained constitution you re-invoke after every cont..."
---

# /prime-directive

A reload-resilient north star for an unattended, multi-wave backlog-clearing marathon — a compact, self-contained constitution you re-invoke after every context compaction to re-establish the mission, the authority you were granted, the per-issue loop, and the never-strip guardrails before resuming. Where `/tackle-issues` and `/autonomous-dev-flow` are the machinery, this is the constitution that keeps a long autonomous run from drifting as its context is summarized and rebuilt.

Invoke it at the **start** of an unattended run to set the mission, and again **after every compaction** to reload it. It does not start work by itself — it re-grounds the agent, then hands off to the marathon machinery (`/tackle-issues`) for the actual wave loop. Treat this file as load-bearing: everything an interrupted, freshly-compacted agent needs to safely resume is here, in one read. Natural-language cues like *"work autonomously / use the prime directive / keep going until the backlog is clean or you're genuinely blocked"* should route here.

## Arguments

- `$ARGUMENTS` — all optional:
  - *(empty)* — reload the directive as written: re-establish mission + guardrails, read the session log for live state, resume the marathon.
  - A path — override the session-log location for this run (default below).
  - A short mission override in quotes — narrow the scope for this run (e.g. `"only label:ready-to-build"`), without editing the file.

## Reliability — the reload contract (read this first)

This skill exists because a long autonomous run is **compacted repeatedly**, and each compaction summarizes (and can quietly distort) the agent's memory of *what it is doing and what the rules are*. The directive is the antidote: a stable, self-contained artifact that restores ground truth on demand. Four rules make that reliable — do not weaken them:

1. **Reload by invocation, never by file-path `cat`.** After every compaction, run **`/prime-directive`**. Do **not** rely on `cat .claude/commands/<name>.md` or any hard-coded path: the legacy `.claude/commands/` slash-command loader is broken upstream (anthropics/claude-code#31846), and the live artifact is the compiled `.claude/skills/prime-directive/SKILL.md` that `/prime-directive` loads. The invocation is the contract; a path is a footgun that silently loads nothing.

2. **Plant the reload trigger where a compacted agent will see it.** The session log's **first line** must read, verbatim: *"After any compaction: re-invoke `/prime-directive`, then read this log from the top for live state, then resume."* Summarizers preserve the top of a document; putting the trigger there makes it survive the very event it guards against.

3. **Keep this file self-contained.** Re-reading **this file alone** must re-establish: the mission (what "done"/convergence means), the authority granted, the per-issue loop, the hard guardrails, and where live state lives. Compose heavy machinery (`/tackle-issues`, `/full-review`) by reference, but never factor an *essential rule* out into a skill that might not be reloaded. The constitution stands alone; the machinery is called by name.

4. **Re-entry is idempotent.** Resuming mid-run must never duplicate work. Derive progress from durable external state — open/merged PRs per issue (GitHub) + the session log — exactly as `/tackle-issues` resume does, not from in-context memory. Re-invoking `/prime-directive` at any moment is always safe.

## Mission

Clear the **entire** open issue backlog for `blamechris/Aeolus`, autonomously, until **convergence**. There is **no stop condition besides a converged backlog** — keep going until every open issue is resolved (closed via a merged PR, decomposed into tracked sub-issues, or documented-blocked with a comment), or nothing tractable remains. The user is away and will review on return. Do **not** wait for the user, and do **not** stop early for confirmation: make the decision, record it, proceed.

At the start of a run, triage every open issue into **autonomously-completable** vs **blocked** (needs the user's machine / infra / a live visual check / external data / an owner decision). Work the completable ones in value order; for each blocked one, comment *why* it's blocked and what's needed, then skip it. **Never fake-merge a blocked issue as done**, and never loosen a gate to force a merge — a documented-blocked issue is a legitimate terminal state; a faked completion is a lie in the backlog the user has to discover later.

## Authority

For an unattended run, this directive grants: full autonomous **self-merge under the merge gate below**; create / close / comment / label issues; decompose epics into sub-issues; file follow-up issues for deferred work; and use a decision panel (the `architect` sub-agent, per the escalation table in `CLAUDE.md`) to choose among genuine options and then **act on the recommendation** rather than escalating to the user.

Two Aeolus-specific limits on that grant, both narrow and both hard. First, the harness permission layer may deny `gh pr merge` outright; if it does, that is a **capability** limit no instruction in this file overrides — run the full gate, record the verdict, stop at **"ready to merge"**, and leave the PR for the owner. Never route around a denial, and never treat one as a reason to stop working on everything else. Second, `CLAUDE.md` reserves a short list of calls to the repo owner regardless of this grant: naming, licence, project scope, anything involving the signing identity, and **any claim of hardware support**. Those escalate rather than being decided. Everything else in this repository is yours to call — make the call, record it, move on.

Aeolus-specific triage: the epic board is the sequencing source of truth and several epics are **explicitly blocked by others** (E5 gates E3/E4). An issue whose blocker is unmerged is **blocked**, not tractable — do not start it to "get ahead". Anything requiring hardware this project cannot test (Intel, M1/M2, desktop Macs) is permanently blocked for an unattended run and must be commented as such, never guessed at.

## Per-issue loop (self-contained — run for every issue, every wave)

1. **Sync** — `git checkout main && git pull origin main`. Always branch fresh from main; never stack branches.
2. **Understand** — read the issue + linked threads. No code-intelligence MCP is configured for this repo: use Grep/Glob/Read directly, or dispatch the `Explore` sub-agent when a question spans many files and only the conclusion is needed. Re-verify any stored audit/plan claim against current main — audits go stale as main moves.
3. **Decide (only if genuinely ambiguous)** — most apparent decisions are already answered by `CLAUDE.md`, the ADRs in `docs/ADR/`, or the epic board; most of the rest are cheap and reversible, so decide, record, proceed. For what survives that — a real decision (epic scope, design fork, choosing among N approaches, or any of `CLAUDE.md`'s escalation triggers) — run the decision panel (the `architect` sub-agent), **pick the recommended option**, and **record the decision** in the session log plus a one-line note on the issue. Never block on the user.
4. **Implement (TDD)** — branch `<area>/<issue-number>-<slug>` (e.g. `smc/12-key-enumeration`), then RED → GREEN → REFACTOR. Match house style: Swift 6 with strict concurrency on; plain imperative commit subjects explaining *why*, never conventional-commit prefixes; `swift format lint --recursive --strict Sources Tests` and `swiftlint lint` both clean. Run the **full** per-package test suite locally (not just the touched file) before pushing — `swift build` then `swift test`. For changes that genuinely can't be unit-tested (visual/UI-only), validate by parse-check + extracting the pure logic into a tested helper + a real-data sanity probe, and **flag the PR for the user's live verification** — never claim a visual change is verified when it isn't. Hardware-dependent tests must **skip** cleanly both on CI (GitHub's macOS runners are VMs with no SMC) and on any Mac that is not `Mac16,5` — never fail there; use `isDevelopmentMachine()` in `Tests/SMCCoreTests/DevelopmentMachine.swift`.
5. **PR** — push, open a PR. Link the issue with a closing keyword: `Closes #N`. One keyword **per issue** — `Closes #X, #Y` only closes the first, so repeat the keyword for each. Avoid negated phrasings ("does NOT close #N" still auto-closes).
6. **Full review (MANDATORY)** — run `/full-review`. A sub-agent review is mandatory on **every** PR (read-only: `gh pr diff` / `git show <ref>:<path>`; a non-worktree review agent must **never** `git checkout`). Copilot Code Review runs automatically on PRs here and is best-effort: if it is blocked / quota-exhausted / not arriving, skip it and do not stall. Triage every thread. `CLAUDE.md` additionally makes the `reviewer` sub-agent mandatory — no exceptions — for any change touching `AeolusHelper`, the `SMCCore` write path, the XPC protocol, entitlements, or a safety mechanism. **A self-review by the author is not a review**: an adversarial pass has already caught blockers in PRs this project's own author reviewed and passed.
7. **Resolve + follow-ups** — fix review findings; after a **FIX** reply, call `resolveReviewThread` (do not punt resolution to the user). **File follow-up issues** for anything deferred and link them. All threads resolved before merge.
8. **Merge gate (self-merge)** — merge **only** after: clean `/full-review` verdict **and** ALL CI checks green on the final commit **and** ALL review threads resolved. Then **synchronous squash merge**; confirm the PR reports `MERGED`. **NEVER** `gh pr merge --auto`, `--admin`, or any protection override. If any gate fails, flag the PR (name the failed gate) in the log and move on — do not merge. On `main` this repository enforces three required checks (`Build and test`, `Monitor app build`, `Lint and format`), **strict up-to-date branches**, and **`required_conversation_resolution`**. Green CI is therefore necessary but **not sufficient**: verify `gh pr view <N> --json mergeStateStatus` reports `CLEAN` before ever claiming a PR is ready. Pushing a thread-resolution fix resets CI, and each merge pushes the remaining branches `BEHIND`, so a batch merges strictly serially — update branch, wait for CI, merge, repeat.
9. **Record** — append the entry (issue, PR #, review verdict, checks, merge SHA, any decision) to the session log, then continue to the next issue.

## Waves / queue

- **Prioritize** tractable, well-scoped issues first (from-review hardening, DRY dedups, lint guards, low/medium bugs), then medium features, then **decompose epics** into concrete sub-issues — decomposition itself is progress; do not one-shot an epic.
- **Replenish** the queue between waves: pick up sub-issues created by decomposition plus any newly-tractable issue. Escalate strategy on retries: fresh context → alternative approach → simplify scope → documented-blocked comment.
- **Converge:** if a wave produces zero new completions on the remaining set, stop and summarize. (For the full wave/retry/convergence machinery, this composes `/tackle-issues` — call it; do not re-implement it here.)

## Final step (only when the backlog is empty / converged)

Run a **SOLID + DRY** whole-project audit (`/project-audit`, or `/agent-review` over the accumulated diff if that skill is not installed) and file / act on its findings, then write the end-of-run report (below).

## Hard guardrails

### Universal — never strip (these are guarded)

- **Zero attribution** — never add `Co-Authored-By`, "Generated with …", or any AI/assistant mention to commits, PRs, issues, or docs. The user is the sole author.
- **Never commit to main** — feature branch + PR, always.
- **Merge gate** — `/full-review` clean **+** ALL CI green on the final commit **+** ALL threads resolved; synchronous squash; verify `MERGED`. **No** `--auto`, **no** `--admin`, **no** protection overrides.
- **Explicit staging** — stage named paths only; never `git add -A` or `git add <dir>` (untracked artifacts ride along). `git status --short` before every commit.
- **Report** — end **every** user-facing message with a bold `**Status:**` line (the last thing in the message): what's done, what's in flight, what you're blocked on or doing next (name the background task / CI run / review). At the end of a long run, also produce an executive brief the `visual-brief` skill into `$CLAUDE_BRIEF_DIR` (if that skill is not installed, write the self-contained HTML directly to that directory and open it): hero statement + outcome chips + a "needs you" callout on top, per-PR / bugs-caught / what's-next detail below. Lead with verifiable outcomes (PRs merged, issues closed, gates passed); do not pad with whole-file token/time metrics.

### Project-specific — build-breaking invariants (CUSTOMIZE)

- **E5 gates the write path** — no code that writes to the SMC merges before the safety subsystem exists and is tested. E5 blocks E3 and E4. Not deferrable to "after it works".
- **Write API stays `package`** — `SMCCore`'s write entry points are reachable only from `AeolusHelper`. Widening that is a safety review, not a refactor. Verify with `grep -rn "package func write" Sources/SMCCore/` on every PR; no write selector constant (the read selectors are 5, 8, 9) may appear anywhere in `Sources/`.
- **Never 0 RPM, never widen firmware bounds** — clamp *targets* to `[F0Mn, F0Mx]` read at runtime; config may narrow, never widen. Thermal ceilings tune downward only. Validate helper-side, after values cross the XPC boundary. The converse is equally load-bearing: an *observed* reading may legitimately be 0 or below `F0Mn` (`F0Ac` 1343.07 was measured against a declared `F0Mn` of 1350). Clamping governs targets, never observations, and no test may assume otherwise.
- **Manual control is a lease** — anything holding the fans keeps proving it is alive; expiry restores automatic control.
- **Never key on `uname -m`** — decode from the SMC's declared type. Byte order is firmware-declared per key via attribute bit `0x04` on the modern interface, for plain integers *and* `flt`/`ioft` (ADR 0003, ADR 0004). The same principle governs identifying the machine in tests: read `hw.model`, never the architecture string.
- **Byte order is one function** — `resolveByteOrder(generation:attributes:type:)` is the single policy point, deliberately, so a falsified hypothesis is a one-function retreat. Do not scatter the rule.
- **Strict concurrency stays on** — `@unchecked Sendable` in the helper is a claim needing review, not a way to silence the compiler.
- **Never claim untested hardware** — only `Mac16,5` is verified. Intel, M1/M2, and desktop Macs stay `untested` in the compatibility matrix. Scope every observed claim to one machine, one snapshot.
- **Cache metadata, never values** — a cached reading is a stale reading presented as current. `SMCConnection` caches key metadata only; every `read` issues a fresh `READ_BYTES`.
- **`READ_BYTES`'s own `dataSize` reads back 0** even on success — size payloads from the prior `READ_KEYINFO`. Trusting the reply field yields zero-byte reads that report success.
- **Generated files** — `Aeolus.xcodeproj` is gitignored; edit `project.yml` and run `xcodegen generate`. `Configs/Signing.xcconfig` is gitignored and absent on CI — never commit a Team ID.
- **XPC protocol changes** bump `AeolusXPCVersion` and say so in the PR.
- **Clean room** — never decompile or inspect Macs Fan Control or any commercial tool; cite every SMC source in `docs/SMC-RESEARCH.md` and honour its licence.

## State / where things live

- **Session log + decision log:** `autonomous-session-<date>.md` at repo root — gitignored, never commit. Source of truth for progress + decisions to present on interrupt. Its **first line carries the reload trigger** (Reliability rule 2). Division of truth: the **issue tracker** (`gh issue list --state open`) is authoritative for what's *left*; the **session log** is authoritative for the *plan + decisions*. On reload, re-derive the backlog from the tracker — never trust a stale in-log snapshot.
- **This directive:** invoke `/prime-directive` (compiled live artifact: `.claude/skills/prime-directive/SKILL.md`). Do not depend on the `.claude/commands/` path resolving (Reliability rule 1).
- **Issue list:** `gh issue list --state open`.
