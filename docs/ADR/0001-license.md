# ADR 0001 — Licence: GPL-3.0-or-later

- **Status:** Accepted
- **Date:** 2026-07-25
- **Deciders:** Project maintainer
- **Supersedes:** —

## Context

Aeolus exists because useful fan control on macOS is, in practice, paid software. The
licence has to serve that premise rather than merely be permissive by default.

Three options were on the table:

1. **GPL-3.0-or-later for everything.**
2. **MIT for `SMCCore` and `FanKit`, GPL-3.0 for the app and helper.**
3. **MIT for everything.**

Two facts constrain the choice.

**The prior art is GPL.** The most relevant existing implementation, `smcFanControl`, is
GPL-licensed. SMC key semantics are not obvious and the published open-source projects are
where that knowledge lives. Contributors *will* read them — that is what they are for —
and the risk is not deliberate copying but the ordinary case of reading an implementation
closely enough that it shapes what you write next.

**The whole premise is that this should not be a paid app.** A permissive licence makes
taking the entire codebase, adding a price, and shipping it as a closed product trivial.
That is not hypothetical in this category.

## Decision

**GPL-3.0-or-later for the entire project.**

## Rationale

**Defensively:** GPL means a fork that adds a price tag must ship its source under the
same terms. It does not prevent commercial use, and it is not meant to — it prevents the
specific outcome of this work becoming somebody's closed paid product, which is the exact
thing the project was started in response to.

**Practically:** GPL compatibility removes an entire category of licensing anxiety around
the prior art. A contributor who has read `smcFanControl` carefully is in a straightforward
position rather than an ambiguous one. Under MIT the same contributor is a question mark,
and the project would have to police the boundary rather than simply be compatible with
it. For a single-maintainer project that is a meaningful ongoing cost.

**The disclaimer of warranty matters more than usual here.** This software controls
cooling hardware. GPL-3.0's warranty disclaimer is not the reason for the choice, but it
is not incidental either.

## Alternatives considered

### MIT for `SMCCore` and `FanKit`, GPL for the app and helper

This is the strongest counter-argument and it was close.

`SMCCore` is genuinely reusable: a well-tested, type-registry-driven SMC layer is useful to
any Mac monitoring tool, and MIT would let other projects embed it. Several existing tools
in this space would plausibly adopt it. There is a real community benefit in that.

Rejected for now, on three grounds:

1. **It is the compatibility problem in miniature.** `SMCCore` is precisely the part of
   the codebase where GPL prior art is most likely to have informed the implementation.
   MIT-licensing that specific module is MIT-licensing the module with the least clear
   provenance.
2. **Split licences cost maintenance.** Every file needs the right header, every
   contributor needs to know which side of the line they are on, and every PR that moves
   code between modules is a licensing question. That overhead is paid continuously, by
   one person.
3. **It is a one-way door in the wrong direction.** Relicensing GPL code as MIT later
   requires every contributor's agreement. Relicensing MIT code as GPL is trivial. Since
   `SMCCore` does not exist yet and has no external users, the reversible option is to
   start GPL.

**This decision should be revisited if `SMCCore` matures into something other projects
actually want.** At that point the module could be split into its own repository under
MIT, with contributor agreement, and consumed as a dependency. That is a better version of
this idea than starting with a split licence in one repository, and the door is left open
deliberately.

### MIT for everything

Maximises adoption and embedding, and lowers the barrier for contributors who dislike
copyleft. Rejected because it gives up the anti-repackaging protection that motivated the
project, in exchange for adoption that a niche macOS utility is unlikely to see much of.

The contributor-pool argument also carries less weight than it looks: the binding
constraint on contribution here is Swift plus the Developer ID requirement, not the
licence.

## Consequences

- Every source file carries a GPL-3.0-or-later header. `LICENSE` is the full text.
- Contributions are accepted under the same licence; `CONTRIBUTING.md` says so explicitly.
- Third-party code adapted into the project must be GPL-compatible, attributed in
  `docs/SMC-RESEARCH.md`, and carry its own licence.
- Distribution through the Mac App Store is foreclosed. This costs nothing: the App Store
  does not permit an app that registers a privileged launch daemon in the first place.
- Other tools cannot embed `SMCCore` without also being GPL. Accepted, and revisitable per
  the note above.
