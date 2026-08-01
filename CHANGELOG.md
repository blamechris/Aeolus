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

### Changed
- **XPC protocol, version 1** — the boundary contract took its shape ahead of any
  implementation. `hello` replaces `protocolVersion(reply:)` so the helper enforces
  version negotiation rather than asking the client to; the fault vocabulary and
  `FanState.manualControlAvailability` are complete and decode forward-tolerantly;
  request validation refuses rather than repairs, lease identifiers included. The
  protocol version stays at **1**: nothing implements or calls this contract yet, so no
  contract has ever shipped.

[Unreleased]: https://github.com/blamechris/Aeolus/commits/main
