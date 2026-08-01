# ADR 0005 — XPC client authorisation and boundary versioning

- **Status:** Proposed
- **Date:** 2026-07-29
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** —

## Context

E2 builds the privilege boundary: an unprivileged app and CLI commanding a root daemon that will
eventually write to fan firmware. Two mechanisms decide whether that boundary holds — how the helper
decides a client is *ours*, and how a version skew between a Homebrew-installed CLI, an updated app,
and an installed helper fails.

Constraints from [CLAUDE.md](../../CLAUDE.md) are inputs, not open questions: being able to connect
is not authorisation (rule 8); no XPC message may disable a safety mechanism (rule 5); the helper is
the sole authority (rules 1, 2, 7). The `Monitor` configuration must keep building with no
certificate, and the project has one test machine (`Mac16,5`) plus CI with neither an SMC nor a
signing identity.

Three authorisation mechanisms were considered:

1. PID-based identity lookup.
2. Hand-rolled audit-token validation (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity`).
3. `NSXPCConnection.setCodeSigningRequirement(_:)`.

Verified against the macOS 26.5 SDK before deciding: that API is
`API_AVAILABLE(macos(13.0))`, and the project's floor is `13.0` in both `Package.swift` and
`project.yml`. It lands exactly on the floor — no availability gate, no floor raise.

## Decision

**Authorisation: option 3.** In `listener(_:shouldAcceptNewConnection:)`, before `resume()`, the
helper sets a code-signing requirement on every connection: Developer ID chain, leaf `subject.OU`
equal to the **helper's own Team ID read from its own signature at runtime**, identifier in
`{com.blamechris.Aeolus, com.blamechris.fanctl}`, and — in the Release helper — absence of
`com.apple.security.get-task-allow`. The Debug helper additionally accepts Apple Development leaf
certificates of the same team.

Requirement construction is pure, unit-tested code; the string is pre-compiled with
`SecRequirementCreateWithString`. Every failure resolves to **refuse all connections**, logged at
fault level:

| Condition | Behaviour |
|---|---|
| Helper's own signing info carries no Team ID (ad-hoc, unsigned) | Refuse all |
| Requirement string fails to compile | Refuse all; never pass an uncompiled string onward |
| Delegate cannot configure a connection for any reason | Return `false` — refusal is the default, acceptance the explicit act |
| Startup negative control: an Apple-signed binary from the wrong team *passes* the requirement | Refuse all — the requirement is broken |

Clients set the mirror requirement on their side and always connect `.privileged`, so a per-user
impostor agent squatting the mach name is unreachable.

**Versioning: the helper enforces negotiation.** Every connection is refused with
`handshakeRequired` until `hello(clientProtocolVersion:)` succeeds with a version inside
`[minimumSupported, current]`. Out-of-range clients are refused with **both** sides' ranges in the
error, so a client can say "helper supports 1–1, this client speaks 3 — update Aeolus.app" rather
than shrugging. **Refuse, never degrade.**

One deliberate exemption: **`restoreAllToAutomatic` bypasses the handshake gate** — never the
authorisation gate — and its semantics are frozen at v1 permanently.

**The protocol carries fan-control intents, never SMC operations.** There is no "write key K with
bytes B" message and there never will be one; a generic key-write would make the helper a root SMC
proxy and reduce every safety mechanism to decoration. Equally absent, permanently: any message that
raises a ceiling, disables the lease, widens bounds, or enables an "advanced mode". Not *refused* —
inexpressible.

**Consequence accepted knowingly:** the helper is absent from the `Monitor` configuration, and a
from-source or Homebrew-built `fanctl` can never command the helper. Reads never needed it; writes
require the signed `fanctl` shipped in the app bundle. Recovery without a signed client remains
`sudo launchctl bootout`, per [RECOVERY.md](../RECOVERY.md).

## Rationale

PID-based identity fails to PID-reuse and exec-after-check races. It is the canonical hole in exactly
this architecture, and was rejected outright.

The hand-rolled audit-token path is correct when written correctly — and every one of its failure
modes is a defect *we* author into root code: dynamic-versus-static validity, flag choices, check
placement, an early return that skips it. This project's review record already includes several cases
where a safety mechanism was itself the defect (a tripwire that would hang before firing, a
cross-check comparing a number to itself, a fail-safe that killed all enumeration). Hand-rolled
root-side security code is that risk class. `NSXPCConnection` also exposes no public audit token,
forcing a shim over a private structure layout.

`setCodeSigningRequirement` moves enforcement into libxpc, keyed on the audit token, evaluated before
any message is delivered, behind a public API at exactly our deployment floor. The residual risk — a
wrong requirement string — is confined to pure, exhaustively testable construction code with
refuse-all as every error's terminal state.

**Same-team-as-self rather than a hardcoded Team ID** keeps the Team ID out of the repository
(`Configs/Signing.xcconfig` is gitignored and absent on CI), gives a fork with its own Developer ID a
correctly-guarded helper for free, and makes an accidentally ad-hoc-signed helper inert by
construction rather than by vigilance.

**Helper-enforced handshake** is rule 8 applied to versioning: a stale client must be *unable* to
proceed unchecked, not merely expected not to. The current `protocolVersion(reply:)` hands the number
to the client and hopes it compares.

**Why the panic path is exempt.** `restoreAllToAutomatic` returns everything to Apple's control,
clears the force key, and drops all leases. Its only expressible effect is the safe state. A version
fence that stopped a panicked user's older `fanctl` from restoring automatic control would be a
safety mechanism defeating safety — precisely the defect class this project keeps finding. The panic
path must carry the fewest preconditions of anything in the protocol.

## The lease: client-renewed, helper-enforced, two independent teardown paths

- **Renewal is client-driven** on the heartbeat interval (TTL/3, per [SAFETY.md](../SAFETY.md) §1).
  A helper-driven "ping the client" inversion is rejected: it makes the root daemon depend on client
  responsiveness and moves authority the wrong way across the boundary.
- **Enforcement is helper-internal against a monotonic clock.** The `expiresAt` in the `Lease` DTO is
  display-grade; the supervisor enforces on `ContinuousClock`, so a wall-clock jump — NTP, a user
  setting the clock back — can never extend a lease, and time asleep counts against the TTL.
- **A lease is bound to the connection that acquired it.** A valid UUID presented on a different
  connection is refused.
- **Connection death is an immediate release.** The invalidation handler for a lease-holding
  connection restores those fans at once — covering crash, `SIGKILL`, and logout within milliseconds,
  because the kernel tears the mach port down regardless of how the process died.
- **The TTL is the independent backstop** for the case where invalidation never fires. Either
  mechanism alone suffices; both must fail for the fans to stay pinned; **they share no code path.**

## The E2/E5 seam

E2 owns everything from the mach port to a dispatch onto an internal `FanAuthority` protocol. E5 owns
everything behind it. E2 ships `ReadOnlyFanAuthority`:

- `snapshot` serves **real data** — fans and sensors through `SMCCore`'s public read API — with
  `activeLease: nil`, every fan `.automatic`, and every fan
  `manualControlAvailability: .unavailable(.writePathNotBuilt)`. This makes E2 demonstrable
  end-to-end on hardware without a write path existing.
- `acquireLease`/`renewLease`/`releaseLease`/`apply` **refuse** with `.manualControlUnavailable`.
  Never a stubbed success: a lease you can acquire that controls nothing is a lie about control —
  rule 6's exact shape.
- `restoreAllToAutomatic` **succeeds as a truthful no-op**: in E2 every fan is already automatic.
  This wires and tests the panic path from day one.

Three things E2 builds now purely so E5 and #37 cannot force a protocol change later — the same
forward-compatibility argument that put `isReclaimedBySystem` into E7's view models before any helper
could set it:

1. **The fault vocabulary**, complete, with forward-tolerant decoding (an unrecognised code decodes
   to `.unknown(raw)`). E2 raises only a handful; the rest exist so E5 can raise them without a bump.
2. **`FanState.manualControlAvailability`** — `available` / `unavailable(reason)`, covering
   `writePathNotBuilt` (E2) and `boundsImplausible` (#37, which requires the UI and CLI to surface
   *why* a fan cannot be controlled, distinct from "no helper" and "fan not found").
3. **`HelloReply.capabilities`** — an opaque, ignorable string set, so E3/E4/E10b can advertise
   without renegotiating. A capability may gate a convenience, **never** a safety mechanism.

## Alternatives considered

### Hand-rolled audit-token validation

The traditional approach, and the designated fallback if `setCodeSigningRequirement` proves defective
on some supported macOS. Rejected as primary for the reasons above. The delegate remains the single
place connections are configured precisely so this swap stays localised.

### Per-method authorisation tiers (an unauthenticated panic path)

Letting any process call `restoreAllToAutomatic` reads attractively — restore-to-safe for everyone.
Rejected: connection-level enforcement cannot express it, so it would drag in manual audit-token
checking for one method; and an unauthenticated root-daemon endpoint is a standing denial-of-service
(any process resetting a user's fans) for a recovery case `launchctl bootout` already serves.

### Degrade-on-mismatch versioning

Rejected. Both endpoints are ours; a compatibility matrix's only real consumers are bugs, and silent
degradation between a client and a root daemon is how safety mechanisms end up not running. Additive
optional DTO fields within a version, plus the capability set, provide the flexibility needed.

## What fails closed, and how you would know if it did not

1. No Team ID, uncompilable requirement, or any delegate error → **refuse all**. Known by unit tests
   on every row, fault-level logs, the startup negative control, and a `Mac16,5` checklist item that
   re-runs on every boundary change.
2. Pre-handshake and out-of-range clients → refused **per connection by the helper**, not by client
   courtesy. Known by CI integration tests over anonymous listeners.
3. Malformed payloads → refused whole, never partially applied or silently corrected.
4. **E2 cannot fail open into a write, because there is no write to fail into.** `SMCConnection.write`
   still throws and no write selector exists in the tree. Building the boundary while the thing
   behind it is inert is E2's strongest fail-closed property, and the reason E2 → E5 → E3/E4 is the
   right order.
5. The one deliberate fail-*safe*-not-closed: `restoreAllToAutomatic` stays reachable pre-handshake.
   Residual exposure is an authorised same-team client resetting fans it did not lease — an annoyance
   bounded by the auth gate, traded for a panic path with minimal preconditions.
6. Every accept and refuse is logged with identifier, team, and reason under a dedicated category, so
   "did the boundary refuse?" is answerable from `log show` on a user's machine.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| `setCodeSigningRequirement` behaves as documented on macOS 26.x | Verified present in the SDK at `macos(13.0)`; behaviour untested | Fall back to hand-rolled audit-token checking behind the same delegate seam |
| Same API behaves correctly on macOS 13–15 | Documented-available; **untestable here** | Ships the same "documented, untested" status as the Intel path; the compatibility matrix must say so |
| `SMAppService.daemon` registration works from a Development-signed Debug build | Unverified | Local iteration falls back to a manually `launchctl`-bootstrapped helper — a dev-workflow cost, not a design change |

**Verification log — 2026-07-31 (#73).** The last row above remains **unverified, and the
reason is now known precisely.** The development machine has no signing identity
configured for this project at all: `Configs/Signing.xcconfig` is absent, and a `Full`
build asked to sign with `Apple Development` stops at *"Signing for 'Aeolus' requires a
development team."* No Development-signed or Developer ID-signed build can be produced
here, so `SMAppService.daemon` registration cannot be attempted — the question is blocked
on a certificate rather than answered.

Two things were established while finding that out. First, the embedding itself is
correct: a `Full` build compiles, embeds the helper at `Contents/MacOS/AeolusHelper` and
its job description at `Contents/Library/LaunchDaemons/`, and stops exactly at code
signing with a clear error naming both the app and the helper. Second — and this is the
part worth recording — **the registration question could not have been answered before
#73 regardless of certificates.** `project.yml` set `CODE_SIGN_IDENTITY: "-"` and
`DEVELOPMENT_TEAM: ""` as project-level build settings, which outrank the project's base
configuration file, so `Configs/Signing.xcconfig` was being silently overridden and every
`Full` build would have come out ad-hoc signed no matter what certificate was installed.
An ad-hoc helper is exactly the "no Team ID in its own signature → refuse all clients"
row of the failure table above, so the symptom would have looked like a broken design
rather than a build setting. Those two settings now apply to the `Monitor` configurations
only.

Resolving the open question needs one thing: a `Configs/Signing.xcconfig` with a real Team
ID and Developer ID, then a `Full Debug` build, `register()`, and a note of what
`SMAppService.Status` reports afterwards.

Nothing in this design depends on `docs/SMC-RESEARCH.md`'s reported-but-unverified section. E2 touches
no write, no `Ftst`, no unlock sequence — deliberately, because the boundary must not encode Apple
Silicon hypotheses. The only E4-adjacent commitments are fault codes and availability reasons, which
are vocabulary rather than behaviour.

**Revisit when:** the project gains co-maintainers or an organisation signing identity
(same-team-as-self may then want a pinned allow-list); a supported macOS is found where
`setCodeSigningRequirement` misbehaves; a concrete need for per-method authorisation appears (resist
until then); or field evidence shows connection invalidation is unreliable as a lease-teardown signal
(which would promote the TTL from backstop to primary — a change this design already tolerates).
