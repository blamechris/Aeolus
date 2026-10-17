# The supervised fan authority

The reasoning behind two declarations in `SupervisedFanAuthority` — the helper's `FanAuthority`,
where a decoded client message lands — that was written as doc comment in
`Sources/AeolusHelper/SupervisedFanAuthority.swift`, relocated here whole and pointed at from the
declarations it belongs to.

This is a **records** document, of the kind [the handback ledger](handback-ledger.md) and
[the reclamation watchdog](reclamation-watchdog.md) are: it is not a decision record —
[ADR 0014](../ADR/0014-apple-silicon-unlock.md) D5 and its amendments own the decisions — and it is
not normative. Each section below is the text of a doc comment, unchanged apart from the edits any
relocation needs, and names the declaration it came from; that declaration keeps a summary and
cites the section by its heading.

## Why it is a document rather than a doc comment

`SupervisedFanAuthority.swift` stood at 400 lines, SwiftLint's `file_length` warning, when
[#410](https://github.com/blamechris/Aeolus/issues/410)'s item 5 needed it to hold § 5 as a role for
the snapshot's `targetRPM`: one stored property, its initialiser parameter and three lines of the
snapshot. The file may declare no type or extension but the authority itself
(`AuthorityRoleTripwireTests.theAuthorityStoresOnlyItsAllowedProperties`), and its state is
`private`, so no helper could move to a sibling file without widening it. What moved instead is
history: two paragraphs that explain why a declaration has the shape it has, which a reader
changing that declaration needs and a reader of the snapshot does not.

## The capability reporter

*From the type's documentation, where it followed the paragraph on the roles the authority holds.*

**The capability reporter is back, and this time something reads it.** An earlier draft of
this file stored one and documented it as *"why `apply` refuses"*, while `apply`'s own
documentation said the opposite two screens below: the refusal is **not** sourced from the
seam, because there is no control loop here for a capable seam to reach. A stored property
no method read, carrying a doc comment that asserted a gate, was the same defect as the
literal this file replaced, so it was removed as decoration. It returned for § 7, whose
panic verb reads it before the machine-wide restore. `apply` does not read it: level 6 asks
the plane's own, after the lease.

## The teardown gate

*From `controlGate`, E5.4d's teardown gate, closed by `SignalTeardown` before it hands the fans
back.*

**Owned here and exposed, rather than injected**, which is the opposite of the rule
`LeaseAuthority` states about its latch — *"a defaulted latch would compile and
report a bit nothing sets"* — and the difference is worth stating rather than
leaving to be re-derived. That hazard is a *second instance*: two mechanisms each
holding a private latch, one setting a bit the other cannot see. Here there is
exactly one gate, it is the one the refusals below read, and `HelperComposition`
hands *this* instance to the teardown. A constructor parameter would let a caller
build an authority whose gate nothing closes, which is the same defect through the
other door.
