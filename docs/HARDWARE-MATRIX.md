# Hardware compatibility

**This project has access to one Mac.** Everything in the tables below that is not that
Mac depends on reports from people who own the hardware.

`untested` is the default and it is not a synonym for `broken` — it means nobody has
reported back yet. Aeolus will never claim support for hardware it has not been verified
on. If your Mac says `untested` here and it works, telling us is the single most useful
thing you can do.

[**File a hardware report**](https://github.com/blamechris/Aeolus/issues/new?template=hardware-report.yml)
— it needs no build, no certificate, and about two minutes.

## Status meanings

| Status | Meaning |
|---|---|
| `verified` | Confirmed by a maintainer on that exact hardware. |
| `reported` | Confirmed by a user report, with model identifier and macOS version. |
| `partial` | Some capability works; the limitation is noted. |
| `untested` | Nobody has reported on this hardware. |
| `broken` | Confirmed not to work, with an open issue. |

Two capabilities are tracked separately, because they fail independently:

- **Monitoring** — reading fans and sensors. Low risk, expected to work broadly.
- **Control** — writing fan speeds. This is where hardware differences bite.

## Development hardware

| Model identifier | Chip | macOS | Monitoring | Control |
|---|---|---|---|---|
| `Mac16,5` (MacBook Pro) | M4 Max | 26.6.2 | `untested` | `untested` |

Listed as untested rather than verified: this is the machine development happens on, but
neither capability exists yet, so there is nothing to have verified. It will move to
`verified` when E1 and E4 land — and only for this row.

## Apple Silicon

Fan control on **M3 and newer** requires an unlock sequence that M1 and M2 do not, and that
sequence is **reported** to need re-establishing after every wake from sleep. That second half is a
community report, not a measurement: see [SMC-RESEARCH.md](SMC-RESEARCH.md), "Sleep resets the force
key", which still carries it as *To verify (E4)*. The 2026-09-05 lid-close capture
([#68](https://github.com/blamechris/Aeolus/issues/68)) did **not** retire it — `Ftst` read `0x00`
both before and after, because nothing had ever set it. What that capture did establish is how many
wakes "every wake from sleep" means: **seven per lid close** on `Mac16,5`, six of them dark wakes
with no user present. Expect these generations to behave differently, and expect M3+ to be the
fragile one.

### M1 generation

| Model identifier | Model | Monitoring | Control |
|---|---|---|---|
| `MacBookAir10,1` | MacBook Air (M1, 2020) | `untested` | `untested` |
| `MacBookPro17,1` | MacBook Pro 13" (M1, 2020) | `untested` | `untested` |
| `MacBookPro18,1`–`18,4` | MacBook Pro 14"/16" (M1 Pro/Max, 2021) | `untested` | `untested` |
| `Macmini9,1` | Mac mini (M1, 2020) | `untested` | `untested` |
| `iMac21,1`, `iMac21,2` | iMac 24" (M1, 2021) | `untested` | `untested` |
| `Mac13,1`, `Mac13,2` | Mac Studio (M1 Max/Ultra, 2022) | `untested` | `untested` |

Note: the MacBook Air (M1) is fanless. Monitoring applies; control does not.

### M2 generation

| Model identifier | Model | Monitoring | Control |
|---|---|---|---|
| `Mac14,2` | MacBook Air 13" (M2, 2022) | `untested` | n/a — fanless |
| `Mac14,15` | MacBook Air 15" (M2, 2023) | `untested` | n/a — fanless |
| `Mac14,7` | MacBook Pro 13" (M2, 2022) | `untested` | `untested` |
| `Mac14,5`–`Mac14,10` | MacBook Pro 14"/16" (M2 Pro/Max, 2023) | `untested` | `untested` |
| `Mac14,3`, `Mac14,12` | Mac mini (M2/M2 Pro, 2023) | `untested` | `untested` |
| `Mac14,13`, `Mac14,14` | Mac Studio (M2 Max/Ultra, 2023) | `untested` | `untested` |
| `Mac14,8` | Mac Pro (M2 Ultra, 2023) | `untested` | `untested` |

### M3 generation and newer

The unlock sequence applies from here on.

| Model identifier | Model | Monitoring | Control |
|---|---|---|---|
| `Mac15,3`–`Mac15,11` | MacBook Pro 14"/16" (M3 family, 2023) | `untested` | `untested` |
| `Mac15,12`, `Mac15,13` | MacBook Air (M3, 2024) | `untested` | n/a — fanless |
| `Mac16,1`–`Mac16,8` | MacBook Pro 14"/16" (M4 family, 2024) | `untested` | `untested` |
| `Mac16,10`, `Mac16,11` | Mac mini (M4/M4 Pro, 2024) | `untested` | `untested` |
| `Mac16,9` | Mac Studio (M4 Max, 2025) | `untested` | `untested` |
| M5 family | — | `untested` | `untested` |

This list is not exhaustive and model identifiers may be wrong — corrections are welcome
as pull requests against this file.

## Intel

Intel uses a different force-manual mechanism (`FS!` bitmask) and a different RPM encoding
(`fpe2`) from Apple Silicon. It is second priority for this project, but it is not
optional, and no Intel hardware is available for development.

**Intel support depends entirely on user reports.** If you have an Intel Mac and are
willing to test, please say so on the issue tracker.

| Family | Monitoring | Control |
|---|---|---|
| MacBook Pro (2016–2020) | `untested` | `untested` |
| MacBook Air (2018–2020) | `untested` | `untested` |
| iMac (2017–2020) | `untested` | `untested` |
| iMac Pro (2017) | `untested` | `untested` |
| Mac mini (2018) | `untested` | `untested` |
| Mac Pro (2019) | `untested` | `untested` |

The classic use case for Intel iMacs — a replacement third-party drive with no thermal
sensor sending the fans to maximum — is tracked as E14 and needs an affected machine to
verify.

## macOS versions

| Version | Status | Notes |
|---|---|---|
| macOS 13 Ventura | `untested` | Minimum supported. `SMAppService` requires it. |
| macOS 14 Sonoma | `untested` | |
| macOS 15 Sequoia | `untested` | |
| macOS 26 | `untested` | Development platform. |

## How this file gets updated

A hardware report issue is triaged, and if it contains a model identifier, a chip, a macOS
version, and an observed behaviour, the row moves from `untested` to `reported` with a
link to the issue. Rows move to `verified` only from a maintainer's own hardware.

Rows are never moved on the basis of "it should work".
