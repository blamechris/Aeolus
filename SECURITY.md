# Security Policy

Aeolus ships a daemon that runs as root and writes to your Mac's firmware. This document
describes what that means, what you are trusting, and how to report a problem.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Use GitHub's private reporting:
[Report a vulnerability](https://github.com/blamechris/Aeolus/security/advisories/new).

What to expect:

| | |
|---|---|
| Acknowledgement | Within 7 days |
| Initial assessment | Within 14 days |
| Fix or mitigation plan | Communicated once the assessment is done |
| Public disclosure | Coordinated with you, after a fix ships |

This is a single-maintainer project run in spare time. Those windows are honest
commitments rather than an SLA, and complicated reports may take longer — you will be
told if so rather than left waiting.

Credit is given in the release notes unless you prefer otherwise.

### In scope

- Privilege escalation through the helper daemon or its XPC interface
- Bypassing client authorisation to issue privileged commands
- Anything that lets an unprivileged process set fan speeds, disable a safety mechanism,
  or suppress the thermal emergency override
- Tampering with the update mechanism or the sensor catalog load path
- Injection through the sensor catalog or a configuration file

### Out of scope

- Attacks requiring the attacker to already have root
- Attacks requiring SIP to be disabled
- Physical thermal damage caused by settings the user deliberately chose within the
  documented safety limits
- Vulnerabilities in macOS itself, though please do tell us if we depend on one

## Trust model

### What runs privileged

`AeolusHelper` is a launch daemon running as root. It is the **only** component that
writes to the SMC. The app and the CLI hold no privileges of their own; they ask the
helper, and the helper decides.

The helper ships inside `Aeolus.app` and is registered with
`SMAppService.daemon(plistName:)`. One consequence is worth stating because it is a
genuine security property: **deleting the app removes the daemon.** There is no orphaned
root process left behind, which was a real failure mode of the older `SMJobBless` flow.

### What the helper trusts

Nothing on the client side. Specifically:

- **Being able to connect is not authorisation.** Every incoming XPC connection is
  checked against a code-signing requirement — the caller must be signed by the expected
  Team ID with the expected identifier. Connections that fail the check are refused, not
  degraded.
- **Every parameter is hostile input.** Fan speeds are clamped against the firmware's own
  bounds after they arrive, not before they are sent. A malicious or buggy client cannot
  talk the helper into an unsafe speed by asking nicely.
- **The safety subsystem is not addressable over XPC.** There is no message that disables
  the lease, raises a thermal ceiling, or turns off the emergency override, because those
  messages do not exist.
- **The protocol is versioned** and negotiated at connect. A mismatched client is
  rejected with a clear error rather than being allowed to half-work.

### What you are trusting

Released builds are signed and notarised with **the maintainer's personal Apple Developer
ID**. There is no organisation behind this project. In practice that means:

- Every official release traces to one individual's certificate.
- **Forks cannot produce signed builds.** A fork can build and ship the `Monitor`
  configuration, which cannot write to fans at all; the write path requires that fork's
  own Developer ID.
- If that certificate were ever compromised, the mitigation is revocation plus a
  re-signed release, announced through the repository and the appcast.
- Should the project gain co-maintainers, releases move to an organisation-held identity
  with the signing key in CI secrets and no individual holding it locally. Until then,
  this is the honest situation.

Verify what you install:

```bash
codesign -dv --verbose=4 /Applications/Aeolus.app
spctl -a -vvv -t install /Applications/Aeolus.app
```

The Team ID reported there should match the one published in the release notes. Builds
from GitHub Releases are notarised and stapled, so they validate offline.

### Update channel

In-app updates use Sparkle 2 with an EdDSA-signed appcast. The signing key is separate
from the code-signing certificate, and an update that fails signature validation is not
installed. The appcast is served over HTTPS from GitHub Pages; GitHub Releases remain the
source of truth, and you can always ignore the updater and download manually.

### Data

Aeolus collects nothing and sends nothing. There is no analytics, no crash reporting, and
no network access other than the update check.

The optional metrics endpoint is **off by default**, binds to localhost only, and exposes
sensor readings and fan speeds — no personal data. Turning it on is a deliberate act.

## Known-dangerous surfaces

Named here so that reviewers know where to look hardest:

1. **The XPC boundary** (`Sources/AeolusXPC`, and the listener in `AeolusHelper`) — the
   privilege boundary itself, and the client authorisation check that guards it.
2. **The SMC write path** (`SMCCore`'s package-scoped write API) — deliberately not
   `public`, so that widening its reach is a visible change rather than an accident.
3. **The Apple Silicon unlock sequence** — writing the diagnostic force key to persuade
   the thermal manager to yield the fans, and re-establishing it after every wake. The
   most fragile code in the project.
4. **Sensor catalog loading** — a hot-loadable JSON file from the user's Application
   Support directory. Schema-validated, and never a source of executable behaviour.

## Supported versions

Pre-release. Once 1.0 ships, the latest minor release receives security fixes; this
section will say so specifically.
