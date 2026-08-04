# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The XPC protocol between clients and the privileged helper carries its **own** version
number, negotiated at connect time. Protocol changes are called out explicitly below.

## [Unreleased]

### Added
- Repository bootstrap: build manifests, CI skeleton, documentation set, contribution
  templates, and the epic board. No functional code yet.
- **The privileged helper now listens.** `AeolusHelper` runs an `NSXPCListener` on its mach
  service, applies the client code-signing requirement to every connection before resuming
  it, and enforces the version handshake per connection: every message except `hello` and
  the panic path is refused until a client has introduced itself with a version the helper
  speaks. An out-of-range client is refused with both sides' ranges, never quietly degraded.
- **`snapshot` serves real data** — every fan and every sensor read from the SMC by the root
  daemon. Sensor keys are discovered once and refreshed by subset read thereafter; the
  helper never attaches catalog labels, which stay a client-side concern.
- **Manual control is refused, not stubbed.** Acquiring, renewing, releasing, and applying
  all answer `manualControlUnavailable(writePathNotBuilt)`, and every fan reports itself as
  uncontrollable. There is no SMC write path in this build, and a lease that controlled
  nothing would be a lie about control. `fanctl reset --all`'s message succeeds as a
  truthful no-op, so the panic path is wired and tested from the day the boundary exists.
- **Fan bounds are checked before they are trusted.** `F<n>Mn`/`F<n>Mx` pass a
  plausibility gate — finite, non-negative, ascending, and inside a 100–20,000 RPM
  envelope — before a fan can be controlled at all. A fan that fails it is reported
  `manualControlAvailability: .unavailable(.boundsImplausible)`, distinct from "no helper"
  and from "no such fan", and **no target can be produced for it by any route**: only a
  fan that passed the gate yields a `FanControlEnvelope`, and an envelope is the only
  thing that can make a speed to write. No protocol change — E2 wrote that vocabulary in
  advance for exactly this.

### Fixed
- **The 0-RPM ban was vacuous on hardware declaring a minimum of zero.** Clamping a target
  into `[F<n>Mn, F<n>Mx]` — what `docs/SAFETY.md` § 2 specified — permits commanding a stop
  on any Mac whose firmware declares a zero minimum, which `docs/RECOVERY.md` says is normal
  for fans that stop at idle. The floor is now `max(F<n>Mn, 100)`, with the 100 compiled in
  and unreachable by configuration. Observations are untouched by this and by everything
  near it: a measured 1343.07 against a declared minimum of 1350 is a real reading and is
  reported as read.
- **A NaN target passed through the clamp unchanged**, because every comparison with NaN is
  false and so neither half of `min(max(_:_:)_:)` fired. It now resolves to the floor.
- **A NaN thermal ceiling silently disabled the thermal override** rather than tightening
  it: `min(requested, ceiling)` returns NaN, and `temperature > NaN` is false at every
  temperature. A ceiling that is not a temperature now falls back to the compiled default.
- **A curve's ramp cap was not enforced on the values that actually cross the privilege
  boundary.** `FanCurve.maximumRampRPMPerSecond` is client data inside a settings payload
  and is now clamped to the compiled 200 RPM/s cap when the curve is *decoded*, not only
  when one is built in Swift. Decoding also sorts the curve's points, which the synthesised
  decoder did not, despite the property documenting itself as kept sorted.

### Changed
- **XPC protocol, version 1** — the boundary contract took its shape ahead of any
  implementation. `hello` replaces `protocolVersion(reply:)` so the helper enforces
  version negotiation rather than asking the client to; the fault vocabulary and
  `FanState.manualControlAvailability` are complete and decode forward-tolerantly;
  request validation refuses rather than repairs, lease identifiers included. The
  protocol version stays at **1**: nothing implements or calls this contract yet, so no
  contract has ever shipped.
- **XPC protocol, still version 1 — and the last shape v1 will ever take.** The helper's
  first implementation landed, and the contract *did* move under it, in the one window where
  moving it is free.
  - **`FanState` was reshaped, breakingly.** The embedded `Fan` and the non-optional
    `actualRPM` are **gone**; `index`, `firmwareName`, and three `FanReading` fields
    replace them, each carrying either a measured value or the reason there is none.
    Removing required fields and changing the type of others is a **breaking** change by
    the documented bump policy, not an additive one, and it is legal here only because
    nothing has ever shipped that speaks v1. It was forced by the first real producer of a
    `SystemSnapshot`: a fan whose `F<n>Mx` did not read left the old shape with three
    options and all three were defects — drop the fan, serve a fabricated `0`, or fail the
    whole snapshot over one key.
  - **`helperFailed` was added to the fault vocabulary**, for the condition it could not
    previously express: the helper could not read the machine. That one *is* additive — a
    peer predating it decodes the value generically — and it is what an unencodable reply
    or a dead connection is now reported as, rather than blaming the client's payload.
  - Reply blocks are now declared `@Sendable`, an annotation rather than a message. The
    message set is unchanged and still carries exactly seven.

  **The pre-ship window that allowed v1 to be reshaped closes here.** The `FanState`
  reshape is the last change it permits. From now on the bump policy binds without
  exception: a change of that shape is version 2 and a migration.

[Unreleased]: https://github.com/blamechris/Aeolus/commits/main
