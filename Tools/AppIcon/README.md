# AppIcon

The source of Aeolus's app icon. It is original artwork, drawn in code: a rounded-square
tile with a cool blue-to-teal gradient, and on it a five-bladed fan rotor in near-white with
a slightly darker hub. Nothing is traced, sampled or downloaded, it uses no SF Symbol
(Apple's SF Symbols licence forbids them in app icons), and it borrows nothing from any other
fan-control tool — see the clean-room rules in [CLAUDE.md](../../CLAUDE.md).

Like the other tools in this directory it is a maintainer tool: not part of `Package.swift`,
not built by `project.yml`, never shipped. What ships is the PNGs it produces, committed in
[`Resources/Assets.xcassets/AppIcon.appiconset`](../../Resources/Assets.xcassets/AppIcon.appiconset).

## Regenerating

```sh
Tools/AppIcon/make-appiconset.sh
```

That runs the generator, then derives every size macOS asks for from its 1024 x 1024 master
with `sips`: 16, 32, 128, 256 and 512 points at 1x and 2x, which is 16, 32, 64, 128, 256, 512
and 1024 pixels. `Contents.json` is committed and not rewritten; it only names the files.

To see the master on its own:

```sh
swift Tools/AppIcon/generate-app-icon.swift <outdir>   # writes <outdir>/AppIcon-1024.png
```

The script uses no randomness, clock or environment, so a rerun on the same machine produces
the same bytes. It is not promised to be byte-identical across macOS versions — CoreGraphics
owns the anti-aliasing — so review a regeneration by looking at it, not by diffing PNGs.

## Changing the design

Everything is a named constant at the top of `generate-app-icon.swift` (`Geometry`,
`Palette`) or in `bladeOutline(rotatedBy:)`. After a change, regenerate, then look at the
16 and 32 pixel renders, not just the master: a rotor that is elegant at 1024 and a smear at
16 is the common failure.

The tile follows Apple's macOS icon grid — an 824-point tile centred on the 1024-point canvas,
with the margin left for its shadow — so the icon sits at the same visual size as its
neighbours in the Dock and in Finder.
