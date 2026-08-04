# Aeolus — Design Document v0.1

> **Working name.** `Aeolus` (Greek keeper of the winds). Final name is Epic 0's first
> decision. Alternates: `Zephyr`, `Bellows`, `Windward`, `Ventus`, `Gust`.
> Avoid: `ThermalForge`, `MacFanControl`, `smcFanControl`, `Stats` — all taken.
> **Never** use "Macs Fan Control" or any confusingly similar mark.

**What this is:** a free, open-source, notarized macOS app + CLI that monitors thermals and
controls fan speed on Apple Silicon and Intel Macs. Feature parity with Macs Fan Control,
then past it.

**Target platform priority:** Apple Silicon first (M1–M5), Intel second but not optional.

---

## 1. Why this is harder than it looks (read this first)

Three non-obvious constraints drive nearly every decision below. An agent that skips this
section will design the wrong thing.

### 1.1 Apple Silicon M3+ actively fights you

On Intel and on M1/M2, forcing manual fan control is a straightforward SMC write. From the
M3 generation onward it is not. `thermalmonitord` holds the fans in mode 3 and the firmware
rejects a naive manual-mode write with SMC error `0x82`. The known-working sequence is:

1. Attempt the mode write directly (`F0Md = 1`). This succeeds on M1/M2, and on M3+ when the
   system is not actively asserting mode 3.
2. On rejection: write the diagnostic/force key `Ftst = 1`.
3. Wait for the thermal manager to yield (~3 s observed; poll rather than sleep blindly).
4. Retry the mode write with bounded retries (~300 attempts at 100 ms is the figure the
   community implementations use).
5. Write the target RPM (`F0Tg`).
6. On release: restore mode to auto **and** write `Ftst = 0`.

**Critical follow-on:** sleep/wake resets `Ftst` in firmware and the system reclaims the
fans. Any implementation must run a supervision loop that detects reclamation and re-runs
the unlock sequence, or manual control silently stops working after the lid closes.

This is the single highest-risk area of the project. Treat it as a research task with a
written findings doc, not as a coding task. Prior art to read (do **not** copy code — see
§9 on licensing): `agoodkind/macos-smc-fan` (research write-up + docs), `exelban/stats`
issue #2928, `raminsharifi/MacFanControl`, `tw93/Mole` issue #1119.

### 1.2 Encoding differs by architecture — but key on *type*, not arch

| | Apple Silicon | Intel |
|---|---|---|
| RPM encoding | little-endian IEEE-754 float (`flt`) | big-endian 14.2 fixed point (`fpe2` / `fp78`, i.e. RPM << 2) |
| Force manual | `F0Md` per-fan mode key (+ `Ftst` on M3+) | `FS!` bitmask, bit *n* = fan *n* |

**Do not branch on `uname -m`.** Read each key's declared type from the SMC at runtime and
encode/decode according to that type. This handles both generations with one code path and
survives future silicon. Implement a type registry: `flt`, `fpe2`, `fp78`, `sp78`, `ui8`,
`ui16`, `ui32`, `si8`, `si16`, `{fds`, `ch8*`, `hex_`.

### 1.3 A privileged helper is mandatory, and it requires a real Developer ID

SMC *writes* need root. The modern path is `SMAppService.daemon(plistName:)`, which
registers a launch daemon that ships **inside the app bundle** (so it disappears when the
app is deleted — a real advantage over legacy `SMJobBless`). Consequences:

- The helper and the app must be signed with the **same Team ID** and a real Developer ID
  certificate. Self-signed and "Sign to Run Locally" do not work. CJ has a paid account, so
  this is a non-blocker — but it does mean **contributors without a paid account cannot
  build or test the write path.** Design for that explicitly (see §7.4).
- `SMAppService` cannot show a password prompt at registration time. The user must approve
  the background item in **System Settings → General → Login Items & Extensions**. First-run
  onboarding has to walk them through it or the app looks broken.
- Do **not** mix legacy `SMJobBless` plist keys (e.g. `SMAuthorizedClients`) into the helper's
  Info.plist. That combination produces confusing registration failures.
- CI runners are VMs with no SMC. GitHub Actions can build, lint, unit-test, sign, and
  notarize — it **cannot** validate fan writes. Hardware verification is manual.

---

## 2. Stack decision

**Chosen: pure Swift, SPM core + Xcode app target, generated project via XcodeGen.**

### Rationale

| Option | Verdict |
|---|---|
| **Swift + SwiftUI (chosen)** | `SMAppService`, `NSXPCConnection`, `IOKit`, `MenuBarExtra`, notarization, universal binaries — all first-class. Zero bridging. |
| Rust/Go core + Swift shell | Rust can call IOKit fine, but `NSXPCConnection` and `SMAppService` need ObjC bridging on both sides of the privilege boundary. That's a security-critical seam built in the least-supported language for the job. Rejected. |
| CLI/daemon first, GUI later | Tempting for an engineer audience, but the *stated* goal is uninstalling a GUI app. Instead: ship the CLI and GUI as two thin clients of the same helper from day one (§3), so we get both without sequencing them. |
| Electron/Tauri | Cannot host a launchd daemon in-bundle cleanly; large; wrong tool. Rejected. |

**Known cost:** Swift narrows the contributor pool versus Go/Rust. Mitigate with a
genuinely good `CONTRIBUTING.md`, a monitor-only build path that needs no certificate, and
small well-documented modules.

### Toolchain

- **Swift 6**, strict concurrency on. The helper is a long-lived actor-based service; data
  races here are a hardware-safety issue, not just a bug.
- **XcodeGen** (`project.yml`) so `project.pbxproj` stays out of git. Agents and humans both
  merge YAML far better than pbxproj. (Tuist is the alternative; heavier, more capable.)
- **swift-format** + **SwiftLint**, enforced in CI.
- **Sparkle 2** for in-app updates (EdDSA-signed appcast).
- **swift-argument-parser** for the CLI.
- Minimum deployment target: **macOS 13.0** (`SMAppService` requires it). macOS 14+ for
  `MenuBarExtra` niceties — gate with availability checks, don't raise the floor.

---

## 3. Architecture

```
┌──────────────────────┐        ┌──────────────────────┐
│  Aeolus.app          │        │  fanctl (CLI)        │
│  SwiftUI + MenuBar   │        │  argument-parser     │
└──────────┬───────────┘        └──────────┬───────────┘
           │        NSXPCConnection (mach service)      │
           └────────────────────┬──────────────────────┘
                                ▼
              ┌───────────────────────────────────┐
              │  AeolusHelper  (root launchd)     │
              │  ─ sole owner of all SMC writes   │
              │  ─ curve engine + control loop    │
              │  ─ safety supervisor + lease      │
              │  ─ client authz (code req check)  │
              └────────────────┬──────────────────┘
                               │ IOKit
                    ┌──────────▼───────────┐
                    │  AppleSMC / IOHID     │
                    └──────────┬───────────┘
                               ▼
                        SMC firmware
```

### Targets

| Target | Kind | Notes |
|---|---|---|
| `SMCCore` | SPM library | Key enumeration, type codec, IOKit connection. **Read-only API is public; write API is internal to the helper target.** |
| `FanKit` | SPM library | Fan/sensor models, curve engine, profile model, config schema. No IOKit. Pure and fully unit-testable. |
| `AeolusHelper` | executable, root daemon | Embedded at `Contents/MacOS/` + `Contents/Library/LaunchDaemons/`. The only writer. |
| `AeolusXPC` | SPM library | Shared `@objc` protocol + Codable DTOs. Imported by all three. |
| `fanctl` | executable | Thin XPC client. Also usable standalone in read-only mode. |
| `Aeolus` | app bundle | SwiftUI. Embeds helper + Sparkle. |

### Why the control loop lives in the helper, not the app

If the curve engine ran in the GUI, quitting the app or a GUI crash would leave fans pinned
at whatever they were last set to. Putting the loop in the helper means the helper is always
the authority on fan state and can enforce safety independently of any client. The GUI
becomes a view + editor of helper state.

### The lease (deadman switch) — the most important safety mechanism

Manual fan control is a **lease**, not a setting.

- A client requests manual control with a TTL (default 30 s).
- The client renews on a heartbeat (default every 10 s).
- If the lease expires — client crashed, was `kill -9`'d, GUI hung, user logged out — the
  helper **restores all fans to automatic and clears `Ftst`.**
- A user-facing "persist across app quit" mode still uses a lease; the helper itself renews
  it, and the helper's own launchd job is the thing keeping it alive.

Failure mode we are engineering against: user sets fans to 800 RPM for silence, app crashes,
user renders video for two hours, thermal damage. The lease makes that impossible.

---

## 4. Safety subsystem (non-negotiable, cannot be disabled by config)

1. **Hardware clamps.** Every target is clamped to `[max(F0Mn, 100), F0Mx]` read from the firmware at
   runtime. Never allow 0 RPM. Never trust a config file's bounds over the firmware's.
2. **Thermal emergency override.** The helper samples critical sensors every cycle. Above a
   compiled-in ceiling (default 95 °C CPU / 90 °C SSD, tunable *downward* only), it forces
   that fan to maximum, then hands back to automatic, and surfaces a notification. User
   curves cannot override this.
3. **Lease expiry → restore to auto** (§3).
4. **Sleep/wake supervision.** Register for `NSWorkspace.willSleepNotification` /
   `didWakeNotification` in the helper's context (`IORegisterForSystemPower`). Release
   control before sleep; re-acquire and re-run the `Ftst` unlock after wake, since firmware
   resets it.
5. **Reclamation watchdog.** Poll actual vs. target RPM. If the system has silently reclaimed
   the fans, either re-assert or fall back to auto and tell the user — never lie about state.
6. **Restore-on-everything.** App quit, helper `SIGTERM`, logout, shutdown, uninstall, crash
   (install a signal handler + `atexit`). Match Macs Fan Control's guarantee that quitting
   always returns fans to Apple's control.
7. **Panic path.** `fanctl reset --all` and a documented recovery procedure (including SMC
   reset key combos per Mac family) that works even if the app is unlaunchable.
8. **Rate limiting.** Cap ramp rate (default 200 RPM/s) and enforce hysteresis so a curve
   near a threshold can't oscillate the fan audibly or mechanically.

Every one of these gets a test. The lease and the emergency override get **integration**
tests against a mock SMC, plus a manual hardware test checklist.

---

## 5. Feature scope

### 5.1 Parity checklist (what Macs Fan Control does)

- [ ] Live fan list: current / min / max RPM per fan
- [ ] Live sensor list with friendly names (CPU, GPU, SSD, battery, ambient, PMU…)
- [ ] Two-pane main window (fans left, sensors right)
- [ ] Per-fan **Auto** vs **Custom**
- [ ] Custom: fixed constant RPM
- [ ] Custom: sensor-based — fan scales between min and max RPM across a temperature range
- [ ] Menu bar display of chosen sensor(s) and/or fan RPM; multiple items simultaneously
- [ ] Named presets, one-click switching (this is Macs Fan Control's **paid** feature — ours
      is free, and it's the headline "why switch" bullet)
- [ ] Settings persist across reboot and auto-apply at login
- [ ] Restore all fans to Auto on quit
- [ ] Third-party HDD/SSD temperature via S.M.A.R.T. (the classic iMac-drive-swap use case)
- [ ] Monitoring-only mode when all fans are on auto
- [ ] Wide model coverage: MacBook Pro/Air, iMac, Mac mini, Mac Studio, Mac Pro, Intel + AS

*Not in scope:* the Windows/Boot Camp build. Note it as an explicitly declined goal in the
README so nobody files it as a bug.

### 5.2 Beyond parity (the reason to switch)

| Feature | Why it wins |
|---|---|
| **Multi-point fan curves** | MFC gives you two points. We give an editable N-point curve with drag handles, per-fan, with hysteresis and ramp-rate limits. |
| **Sensor groups** | Drive a curve from `max(CPU die, GPU, SSD)` rather than one sensor. Prevents the classic "cooled the CPU, cooked the SSD" mistake. |
| **Profile auto-activation** | Switch profiles on triggers: on AC vs battery, clamshell/lid closed, external display attached, or when a named process is running (Xcode, Blender, ffmpeg, a game). |
| **History + charts** | Rolling ring buffer of all sensors, in-app charts, CSV/JSON export. MFC shows you *now*; we show you the render you ran last night. |
| **Throttle detection** | Surface CPU speed-limit / thermal-pressure events (`NSProcessInfo.thermalState`, power-status APIs) alongside temps. Answers "am I actually being throttled?" |
| **First-class CLI** | `fanctl` for scripting, SSH, and headless Mac minis. Homebrew-installable. |
| **Optional metrics endpoint** | Off by default, localhost-only: JSON or Prometheus text for homelab/Grafana users. |
| **Menu bar sparklines** | Tiny inline trend graph, not just a number. |
| **Honest hardware compat matrix** | Community-reported table of what works per model, published in-repo. |
| **Real uninstaller** | Deregisters the daemon, restores fans, removes prefs. Verifiable. |

### 5.3 Explicit non-goals (write these down early)

- Undervolting, CPU power limits, charge limiting (that's AlDente's territory)
- Kernel extensions of any kind
- Windows / Boot Camp
- Overriding Apple's thermal limits or defeating throttling
- Anything requiring SIP to be disabled

---

## 6. Data & sensor naming

The hardest maintenance problem in this category is **sensor names**. `Tp0C` means nothing
to a user, and the mapping differs per chip family and Mac model.

**Design:** a JSON catalog, versioned in-repo, shipped as a bundle resource and
hot-loadable from `~/Library/Application Support/<app>/catalog.json`.

```jsonc
{
  "schemaVersion": 1,
  "entries": [
    {
      "key": "Tp09",
      "match": { "chipFamily": ["M1", "M1 Pro", "M1 Max"] },
      "label": "CPU Efficiency Core Cluster",
      "category": "cpu",
      "confidence": "community"   // "verified" | "community" | "guess"
    }
  ]
}
```

Rules:
1. **Always** show the raw key alongside the friendly name (toggleable). Never let a wrong
   label silently mislead someone into a bad curve.
2. `confidence` is displayed in the UI. Guesses are marked as guesses.
3. Catalog contributions come via PR with a template that includes model identifier, chip,
   macOS version, and observed behavior. Catalog PRs need no Developer ID — this is the main
   low-friction contribution path.
4. Sensor discovery is dynamic (`#KEY` count + index→key lookup); the catalog only decorates.
   An unknown Mac shows every sensor it has, unlabeled, and still works.

**Research task for Epic 1:** on Apple Silicon, some thermal sensors are exposed through
`IOHIDEventSystemClient` rather than the SMC (this is what `powermetrics` reads). Determine
whether we need both providers or SMC alone is sufficient, and write it up. Design the
sensor layer behind a `SensorProvider` protocol so a second provider can be added without
churn either way.

---

## 7. Distribution & release

### 7.1 Signing / notarization

- Developer ID Application certificate; hardened runtime; `--options runtime`.
- Sign inner-out: helper → Sparkle XPC services → frameworks → app bundle.
- Notarize with `notarytool` using an App Store Connect **API key** (not an app-specific
  password) so CI has no interactive step. Staple the ticket to the DMG.
- Secrets in GitHub Actions: `APPLE_TEAM_ID`, `APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_PRIVATE_KEY`, `SPARKLE_ED_PRIVATE_KEY`.
  Import the cert into a temporary keychain in CI and destroy it in a cleanup step.
- **The certificate is CJ's personal identity.** Document the trust model in
  `SECURITY.md`: forks build unsigned monitor-only; only the maintainer's release pipeline
  produces signed builds. Have a plan for what happens if the project gains co-maintainers.

### 7.2 Channels

1. **GitHub Releases** — notarized, stapled DMG + detached checksums. Source of truth.
2. **Homebrew cask** (`brew install --cask <name>`) — own tap first, `homebrew-cask` once
   there's a release history.
3. **Homebrew formula for `fanctl`** — can be built from source by anyone (read-only mode
   works without signing; write mode requires the app's helper to be installed).
4. **Sparkle** in-app updates against a GitHub-Pages-hosted appcast.

### 7.3 Versioning

SemVer. The XPC protocol gets its **own** version number, negotiated at connect. A stale CLI
against a newer helper must fail loudly with a clear message, not misbehave.

### 7.4 The contributor-without-a-certificate problem

Build configurations:
- `Monitor` — read-only, no helper, no entitlements, ad-hoc signable. **Anyone can build
  and run this.** All UI, sensors, charts, catalog work happens here.
- `Full` — helper + entitlements, requires Team ID in a gitignored `.xcconfig`.

CI builds `Monitor` on every PR. `Full` builds only on the maintainer's tags. Make this
prominent in `CONTRIBUTING.md`, and add a `make monitor` one-liner.

---

## 8. Repository layout

```
<repo>/
├── .github/
│   ├── workflows/{ci.yml, release.yml, catalog-validate.yml}
│   ├── ISSUE_TEMPLATE/{bug.yml, hardware-report.yml, sensor-catalog.yml, feature.yml}
│   └── pull_request_template.md
├── .claude/
│   ├── skills/                  # pulled from skill-templates (see agent prompt)
│   ├── agents/                  # subagent definitions with model tiers
│   └── settings.json
├── Sources/
│   ├── SMCCore/
│   ├── FanKit/
│   ├── AeolusXPC/
│   ├── AeolusHelper/
│   ├── fanctl/
│   └── Aeolus/                  # SwiftUI app
├── Tests/{SMCCoreTests, FanKitTests, IntegrationTests}/
├── Resources/catalog/           # sensor catalog JSON + schema
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SAFETY.md
│   ├── SMC-RESEARCH.md          # AS unlock findings, key tables, observed behavior
│   ├── HARDWARE-MATRIX.md
│   ├── RECOVERY.md              # "my fans are stuck" panic doc
│   └── ADR/0001-*.md            # architecture decision records
├── scripts/{build.sh, sign.sh, notarize.sh, uninstall.sh}
├── project.yml                  # XcodeGen
├── Package.swift
├── CLAUDE.md                    # agent operating instructions
├── CONTRIBUTING.md · SECURITY.md · README.md · LICENSE · CHANGELOG.md
```

---

## 9. Legal & licensing

**License recommendation: GPL-3.0-or-later.**

Two reasons, one defensive and one practical:
- The whole premise is "this should not be a paid app." GPL keeps a repackage-and-sell fork
  from being trivial. MIT does not.
- The most relevant prior art (`smcFanControl`) is GPL. If any contributor reads it closely
  enough for its ideas to influence implementation, GPL compatibility removes an entire class
  of licensing anxiety. MIT would not.

Counter-argument to record in the ADR: MIT maximizes adoption and lets other tools embed
`SMCCore`. A split license (MIT for `SMCCore`/`FanKit`, GPL for the app) is a defensible
middle path and probably the best answer if `SMCCore` is meant to be a reusable community
library. **Make this Epic 0's second decision.**

**Clean-room discipline — put this in `CONTRIBUTING.md`:**
- Do not decompile, disassemble, or inspect Macs Fan Control binaries.
- Do not copy its UI assets, icons, strings, or branding. Two-pane layout is a UI *idea*, not
  a protected asset — but write our own everything.
- Do not use "Macs Fan Control", "MacsFanControl", or crystalidea marks in the name, domain,
  App Store text, or repo description. "Alternative to X" in prose is fine and accurate;
  naming ourselves after X is not.
- SMC key semantics come from published open-source projects and public research. **Cite
  sources in `docs/SMC-RESEARCH.md` and honor their licenses.** If code is adapted rather
  than reimplemented, attribute it and carry the license.

Add a `DISCLAIMER` in the README: this software controls cooling hardware; misuse can cause
thermal damage; provided without warranty. Not legal armor, but honest and appropriate.

---

## 10. Epics (GitHub issues board)

Create these as issues labeled `epic`, each with a checklist of child tasks, grouped into
four milestones. Sequencing matters: **E1–E2 gate everything, and E5 must land before any
write path is merged to `main`.**

**Milestone M0 — Bootstrap**
- **E0 — Repo, governance, decisions.** Name, license ADR, LICENSE, README, CONTRIBUTING,
  SECURITY, CODE_OF_CONDUCT, labels, issue/PR templates, `CLAUDE.md`, skills onboarding,
  XcodeGen scaffold, CI skeleton, branch protection.

**Milestone M1 — Monitor-only (shippable, zero risk)**
- **E1 — SMC read core.** IOKit connection, key enumeration (`#KEY`/index lookup), full type
  codec with round-trip tests, sensor model, `SensorProvider` protocol, IOHID investigation,
  `docs/SMC-RESEARCH.md` v1.
- **E6 — Sensor catalog.** Schema, seed data for common models, JSON validation CI, PR
  template, confidence levels, raw-key fallback.
- **E7 — App shell + monitoring UI.** Two-pane main window, `MenuBarExtra`, multi-item menu
  bar readouts, preferences, launch-at-login, `Monitor` build config.
- **E10a — CLI read commands.** `fanctl list`, `fanctl sensors`, `fanctl watch`, JSON output.
- **E14 — Drive temperatures.** S.M.A.R.T. for SATA, NVMe SMART log for NVMe, third-party
  drive support.

**Milestone M2 — Parity (write path)**
- **E2 — Privileged helper.** `SMAppService` daemon registration, XPC protocol + versioning,
  **client authorization via code-signing requirement check**, onboarding flow for the Login
  Items approval step, entitlements, install/uninstall lifecycle.
- **E5 — Safety subsystem.** ⚠️ *Merge before E3/E4.* Lease/deadman, hardware clamps, thermal
  emergency override, sleep/wake handling, reclamation watchdog, restore-on-exit paths,
  ramp limiting, `docs/SAFETY.md`, `docs/RECOVERY.md`, panic command.
- **E3 — Intel write path.** `FS!` bitmask, `fpe2` encoding, per-fan force/release.
- **E4 — Apple Silicon write path.** ⚠️ *Highest risk.* `F0Md` per fan, `Ftst` unlock
  sequence with bounded retry, `flt` encoding, M1/M2 vs M3+ divergence, post-wake
  re-assertion, error `0x82` handling, hardware test matrix.
- **E10b — CLI write commands.** `set`, `auto`, `reset --all`, profile switching.
- **E8a — Two-point sensor mode.** Parity-level sensor-based control.
- **E9a — Presets.** Named presets, one-click switch, persistence, auto-apply at login.

**Milestone M3 — Beyond parity**
- **E8b — Curve engine.** N-point curves, drag-handle editor, hysteresis, ramp limits,
  sensor groups with `max()`/`avg()` aggregation.
- **E9b — Profile automation.** Triggers: power source, clamshell, external display, running
  process. Rules engine + UI.
- **E11 — History & telemetry.** Ring buffer, charts, CSV/JSON export, throttle detection,
  optional localhost metrics endpoint (off by default).

**Milestone M4 — Ship**
- **E12 — Distribution.** Sign/notarize/staple pipeline, DMG, Sparkle appcast, Homebrew cask
  + formula, release automation, keychain hygiene in CI.
- **E13 — Docs & community.** Architecture docs, hardware compat matrix, screenshots,
  migration-from-Macs-Fan-Control guide, project site.
- **E15 — Uninstall & recovery.** Verified uninstaller, daemon deregistration, prefs cleanup,
  documented SMC-reset fallback.

---

## 11. Model delegation policy

The orchestrating agent should route work by **blast radius**, not by apparent difficulty.

| Tier | Use for |
|---|---|
| **Fable 5** (top) | Architecture decisions that are expensive to reverse; the Apple Silicon unlock strategy; security review of the XPC boundary and client authorization; safety subsystem design review; license strategy. Call it *before* implementation, not to fix implementation. |
| **Opus 5** (orchestrator, default) | Epic decomposition, writing issue specs, reviewing all Sonnet output, integration, and **any code that can write to the SMC or runs as root**. |
| **Sonnet 5** | SwiftUI views, data models, catalog wiring, unit tests, CLI argument parsing, CI YAML, docs prose, refactors with tests already green. The bulk of the work. |
| **Haiku 4.5** | Labels, issue templates, changelog entries, formatting, mechanical renames. |

**Hard rule:** no Sonnet-authored code lands in `AeolusHelper` or `SMCCore`'s write path
without Opus review. Everything else is fair game for delegation.

**Escalation triggers** (Sonnet → Opus → Fable): a task touches the privilege boundary; a
test fails in a way that suggests the design is wrong rather than the code; hardware behavior
contradicts documented expectations; two approaches both look correct and the choice is
hard to undo.

---

## 12. Open questions for CJ

1. Final project name.
2. License: GPL-3.0 for everything, or MIT core + GPL app?
3. Which Macs are available for hardware testing? (Chip + model identifier + macOS version —
   this determines what E4 can actually verify versus what ships marked "untested".)
4. Public repo from commit 1, or private until M1?
5. Is the optional metrics endpoint wanted, or scope creep?
