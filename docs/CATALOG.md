# Contributing to the sensor catalog

`Tp09` means nothing to anyone. `Resources/catalog/catalog.json` is the record of what a
raw SMC key actually is, on a specific Mac — and it is the single lowest-friction
contribution to this project. No certificate, no Xcode, no Swift: a text editor and a pull
request against one JSON file.

This document is the full guide. The short version lives in
[CONTRIBUTING.md](../CONTRIBUTING.md); use the
[sensor catalog issue template](../.github/ISSUE_TEMPLATE/sensor-catalog.yml) if you would
rather not touch JSON at all.

---

## The one rule everything else follows from

**The catalog only decorates. It never gates.** A machine with zero matching catalog
entries still shows every sensor it has — raw key, current value, all of it — fully
functional. Nothing in Aeolus makes a reading, a fan curve, or any other capability depend
on a catalog entry existing. Adding an entry only ever adds a label; it can never make a
sensor appear or disappear, and it can never be wrong in a way that breaks anything —
only in a way that displays something misleading, which is exactly what the confidence
levels below exist to prevent.

**The raw key is always shown alongside the label, everywhere, with no exception.**
`fanctl sensors` prints both columns today. The app does not read the catalog yet —
`SensorListView` in `Sources/Aeolus/AeolusApp.swift` is a `TODO(E7)` placeholder with no
catalog reference at all — so this guarantee applies to `fanctl` in practice until E7
(#61–#64) lands the app's own sensor UI. A label is a convenience layered on top of the
key, never a replacement for it — see `CatalogDecoration` in
`Sources/FanKit/CatalogDecoration.swift`, which does not even have an API that resolves
anything *from* a label. If you are adding UI that shows a catalog label, showing the
label without the key next to it is a defect, not a style choice.

## Anatomy of one entry

```json
{
  "key": "Tp09",
  "match": { "modelIdentifier": ["Mac16,5"] },
  "label": "CPU Efficiency Core Cluster",
  "category": "cpu",
  "confidence": "community",
  "source": "https://github.com/blamechris/Aeolus/issues/123"
}
```

| Field | Required | Meaning |
|---|---|---|
| `key` | yes | The raw four-character SMC key, exactly as read — case matters (`Tp09`, not `tp09`). |
| `match` | no | Scopes the entry to specific hardware. Omit it only if the mapping is genuinely universal, which is rare — see below. |
| `label` | yes | The human-readable name. Always shown next to `key`, never instead of it. |
| `category` | yes | One of `cpu`, `gpu`, `memory`, `storage`, `battery`, `power`, `ambient`, `display`, `fan`, `other`. |
| `confidence` | yes | `verified`, `community`, or `guess` — see below. This is the field that keeps a wrong guess from quietly passing as fact. |
| `source` | in practice, yes for `verified` | Where the mapping came from. See below. |

The full field-level rules live in
[`Resources/catalog/catalog.schema.json`](../Resources/catalog/catalog.schema.json), and
every pull request against the catalog is validated against it automatically — see
"How this gets checked" below.

## Scoping: `match`

Most SMC keys mean different things on different chips, so most entries should declare a
`match`. Two axes, and you can use either or both:

- **`modelIdentifier`** — exact `hw.model` values, e.g. `["Mac16,5"]`. Run
  `sysctl -n hw.model`, or `system_profiler SPHardwareDataType | grep 'Model Identifier'`,
  to get yours. `fanctl sensors --json` does not carry this — its verified top-level
  fields are `capturedAt`, `keysDeclared`, `keysSkipped`, `provider`, `sensorCount`, and
  `sensors`, none of which is a model identifier — so read it with `sysctl` or
  `system_profiler`, not out of a sensors dump. This is the more specific axis: an entry
  naming your exact model wins over a family-wide guess for the same key.
- **`chipFamily`** — the marketing chip name, e.g. `["M4 Max"]`. On Apple Silicon this is
  `machdep.cpu.brand_string` with the `"Apple "` prefix stripped, so `"Apple M4 Max"`
  becomes `"M4 Max"` — write it exactly that way.

**A note specific to Intel.** No normalised Intel `chipFamily` convention has been
verified against real hardware. `machdep.cpu.brand_string` on Intel is the CPU's own
verbose marketing string (`"Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"`, sometimes with
extra internal spacing), read back verbatim aside from trimming leading and trailing
whitespace. A hand-typed value like `"Intel Core i9-9880H"` — the kind of thing a hardware
report or `system_profiler`'s "Chip or processor" field gives you — will never equal the
raw brand string, and the entry will silently match no Intel Mac at all. **Scope Intel
entries with `modelIdentifier` only**, until someone has actually confirmed the exact
`brand_string` text on real Intel hardware and that convention is written down here.

An entry with no `match` at all applies to every machine, which should be rare — see
`CatalogMatcher`'s documentation in `Sources/FanKit/CatalogMatcher.swift` for exactly how
overlapping entries for the same key are resolved (in short: `modelIdentifier` beats
`chipFamily` beats unrestricted, and a restriction that does not hold on a machine means
the entry does not apply there at all — never as a fallback).

## Confidence: say it plainly

This is the field that matters most, and it asks for one thing: **honesty about how you
know**.

- **`verified`** — you loaded that specific component and watched that specific sensor
  respond, or you have two independent measurements agreeing on the same physical sensor
  closely enough that coincidence is not a plausible explanation. This is a high bar on
  purpose. `Resources/catalog/catalog.json`'s current `verified` entries are exactly this:
  the eight RPM-valued fan keys (`F0Ac`/`F1Ac`, `F0Mn`/`F1Mn`, `F0Mx`/`F1Mx`, `F0Tg`/`F1Tg`
  — semantics confirmed by the values themselves, and by target and actual moving together
  as the machine warmed under load), and `TR0Z` (an `ioft` decode cross-checked
  byte-for-byte against an independent `IOHIDEventSystemClient` reading of the same
  physical sensor, agreeing to three decimal places).
- **`community`** — this is the reported consensus, or it matches what other public
  sources say, but nobody working on this project has independently confirmed it on
  hardware they own. `F0Md`/`F1Md` (the mode keys) sit here: the reported "0 = automatic"
  convention matches what this project reads, but nothing has forced a write and watched
  the fans respond — see `docs/SMC-RESEARCH.md`. `TB0T`/`TB1T`/`TB2T` sit at `guess`
  instead — see below and `docs/SMC-RESEARCH.md`'s "TB0T/TB1T/TB2T versus the real gas
  gauge" section for why a battery meaning was never actually confirmed for them, despite
  an earlier version of this document claiming otherwise.
- **`guess`** — it looks right, based on the key's name, its position near other known
  keys, or a hunch. Still worth recording — a labelled guess is a lead for the next
  person — but it is displayed as a guess, deliberately, so it cannot quietly pass as
  fact.

**A guess marked `guess` is a genuinely useful contribution.** A guess marked `verified`
is how someone ends up building a fan curve on the wrong sensor. If you are unsure which
level applies, pick the lower one.

**Where nothing is known at all, do not add an entry.** An absent entry is the honest
state — the catalog is built so that a sensor with no matching entry still shows,
unlabelled and fully usable (see the rule at the top of this document). Padding the
catalog with guesses to make it look more complete is worse than leaving the gap.

## What counts as a `source`

Anything that lets someone else retrace how you know:

- An issue or pull request number in this repository (`#123`, or the full URL).
- A citation into `docs/SMC-RESEARCH.md`, for anything already recorded there — e.g.
  `"docs/SMC-RESEARCH.md § Fan topology and the Ftst key"`.
- A link to public documentation or research you consulted, honouring its licence — see
  the clean-room rules below before citing anything.
- For a `verified` entry, a short description of what you actually did and observed is
  even better than a bare link: "ran a sustained all-core compile; `Tp09` climbed from 38
  to 71 °C and tracked the efficiency cores in `powermetrics` within about a degree."

`source` is technically optional in the schema, but CI (`catalog-validate.yml`) rejects
any `verified` entry that omits it — a `verified` label with no way to check it is exactly
the failure mode `confidence` exists to prevent.

## Clean-room rule for sources

**Do not take a mapping from decompiled commercial software**, including — but not
limited to — the commercial fan-control tools this project deliberately does not study.
Reading a project's published documentation and reimplementing from the described
behaviour is fine; copying an implementation, or a mapping extracted by decompiling one,
is not. See [CONTRIBUTING.md](../CONTRIBUTING.md)'s clean-room section and
`docs/SMC-RESEARCH.md`'s sources table for how this project cites and licenses what it
does draw on.

## Two ways to contribute

1. **The issue template.** The
   [sensor catalog issue template](../.github/ISSUE_TEMPLATE/sensor-catalog.yml) asks for
   your model identifier, chip, macOS version, the mappings themselves, and — critically —
   how confident you are and what you checked. Somebody turns this into a JSON entry and
   opens the pull request.
2. **A pull request directly against `Resources/catalog/catalog.json`.** Add your
   entries to the `entries` array, in the shape above. No build step is required to do
   this, though running `swift test` locally will exercise the loader against your edit if
   you have a Swift toolchain handy.

Either way, running `fanctl sensors --json --raw-keys` on your Mac and attaching the
output (or the relevant slice of it) is the single most useful thing you can add: it gives
whoever picks this up every key your machine actually exposes, not just the ones you
happened to name.

## How this gets checked

`.github/workflows/catalog-validate.yml` runs on every change under
`Resources/catalog/`, before anything else in CI, so feedback on a small JSON edit does
not wait on a full macOS build. It does two things:

1. Validates `catalog.json` against `catalog.schema.json` — required fields, the
   `key`/`category`/`confidence` value sets, and that a declared `match` actually restricts
   something (an empty `chipFamily`/`modelIdentifier` array, or a blank string inside one,
   is rejected rather than silently read as "applies everywhere").
2. Checks that every `confidence: "verified"` entry cites a non-empty `source` — a rule
   the schema deliberately does not enforce (JSON Schema's `if`/`then` could express a
   "required when some other field has a specific value" condition; this project just
   keeps that check in the CI script instead of the schema).

You can run the same two checks locally with the same `jsonschema` package CI uses
(`pip install "jsonschema>=4.21"`); the workflow file itself is the exact script.

## A personal override, without a pull request

If you would rather keep a mapping to yourself, or you are testing something you are not
ready to publish, `fanctl` reads
`~/Library/Application Support/Aeolus/catalog.json` in the same shape as the bundled file
and layers it on top. (The app does not read either catalog yet — see the note at the top
of this document; this is a `fanctl`-only mechanism until E7 lands.) This is a personal
file, not something this project ships or reviews; the guidance above about confidence and
sources still matters if you plan to open a pull request from it later.

**An override entry replaces a bundled one only when both `key` and `match` are the same**
(see "Scoping: `match`" above and `CatalogLoader.merge`'s documentation in
`Sources/FanKit/CatalogLoader.swift`) — a *different* `match` is additive, not a
replacement, and `CatalogMatcher` ranks `modelIdentifier` above an unrestricted entry
regardless of which file it came from. So an override entry for `TB0T` with no `match` at
all does **not** win over this catalog's `Mac16,5`-scoped `TB0T` entry; the scoped one is
more specific and wins every time, even though it lives in the bundled file. **To actually
override a bundled entry, copy its `match` verbatim** — same `modelIdentifier`/
`chipFamily` values, same shape — so the two are the same slot rather than two entries
competing at different specificity tiers.
