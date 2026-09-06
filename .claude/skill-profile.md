# Aeolus skill profile

## Project Context
- Tech: Swift 6 (strict concurrency), SwiftUI, IOKit, NSXPCConnection, SMAppService. macOS 13+ deployment target, universal (Apple Silicon + Intel).
- Build system: Swift Package Manager for libraries, CLI, and helper; XcodeGen (`project.yml`) generates `Aeolus.xcodeproj` for the app bundle. `Aeolus.xcodeproj` is gitignored.
- Repo: blamechris/Aeolus
- Main branch: main
- CI: required checks are `Build and test`, `Monitor app build`, and `Lint and format` (`.github/workflows/ci.yml`). `Validate sensor catalog` runs only on catalog changes.
- Status: Epic 0 complete — repository, docs, board, and target skeletons exist. No functional code yet; nothing reads a sensor or writes to a fan.
- Hard requirements (never regress):
  - The safety subsystem (E5) merges before any SMC write path (E3, E4).
  - Manual fan control is a lease, never a setting. Lease expiry restores automatic control.
  - 0 RPM is unreachable by any code path.
  - Fan speeds are clamped to firmware bounds read at runtime; configuration never widens them.
  - Thermal ceilings are tunable downward only; no XPC message may disable a safety mechanism.
  - `SMCCore`'s write API stays behind the `FanWrite` SPI group, nameable only from `AeolusHelper`.
  - Never claim hardware support that has not been verified — the compatibility matrix says `untested`.
  - Clean room: never decompile or inspect Macs Fan Control; cite every SMC source in `docs/SMC-RESEARCH.md`.

## Build / Test Commands
- Build (the gate): `swift build`
- Test: `swift test`
- App build: `xcodegen generate && xcodebuild -project Aeolus.xcodeproj -scheme "Aeolus (Monitor)" -configuration "Monitor Debug" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build`
- Lint/typecheck: `swift format lint --recursive --strict Sources Tests` and `swiftlint lint`
- Format: `swift format format --in-place --recursive Sources Tests`

## Conventions
- Branch prefix / naming: `<area>/<issue-number>-<slug>`, e.g. `smc/12-key-enumeration`
- Commit style: plain imperative subject explaining why, not conventional-commit prefixes. No AI or agent attribution anywhere — no `Co-Authored-By` for tools, no "generated with" footers.
- Source file patterns: `Sources/**/*.swift`, `Tests/**/*.swift`, `Resources/catalog/*.json`, `project.yml`, `Package.swift`, `.github/workflows/*.yml`
- Labels: `epic`, `bug`, `enhancement`, `milestone:M0`–`M4`, `area:smc`, `area:helper`, `area:ui`, `area:cli`, `area:catalog`, `area:ci`, `safety-critical`, `needs-hardware`, `good-first-issue`, `no-signing-required`, `hardware-report`
- Milestones: `M0 — Bootstrap`, `M1 — Monitor-only`, `M2 — Parity`, `M3 — Beyond parity`, `M4 — Ship`

## Skill Targets
targets: claude

## agent-review Customizations
Scale review depth to **blast radius, not diff size**. A three-line change in `Sources/AeolusHelper` outranks a thousand-line SwiftUI refactor.

Highest scrutiny, line by line: `Sources/AeolusHelper/**`, the SPI-gated write path in `Sources/SMCCore/**`, `Sources/AeolusXPC/**`, `Configs/*.entitlements`, `Configs/LaunchDaemons/**`.

Privileged-code checklist: clamping to firmware bounds on the helper side; no path reaching 0 RPM; lease expiry on every exit including crash and `SIGKILL`; thermal ceilings unraisable by configuration; client code-signing requirement checked before the request is honoured; every XPC parameter treated as hostile input; no state reported that the helper has not confirmed; no `@unchecked Sendable` or swallowed `try?` in the helper; restore-on-exit paths present and reachable; encoding keyed on the SMC's declared type rather than the architecture.

Be suspicious of: a test changed in the same commit as the code it tests; a safety check moved, reordered, or made conditional; a timeout or retry budget that "works on my machine"; any row added to `docs/HARDWARE-MATRIX.md` without an issue link behind it.

Escalate to the `architect` agent rather than approving when the change alters the shape of the privilege boundary, changes the Apple Silicon unlock strategy, or when a test fails in a way suggesting the design is wrong rather than the code.

## check-pr Customizations
Required checks that must be green before merge: `Build and test`, `Monitor app build`, `Lint and format`. Run `swift build && swift test` locally before pushing a fix; run `swift format format --in-place --recursive Sources Tests` for formatting comments.

Never resolve a review comment on privileged code by weakening the check it questions. If a reviewer asks why a safety mechanism is bypassed, the answer is to stop bypassing it.

## fix-ci Customizations
Required checks: `Build and test`, `Monitor app build`, `Lint and format`.

Common failures and their causes:
- `Monitor app build` failing means the repository has grown a dependency on `Configs/Signing.xcconfig`, which is gitignored and absent on CI and on every contributor's machine. That locks out outside contributors — fix the dependency, never add the file to CI.
- `Lint and format` failing on formatting: run `swift format format --in-place --recursive Sources Tests`.
- SwiftLint custom-rule failures (`no_zero_rpm_literal`, `no_unchecked_sendable_in_helper`, `no_silent_write_failure`) are safety invariants. Fix the code; do not add an inline disable.
- CI cannot verify fan writes — GitHub's macOS runners are VMs with no SMC. A test that needs hardware does not belong in CI.

## create-issue Customizations
Every issue states a Goal paragraph, explicit "Done when" acceptance criteria, and its dependencies as "Blocked by #N". Apply an `area:*` label, a `milestone:M*` label, and the matching GitHub milestone.

Apply `safety-critical` to anything touching the helper, the SMC write path, the XPC boundary, or a mechanism in `docs/SAFETY.md`. Apply `needs-hardware` to anything that cannot be verified in CI. Apply `no-signing-required` and `good-first-issue` to work that builds in the Monitor configuration.

Include a suggested model tier per the delegation policy in `CLAUDE.md`.

## decompose-issue Customizations
Parent issues here are epics (E0–E15) labelled `epic`. Child issues inherit the parent's `area:*` label, milestone, and `safety-critical` status — a child of a safety-critical epic is safety-critical.

Never decompose in a way that lets a write-path child merge before E5 (the safety subsystem). If a child would write to the SMC, state "Blocked by E5" in its body.

Prefer children that are independently mergeable and independently testable. A child that can only be verified on hardware gets `needs-hardware` and says which Mac family it needs.

## create-pr Customizations
Link the issue with "Closes #N" or "Part of #N". Tick the privileged-code section of the pull request template when the change touches `AeolusHelper`, the `SMCCore` write path, the XPC protocol, entitlements, or any mechanism in `docs/SAFETY.md`. Bump `AeolusXPCVersion` and say so when the protocol changes.

## changelog Customizations
`CHANGELOG.md` follows Keep a Changelog with SemVer. Call out XPC protocol version changes explicitly under their own note — a stale CLI against a newer helper must fail loudly, and users need to know when that boundary moved.

Group entries by user-visible impact rather than by module. Safety-relevant fixes are called out even when small.

## manual-testing-mode Customizations
Hardware verification is manual and cannot be automated: GitHub's macOS runners are VMs with no SMC. Available test hardware is a single `Mac16,5` (Apple M4 Max, macOS 26.5.2) — an M3-or-newer part, so the `Ftst` unlock path is testable but the Intel and M1/M2 paths are not.

Always test these before declaring a fan-control change good:
- Fans return to automatic when the app quits, and when it is `kill -9`'d
- Manual control survives sleep and wake (the `Ftst` reset case)
- Actual RPM follows target RPM, and reclamation is reported rather than hidden
- `fanctl reset --all` works from a cold start and with the app not running

File findings as issues rather than fixing inline. Anything in the first list failing is `safety-critical`.

## tiered-delegation Customizations
Route by blast radius, not apparent difficulty. Subagents are defined in `.claude/agents/`: `architect` (Fable), `reviewer` (Opus), `implementer` (Sonnet), `chore-runner` (Haiku).

Hard rule: no Sonnet-authored code lands in `AeolusHelper` or `SMCCore`'s write path without Opus review. Escalation triggers are in `CLAUDE.md` — a task touching the privilege boundary, a test failing in a way that suggests the design is wrong, hardware behaviour contradicting documentation, or two hard-to-reverse approaches both looking correct.
