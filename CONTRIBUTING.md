# Contributing to Aeolus

Thank you for considering it. This document covers one awkward constraint honestly and
early, because it shapes everything else: **part of this project cannot be built without a
paid Apple Developer account, and most of it can.**

---

## The certificate problem, stated plainly

Writing to the SMC requires root. The supported way to get root on modern macOS is
`SMAppService.daemon(plistName:)`, which registers a launch daemon that ships inside the
app bundle. Apple requires that the app and its embedded helper be signed **with the same
Team ID, using a genuine Developer ID Application certificate**. Self-signed certificates
do not work. "Sign to Run Locally" does not work. There is no developer-mode escape hatch.

The practical consequence: a contributor without a paid Apple Developer account cannot
build or test the code that changes fan speed.

Rather than pretend otherwise, the project is arranged so that this blocks as little as
possible.

### Two build configurations

| | `Monitor` | `Full` |
|---|---|---|
| Needs a Developer ID | **No** | Yes |
| Privileged helper | Not built | Built and embedded |
| Entitlements | None | Yes |
| Reads sensors and fan speeds | Yes | Yes |
| Changes fan speeds | No | Yes |
| Built by CI on every PR | Yes | No — maintainer tags only |

**`Monitor` is not a stub.** It is the whole application minus the write path: the
two-pane window, the menu bar, every sensor reading, the charts, the history, the sensor
catalog, preferences, and the CLI's read commands. If you are working on any of that —
and most of the open work is — you never need a certificate.

## Getting set up

```bash
git clone https://github.com/blamechris/Aeolus.git
cd Aeolus
```

**Prerequisites:** macOS 13 or newer, Xcode 16 or newer, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### The libraries, the CLI, and the tests

No Xcode project needed:

```bash
swift build && swift test
```

This is what CI runs first, and it is the fastest loop for anything in `SMCCore`,
`FanKit`, `AeolusXPC`, or `fanctl`.

### The app

`Aeolus.xcodeproj` is generated from `project.yml` and is **not** committed —
`project.pbxproj` is unmergeable, and this repository expects a lot of parallel work.
Generate it, then open it:

```bash
xcodegen generate && open Aeolus.xcodeproj
```

Pick the **Aeolus (Monitor)** scheme. It builds and runs with ad-hoc signing.

If you change `project.yml`, re-run `xcodegen generate`. If you add a source file in
Xcode, it lands on disk in the right place and the next generation picks it up.

### Building the write path (maintainer, or contributors with a Developer ID)

```bash
cp Configs/Signing.xcconfig.example Configs/Signing.xcconfig
# fill in DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY
xcodegen generate
```

Then use the **Aeolus (Full)** scheme. `Configs/Signing.xcconfig` is gitignored; never
commit it, and never commit a Team ID.

Without that file the `Full` scheme fails immediately, before compiling anything, with
`Unable to open base configuration reference file`. With it but without a matching
certificate, it compiles and embeds everything and then stops at code signing with
`No "Developer ID Application" signing certificate … was found`. Both are the intended
outcomes: there is no configuration in which `Full` quietly produces an ad-hoc-signed
helper, because an ad-hoc-signed root daemon is one `SMAppService` will not register and
one that would refuse every client anyway — it can read no Team ID from its own signature.

After first launch you must approve the background item in **System Settings → General →
Login Items & Extensions**. `SMAppService` cannot prompt for this, so if you skip it the
app appears broken rather than unapproved. The app's own footer says so while it is
pending, and offers to open that settings pane.

**Registering from a Development-signed Debug build is still unverified.** Nobody has yet
run it on a machine with a signing identity — see the assumptions table in
[docs/ADR/0005-xpc-authorisation.md](docs/ADR/0005-xpc-authorisation.md). If it turns out
Apple Development certificates are not accepted for daemon registration, local iteration
falls back to bootstrapping the helper by hand:

```bash
sudo launchctl bootstrap system /Applications/Aeolus.app/Contents/Library/LaunchDaemons/com.blamechris.Aeolus.Helper.plist
sudo launchctl bootout system/com.blamechris.Aeolus.Helper   # when you are done
```

That is a development-workflow cost, not a design change: shipped builds are Developer ID
signed and register through `SMAppService` either way. If you do try it, please report
what happened — a clear negative is as useful as a success.

## The best first contribution: a sensor catalog entry

`Tp09` is a sensor. On some Macs it is the efficiency-core cluster. On others it is
something else entirely, and on most we simply do not know. The mapping from raw SMC keys
to names a human can read differs by chip family and by model, and there is no
authoritative source for it — only what people observe on the machines they own.

`Resources/catalog/catalog.json` is that record. Adding to it:

- needs **no certificate**, no Xcode, and no Swift
- is validated automatically in CI against `catalog.schema.json`
- is the single highest-value thing you can do for other people with your Mac

Use the [sensor catalog issue template](.github/ISSUE_TEMPLATE/sensor-catalog.yml) or open
a PR against the JSON directly. **[docs/CATALOG.md](docs/CATALOG.md) is the full guide** —
read it before your first entry; the three rules below are the summary, not the whole
story.

Three rules for catalog entries:

1. **Mark your confidence honestly.** `verified` means you confirmed it — you loaded that
   specific component and watched that specific sensor respond. `community` means it is
   the consensus. `guess` means it looks right. A guess labelled as a guess is useful; a
   guess labelled `verified` can lead someone to build a fan curve on the wrong sensor.
   Where you genuinely do not know, add no entry at all — an absent entry is the honest
   state.
2. **Scope it.** Include the chip family or model identifier your entry applies to. Keys
   mean different things on different silicon.
3. **Say where it came from.** An issue number, a PR, or a citation. Required in practice
   for `verified` — CI rejects a `verified` entry with no source.

## Reporting hardware

The [hardware report template](.github/ISSUE_TEMPLATE/hardware-report.yml) asks for your
model identifier, chip, and macOS version. This is how `docs/HARDWARE-MATRIX.md` gets
filled in, and it matters more than usual here: the project has access to exactly one Mac
for testing, so everything else in that matrix depends on reports.

A report saying "this does not work on my machine" is as valuable as one saying it does.

## Clean-room rules

These are not negotiable, and they apply to everyone including the maintainer.

- **Do not decompile, disassemble, or inspect Macs Fan Control**, or any other commercial
  tool in this category. Not to check a value, not out of curiosity.
- **Do not copy its assets, icons, strings, or branding.** A two-pane layout is a user
  interface idea and ideas are not owned — but we write our own everything.
- **Do not use "Macs Fan Control", "MacsFanControl", or crystalidea marks** in the project
  name, a domain, a repository description, or release text. Describing Aeolus as an
  alternative to it, in prose, is accurate and fine.
- **Cite every SMC source** in `docs/SMC-RESEARCH.md` and honour its licence. Key
  semantics come from published open-source projects and public research; where code is
  adapted rather than reimplemented, attribute it and carry its licence with it.

If you have read decompiled output of a commercial fan utility, please do not contribute
to the SMC layer. That is not an accusation of anything — it is how clean-room separation
stays credible.

## Safety rules for code

Anything under `Sources/AeolusHelper` or the write path of `Sources/SMCCore` runs as root
and can damage hardware. Contributions there are held to a higher standard:

- **The safety subsystem lands first.** No code that writes to the SMC merges before the
  lease, clamping, and emergency-override mechanisms exist and are tested. This is
  tracked as E5 and it blocks E3 and E4.
- **Never trust configuration over firmware.** Hardware bounds are read at runtime and
  are the final word.
- **Never allow 0 RPM**, by any code path, for any reason.
- **Never claim control you do not have.** If the system has reclaimed the fans, the UI
  says so. Reporting a target speed the hardware is ignoring is worse than reporting an
  error.
- **Every safety mechanism gets a test**, and the lease and emergency override get
  integration tests against a mock SMC.

See [docs/SAFETY.md](docs/SAFETY.md).

## Pull requests

- Branch from `main`. `main` requires a green CI run and a review.
- Keep commits logical and their messages explanatory — say why, not what.
- **No AI or agent attribution** in commits, PR descriptions, or documentation. No
  `Co-Authored-By` trailers for tools.
- New behaviour comes with tests. `FanKit` is pure and has no excuse not to be covered.
- If you change the XPC protocol, bump `AeolusXPCVersion` and say so in the PR. A stale
  client meeting a newer helper must fail loudly, never degrade quietly.

## Code style

`swift-format` and SwiftLint are enforced in CI. Swift 6 with strict concurrency is on
everywhere and is not to be worked around with `@unchecked Sendable` — in the helper, a
data race is a hardware-safety problem rather than a crash report.

## Licence

Contributions are accepted under [GPL-3.0-or-later](LICENSE), the licence this project
ships under.
