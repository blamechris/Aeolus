# Aeolus

Fan control and thermal monitoring for macOS. Free, open source, and notarised.

Aeolus watches your Mac's temperature sensors and, when you ask it to, takes over the
fans — a fixed speed, or a curve that follows whichever sensors you care about. It works
on Apple Silicon and Intel, from the menu bar or from the command line.

> **Status: not usable yet.** This repository currently contains its design, its plan,
> and a set of target skeletons that compile and do nothing. There is no release, no
> binary, and no working feature. Nothing reads a sensor and nothing writes to a fan.
> The [issue board](https://github.com/blamechris/Aeolus/issues) is the honest picture of
> where things stand.

---

## Why this exists

The best-known tool in this space is [Macs Fan Control](https://crystalidea.com/macs-fan-control),
and it is genuinely good software. Two things about it prompted this project:

1. **Presets are a paid feature.** Switching between "quiet" and "rendering" is the single
   most useful thing fan control does, and it sits behind a licence. Here it is just part
   of the app.
2. **Two-point curves.** You get a minimum temperature, a maximum temperature, and a
   straight line between them. That is enough for a lot of machines and not enough for
   the rest.

Aeolus aims at parity first and then past it: N-point curves, sensor groups so a fan can
follow `max(CPU, GPU, SSD)` instead of one sensor, profiles that switch themselves on
when you unplug or open Blender, and a real CLI for headless machines.

This project is an independent alternative. It is not affiliated with, derived from, or
endorsed by crystalidea, and no part of Macs Fan Control has been decompiled, inspected,
or copied in building it. See [CONTRIBUTING.md](CONTRIBUTING.md) for the clean-room rules
contributors are held to.

## What it will do

**Parity**

- Live fan readings — current, minimum, and maximum RPM per fan
- Live sensor list with friendly names, and the raw SMC key always visible next to them
- Per-fan automatic or manual control, at a fixed speed or following a sensor
- Menu bar readouts, several at once
- Named presets with one-click switching
- Settings that survive a reboot and reapply at login
- Fans returned to Apple's control whenever the app quits — every time, including crashes
- Third-party drive temperatures over S.M.A.R.T.

**Beyond parity**

- Multi-point fan curves with a drag-handle editor, hysteresis, and ramp limiting
- Sensor groups, so cooling the CPU cannot quietly cook the SSD
- Profiles that activate on AC/battery, lid state, external display, or a running process
- History, charts, and CSV/JSON export — not just what the temperature is right now
- Throttle detection, so you can answer "am I actually being throttled?"
- `fanctl`, a first-class CLI for scripting, SSH, and headless Mac minis — see
  [docs/CLI.md](docs/CLI.md) for the command reference and `--json` shapes
- An optional localhost metrics endpoint for homelab dashboards, off by default
- A hardware compatibility matrix that says "untested" when something is untested

## What it will not do

Filing these as bugs will get you a polite link back here:

- **Undervolting, CPU power limits, or battery charge limiting.** Different problem,
  different risks. [AlDente](https://apphousekitchen.com) covers the charging side.
- **Kernel extensions.** Not now, not later.
- **Windows or Boot Camp.**
- **Defeating Apple's thermal limits or throttling.** Aeolus can make your fans work
  harder. It cannot and will not make your Mac ignore its own safety limits.
- **Anything requiring SIP to be disabled.**

## Safety

Fan control software can damage hardware. Aeolus is built so that the obvious way to
cause that damage is unavailable:

- **Manual control is a lease, not a setting.** Whatever holds the fans has to keep
  saying so. If the app crashes, hangs, or is killed, the fans go back to automatic
  within seconds. Setting your fans low for silence and then forgetting about it while a
  two-hour render runs is not a state this software can be left in.
- **The firmware's limits win.** Speeds are clamped to the range the hardware reports.
  A configuration file cannot widen that range, and no fan can be stopped.
- **There is a ceiling you cannot raise.** Above a compiled-in temperature the fan is
  forced to maximum regardless of your curve. That limit can be lowered, never raised.
- **Sleep, wake, logout, shutdown, and uninstall all restore automatic control.**

[docs/SAFETY.md](docs/SAFETY.md) describes each mechanism and how it is tested.
[docs/RECOVERY.md](docs/RECOVERY.md) is the "my fans are stuck and the app will not
launch" document.

### Disclaimer

This software controls cooling hardware. Misuse — or a bug — can cause overheating,
thermal throttling, or permanent damage to your Mac. It is provided **without warranty of
any kind**, as set out in the [GPL-3.0 licence](LICENSE). You are responsible for what
you tell your fans to do.

## Hardware support

Support is claimed only for hardware someone has actually tested. Everything else is
listed as untested, which is not the same as broken — it usually just means nobody with
that Mac has reported back yet.

See [docs/HARDWARE-MATRIX.md](docs/HARDWARE-MATRIX.md), and please
[file a hardware report](https://github.com/blamechris/Aeolus/issues/new?template=hardware-report.yml)
if your Mac is missing. It needs no special setup.

One constraint worth knowing about up front: on Apple Silicon **M3 and newer**, macOS
actively holds the fans and rejects a straightforward request for manual control. There
is a known way around it, but it is fragile — it has to be re-established every time the
machine wakes from sleep. This is the hardest part of the project and the most likely to
behave differently on hardware we have not seen.

## Contributing

**You do not need an Apple Developer account.** The `Monitor` build — the entire user
interface, every sensor reading, the charts, and the sensor catalog — builds and runs with
no certificate at all:

```bash
xcodegen generate && open Aeolus.xcodeproj
```

Only the privileged helper that writes to the fans needs a paid Developer ID, because
macOS requires the app and its embedded daemon to share a real one. That is a limitation
of the platform, not a choice, and [CONTRIBUTING.md](CONTRIBUTING.md) explains how the
project is arranged around it.

The lowest-friction way to help is a **sensor catalog entry**: telling us that `Tp09` is
the efficiency-core cluster on your particular Mac. That is a JSON edit, it needs no
build, and it is the thing that makes this software readable rather than a wall of
four-character codes. See [docs/CATALOG.md](docs/CATALOG.md) for how.

## Licence

[GPL-3.0-or-later](LICENSE). The reasoning, and the MIT alternative that was considered
and rejected, are in [docs/ADR/0001-license.md](docs/ADR/0001-license.md).
