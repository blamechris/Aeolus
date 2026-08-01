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

### Changed
- **XPC protocol, version 1** — the boundary contract took its shape ahead of any
  implementation. `hello` replaces `protocolVersion(reply:)` so the helper enforces
  version negotiation rather than asking the client to; the fault vocabulary and
  `FanState.manualControlAvailability` are complete and decode forward-tolerantly;
  request validation refuses rather than repairs, lease identifiers included. The
  protocol version stays at **1**: nothing implements or calls this contract yet, so no
  contract has ever shipped.
- **XPC protocol, still version 1** — the helper's first implementation landed and the
  contract did not move under it. One fault code was added, `helperFailed`, for the
  condition the vocabulary could not previously express: the helper could not read the
  machine. Adding a case to a forward-tolerantly decoded vocabulary is additive by the
  documented bump policy, and a peer that predates it decodes the value generically. Reply
  blocks are now declared `@Sendable`, which is an annotation rather than a message: the
  selectors, the wire format, and the message set are unchanged. **The pre-ship window that
  allowed v1 to be reshaped closes here** — from now on the bump policy binds without
  exception.

[Unreleased]: https://github.com/blamechris/Aeolus/commits/main
