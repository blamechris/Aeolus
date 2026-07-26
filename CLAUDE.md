# CLAUDE.md — operating instructions for Aeolus

Read this before doing anything in this repository. It is not a summary of the code; it is
the set of rules that make working here safe.

**What this project is:** a free, open-source macOS app and CLI that monitors thermals and
controls fan speed on Apple Silicon and Intel Macs. It writes to firmware as root. A bug
here does not produce a stack trace — it produces a hot laptop.

Full design: [docs/DESIGN.md](docs/DESIGN.md). Architecture:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Safety: [docs/SAFETY.md](docs/SAFETY.md).

---

## Architecture in one screen

Two unprivileged clients — the SwiftUI app and `fanctl` — talk over `NSXPCConnection` to
`AeolusHelper`, a root launch daemon that is **the sole owner of every SMC write**. The
helper also runs the control loop and the safety supervisor. Below it, IOKit and the SMC
firmware.

| Target | What it is | Rules |
|---|---|---|
| `SMCCore` | IOKit connection, key enumeration, type codec | Read API `public`; write API `package`. Widening that is a safety review. |
| `FanKit` | Models, curve engine, profiles | Pure. No IOKit, no I/O. Keep it exhaustively testable. |
| `AeolusXPC` | The `@objc` protocol and DTOs | This *is* the privilege boundary. |
| `AeolusHelper` | Root daemon | The only writer. Highest review bar in the repo. |
| `fanctl` | CLI client | Read commands work with no helper and no signing. |
| `AeolusUI` / `Aeolus` | SwiftUI views / app bundle | A view of helper state, never an owner of it. |

The control loop lives in the helper, not the app, so that quitting or crashing a client
can never leave fans pinned. Do not move it.

## Hard rules

These are not style preferences. Violating one is a defect regardless of whether tests
pass.

1. **Safety before capability.** No code that writes to the SMC merges before the safety
   subsystem (E5) exists and is tested. E5 blocks E3 and E4. The lease is not a
   nice-to-have and is not deferrable to "after it works".
2. **Manual control is a lease, never a setting.** Anything holding the fans must keep
   proving it is alive. Lease expiry restores automatic control. "Persist across quit" is
   a helper-renewed lease, not an exception to this.
3. **Never allow 0 RPM.** Any path, any input, any configuration.
4. **Firmware bounds win.** Clamp to `[F0Mn, F0Mx]` read at runtime. A config file may
   narrow the range; it may never widen it and is never trusted over the hardware.
5. **Thermal ceilings are tunable downward only.** A config that raises one is rejected,
   not honoured. There is no XPC message that disables a safety mechanism, and none may
   be added.
6. **Never claim control you do not have.** If the system has reclaimed the fans, say so.
   A UI that reports a target speed nothing is honouring is worse than one reporting an
   error, because the user acts on it.
7. **Clamp and validate on the helper side**, after values cross the boundary. Client-side
   validation is a courtesy; helper-side validation is the control.
8. **Being able to connect is not authorisation.** Every XPC client is checked against a
   code-signing requirement.
9. **Key on the SMC's declared type, never on `uname -m`.** One code path serves both
   architectures and stands a chance of surviving future silicon.
10. **Strict concurrency stays on.** `@unchecked Sendable` in the helper is a claim needing
    review, not a way to silence the compiler.
11. **Do not fake hardware support.** If a Mac family cannot be tested, the compatibility
    matrix says `untested`. Never claim support that has not been verified.

## Clean room

- **Never decompile, disassemble, or inspect Macs Fan Control** or any commercial tool in
  this category. Not to check a value, not out of curiosity.
- **Never copy its assets, icons, strings, or branding.** A two-pane layout is an idea;
  ideas are not owned. We still write our own everything.
- **Never use "Macs Fan Control", "MacsFanControl", or crystalidea marks** in the project
  name, a domain, the repository description, or release text. Describing Aeolus as an
  alternative to it, in prose, is accurate and fine.
- **Cite every SMC source** in [docs/SMC-RESEARCH.md](docs/SMC-RESEARCH.md) and honour its
  licence. Reading documentation and reimplementing from described behaviour is not
  adaptation; copying an implementation is, and carries its licence.

## Research before coding the Apple Silicon path

[docs/SMC-RESEARCH.md](docs/SMC-RESEARCH.md) currently contains **community reports, not
verified fact**. The `Ftst` unlock sequence, the ~3 second yield, the ~300-attempt retry
budget — all of it is a hypothesis to test on this machine, not a specification to
implement against.

Fill in the observed section from actual behaviour on the development hardware before
implementing E4. Disagreements between what is reported and what is observed are the most
valuable thing that document can contain.

## Build and test

```bash
swift build                  # libraries, CLI, helper — no Xcode needed
swift test                   # the fast loop; run this before every commit
xcodegen generate            # regenerate Aeolus.xcodeproj after editing project.yml
```

```bash
xcodebuild -project Aeolus.xcodeproj -scheme "Aeolus (Monitor)" \
  -configuration "Monitor Debug" -destination "platform=macOS" build
```

- `Aeolus.xcodeproj` is **generated and gitignored**. Never commit it; edit `project.yml`.
- `Configs/Signing.xcconfig` is gitignored and absent on CI. Never commit a Team ID.
- The `Monitor` configuration needs no certificate and is what CI builds. `Full` needs a
  Developer ID and only the maintainer can produce it.
- CI cannot verify fan writes — GitHub's macOS runners are VMs with no SMC. Hardware
  verification is manual, always.

## Development hardware

One machine: `Mac16,5`, Apple M4 Max, macOS 26.5.2.

That is an M3-or-newer part, so the hardest write path can be tested here. **The Intel
path and the M1/M2 path cannot be tested at all.** Never mark them as working. Code for
them is written against documented behaviour and shipped as `untested` until someone
reports otherwise.

## Model delegation

Route by **blast radius**, not by apparent difficulty. A one-line change in the helper
outranks a large SwiftUI refactor.

| Tier | Agent | Use for |
|---|---|---|
| **Fable** | `architect` | Decisions expensive to reverse: the Apple Silicon unlock strategy, security review of the XPC boundary and client authorisation, safety subsystem design review, licence strategy. Call it **before** implementation, not to repair it. |
| **Opus** | `reviewer`, and this session | Epic decomposition, issue specs, reviewing all Sonnet output, integration, and **any code that writes to the SMC or runs as root**. |
| **Sonnet** | `implementer` | SwiftUI views, data models, catalog wiring, unit tests, CLI argument parsing, CI YAML, documentation prose, refactors with tests already green. The bulk of the work. |
| **Haiku** | `chore-runner` | Labels, issue templates, changelog entries, formatting, mechanical renames. |

**Hard rule:** no Sonnet-authored code lands in `AeolusHelper` or `SMCCore`'s write path
without Opus review. Everything else is fair game for delegation — and should be delegated.
Reserve your own turns for design, review, integration, and anything touching root or the
SMC write path.

### Escalation triggers

Escalate immediately, without being asked, when any of these is true:

- **The task touches the privilege boundary** — XPC, client authorisation, entitlements,
  the helper's lifecycle. Sonnet → Opus. If it changes the boundary's *shape* rather than
  its implementation, Opus → Fable.
- **A test fails in a way that suggests the design is wrong**, not the code. Do not fix
  the test. Escalate.
- **Hardware behaviour contradicts documented expectations.** This is the expected case on
  the Apple Silicon path. Record it in `docs/SMC-RESEARCH.md` and escalate rather than
  coding around it.
- **Two approaches both look correct and the choice is hard to undo.** That is precisely
  the Fable case; a cheap consultation now beats an expensive migration later.

## Working in this repository

- Branch from `main`; `main` requires a pull request and green CI.
- Commit in logical chunks with messages that explain **why**. Do not dump a session's
  work into one commit.
- **No AI or agent attribution anywhere** — no `Co-Authored-By` trailers for tools, no
  "generated with" footers in commits, PRs, issues, or documentation.
- New behaviour comes with tests. `FanKit` is pure and has no excuse.
- Changing the XPC protocol means bumping `AeolusXPCVersion` and saying so in the PR.
- The epic board is the source of truth for sequencing. Check dependencies before starting
  work; several epics are explicitly blocked by others.

## Decisions that are the maintainer's, not yours

Ask rather than assume: naming, licence, project scope, anything involving the signing
identity, and anything that would claim hardware support. Everything else is yours to
call — make the call and move on.
