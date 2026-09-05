# ADR 0005 — XPC client authorisation and boundary versioning

- **Status:** Accepted (2026-08-01)
- **Date:** 2026-07-29
- **Deciders:** Project maintainer, on architect review
- **Supersedes:** —
- **Extended by:** [ADR 0006](0006-single-smc-reader.md)

Accepted once three PRs implementing it had merged (#79 the contract, #80 the authorisation module,
#81 the lifecycle) **and** its central untested assumption had been settled by experiment: the
`setCodeSigningRequirement` row below moved from "documented, behaviour untested" to verified on this
machine. Accepting it before that would have ratified a design resting on an API nobody had watched
work.

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
  `activeLease: nil`, every fan's `mode` as `F<n>Md` declares it, and every fan
  `manualControlAvailability: .unavailable(.writePathNotBuilt)`. This makes E2 demonstrable
  end-to-end on hardware without a write path existing.

  > **Amended 2026-09-05 (#148).** This bullet read "every fan `.automatic`" until the mode was
  > read rather than asserted. A literal `.automatic` was a fact about the executable — nothing
  > here can take a fan off automatic control — and never an observation of the machine, so a fan
  > left in manual by another vendor's tool or by a crashed previous helper was reported as
  > managed. The mode is now read per fan; an unreadable `F<n>Md` still falls back to
  > `.automatic`, because v1's `FanControlMode` has no way to say "not known" —
  > [#178](https://github.com/blamechris/Aeolus/issues/178) holds that open half.
- `acquireLease`/`renewLease`/`releaseLease`/`apply` **refuse** with `.manualControlUnavailable`.
  Never a stubbed success: a lease you can acquire that controls nothing is a lie about control —
  rule 6's exact shape.
- `restoreAllToAutomatic` **succeeds as a no-op**: nothing in E2 can take a fan off automatic
  control, so the call leaves the machine as it found it. This wires and tests the panic path
  from day one.

  > **Amended 2026-09-05 (#148).** This bullet read "a truthful no-op: in E2 every fan is already
  > automatic". Reading `F<n>Md` falsified the premise, not the behaviour: a firmware-manual fan
  > is now observable in the same snapshot, and E2 has no write path with which to clear it. The
  > verb still succeeds — the panic path keeps the fewest preconditions it can have, and
  > [#159](https://github.com/blamechris/Aeolus/issues/159) ships its client before any write
  > path — and clearing such a fan belongs to startup reconciliation,
  > [#164](https://github.com/blamechris/Aeolus/issues/164).

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
6. Every accept and refuse is logged under a dedicated category, so "did the boundary refuse?" is
   answerable from `log show` on a user's machine — **but not with an identifier and a team, and this
   row said otherwise until #72 implemented it.** Two measured properties of
   `setCodeSigningRequirement` (see the 2026-08-01 verification log below) make that unimplementable.
   Enforcement is per *message*, so accepting a connection verifies nothing about the peer and no log
   line may claim it does; and libxpc drops a requirement-refused peer without reporting who it was,
   so a refusal is visible only as an invalidation with no message ever delivered — which is
   indistinguishable from a client that disconnected before its first message.

   What the boundary logs instead: the connection's `ConnectionID` and that the requirement was
   applied (no identity claim); at handshake, the negotiated version and the client's own
   *self-described* name, explicitly labelled as validated-not-verified; and at invalidation, the
   handshake state and the messages-delivered count, with zero naming both possibilities and
   preferring neither. Refusals are logged at info level, because a refused foreign binary is the
   mechanism working; fault level stays for the refuse-all rows, where the helper itself is broken.
   Saying the weaker true thing is rule 6 applied to the boundary's own diagnostics.

## Assumptions and what would invalidate them

| Assumption | Basis | If it fails |
|---|---|---|
| `setCodeSigningRequirement` behaves as documented on macOS 26.x | **Verified by experiment on `Mac16,5` / macOS 26.5.2 (25F84)** — see the #72 log below | Fall back to hand-rolled audit-token checking behind the same delegate seam |
| Same API behaves correctly on macOS 13–15 | Documented-available; **untestable here** | Ships the same "documented, untested" status as the Intel path; the compatibility matrix must say so |
| `SMAppService.daemon` registration works from a **Developer ID**-signed `Full Debug` build | Unverified | The shipping path itself does not work; E2 needs a different registration mechanism, not a workaround |
| `SMAppService.daemon` registration works from an **Apple Development**-signed build | Unverified | Local iteration falls back to a manually `launchctl`-bootstrapped helper — a dev-workflow cost, not a design change |

Those last two were one row until #81's review pointed out they name different certificates
and have different consequences. A Developer ID failure is a design problem; an Apple
Development failure is a workflow problem, and `CONTRIBUTING.md`'s manual `launchctl`
fallback exists for the second row specifically — for contributors who hold an Apple
Development certificate and no Developer ID. Verifying one says nothing about the other.

**Verification log — 2026-07-31 (#73).** The last two rows above remain **unverified, and
the reason is now known precisely.** The development machine has no signing identity
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

Resolving the **Developer ID** row needs one thing: a `Configs/Signing.xcconfig` with a
real Team ID and `CODE_SIGN_IDENTITY = Developer ID Application`, then a `Full Debug`
build, `register()`, and a note of what `SMAppService.Status` reports afterwards.

The **Apple Development** row needs a second run of the same steps with
`CODE_SIGN_IDENTITY = Apple Development` — a different certificate, and therefore a
separate result. Do not mark it verified off the Developer ID run.

One thing to expect on either run, so it is not mistaken for a failure: registration
currently installs a job description for a scaffold. `Sources/AeolusHelper/AeolusHelperMain.swift`
writes to stderr and exits non-zero by design, and the plist carries no `RunAtLoad` and no
`KeepAlive`, so launchd starts it only when something connects to the mach service. The
question these rows ask is whether `SMAppService` accepts and registers the job, not
whether the daemon does anything once started — it does not, until #72.

**Verification log — 2026-08-01 (#72). `setCodeSigningRequirement` is enforced.** Measured on
`Mac16,5` / macOS 26.5.2 (25F84) with an anonymous in-process `NSXPCListener`, so both peers carried
the same signature and the requirement was the only variable:

| Requirement applied to the connection | Client outcome |
|---|---|
| none | reply delivered |
| the binary's own designated requirement | reply delivered |
| `anchor apple` | **no reply** — connection invalidated |
| `identifier "com.example.definitely.not.us"` | **no reply** — connection invalidated |

The mechanism holds on this OS. The hand-rolled audit-token fallback is not needed here, and the
alternatives section stands unchanged as the contingency for an OS where this stops being true.
**Scoped to one machine and one OS version**, per `CLAUDE.md`: macOS 13–15 remain documented-untested
and the row above says so.

Three properties of the API matter to E2.3 and were not obvious from the ADR as written:

1. **It returns `Void`, and a malformed requirement throws.** `NSXPCConnection.h` says so, and the
   behaviour is worse than it sounds: the exception is an uncatchable `NSInvalidArgumentException`
   raised **inside `listener(_:shouldAcceptNewConnection:)`**, on a libxpc event thread. Confirmed —
   SIGABRT, exit 134. For a launchd on-demand root daemon that means aborting on *every* connection
   attempt, which is a denial of service triggered by a bad string rather than by an attacker.
   `ClientAuthorisationBuilder.seal` pre-compiling the text with `SecRequirementCreateWithString`
   before it can ever reach libxpc is therefore **load-bearing, not defensive**, and the fail-closed
   row "never pass an uncompiled string onward" is the thing preventing it. Nothing may construct a
   requirement string at the listener; `AuthorisedClientRequirement` has no public initialiser
   precisely so that this cannot be worked around.

2. **Enforcement is per-message, not at accept time.** `shouldAcceptNewConnection` returns `true` for
   a peer that will never be permitted to send anything. Accepting a connection is therefore *not*
   evidence that a client was authorised, and no log line or metric may say that it is — that would
   be rule 6's shape applied to the boundary's own diagnostics.

3. **The listener side does observe the refusal.** The connection's `invalidationHandler` fires and
   the message never reaches the exported object. So a refusal is loggable — but an invalidation with
   no message ever delivered is *consistent with* a requirement refusal rather than *proof* of one; a
   client that connected and disconnected before its first message looks identical. E2.3's logging
   says the weaker true thing, and fail-closed row 6 above was amended to match.

**What #72 could not verify, and nothing on CI ever will.** Mutation testing of E2.3 deleted the
`setCodeSigningRequirement` call from `SealedRequirementAdmission` and the full suite stayed green.
That mutation is a **known survivor, left in deliberately**: killing it needs a Developer ID
signature and a foreign-signed client process, which exist on no CI runner and on exactly one
machine. It is E2.5's manual `Mac16,5` checklist item — "an ad-hoc-built client is refused by the
installed helper" — and it is the reason that item is load-bearing rather than ceremonial. Every
listener test in the tree drives an admission policy declared in the *test target* that applies no
requirement at all, precisely so no production wiring can select one; a green suite says the gate and
the seam are correct, and says nothing whatever about the requirement.

Nothing in this design depends on `docs/SMC-RESEARCH.md`'s reported-but-unverified section. E2 touches
no write, no `Ftst`, no unlock sequence — deliberately, because the boundary must not encode Apple
Silicon hypotheses. The only E4-adjacent commitments are fault codes and availability reasons, which
are vocabulary rather than behaviour.

**Revisit when:** the project gains co-maintainers or an organisation signing identity
(same-team-as-self may then want a pinned allow-list); a supported macOS is found where
`setCodeSigningRequirement` misbehaves; a concrete need for per-method authorisation appears (resist
until then); or field evidence shows connection invalidation is unreliable as a lease-teardown signal
(which would promote the TTL from backstop to primary — a change this design already tolerates).
