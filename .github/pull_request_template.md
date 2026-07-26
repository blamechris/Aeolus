<!--
Thank you for contributing.

Delete any section that does not apply — an honest short PR description beats a
completed template that says nothing.
-->

## What this changes

<!-- What does it do, and why? The why matters more; the diff already shows the what. -->

## Related issues

<!-- e.g. Closes #12, part of #3 -->

## How it was tested

<!--
Say what you actually ran. "swift test passes" is fine for pure logic.

If this touches fan control, say which Mac you tested on — model identifier, chip,
macOS version. If you could not test on hardware, say that too; it is not a problem,
but it changes how the change is reviewed.
-->

## Checklist

- [ ] `swift build && swift test` pass
- [ ] New behaviour has tests, or there is a reason it does not
- [ ] Documentation updated if behaviour or setup changed
- [ ] No AI or agent attribution in commits or in this description

## Does this touch privileged or safety-critical code?

Tick if the change affects `AeolusHelper`, the `SMCCore` write path, the XPC protocol,
entitlements, or any mechanism in [docs/SAFETY.md](../docs/SAFETY.md).

- [ ] **This change touches privileged or safety-critical code**

If ticked, confirm each of these:

- [ ] The safety subsystem (E5) is merged, or this change does not write to the SMC
- [ ] Fan speeds are clamped to firmware bounds on the helper side
- [ ] No path added here can reach 0 RPM
- [ ] No configuration added here can raise a thermal ceiling or disable a safety mechanism
- [ ] Every parameter crossing the XPC boundary is validated as hostile input
- [ ] Nothing reports a fan state the helper has not confirmed
- [ ] `AeolusXPCVersion` is bumped if the protocol changed
- [ ] Safety-relevant behaviour has a test that exercises the failure, not just the happy path

## Hardware claims

- [ ] This PR does **not** claim support for any Mac that has not been verified

<!--
If you are adding to docs/HARDWARE-MATRIX.md, link the issue or report behind the row.
"It should work" is not a basis for changing a row from untested.
-->
