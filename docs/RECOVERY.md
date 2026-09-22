# Recovery

**My fans are stuck. What do I do?**

This document assumes something has gone wrong and works from the least disruptive option
to the most. Follow it in order.

> **First, the reassuring part.** Handing the fans back to Apple's thermal management is
> always a safe state, and every option below does exactly that. None of these steps can
> damage your Mac, and none of them lose data.
>
> Also, with one distinction that matters: if the **app** stops — it crashed, you force-quit
> it, it hung — its lease expires within about 30 seconds and the background helper returns
> the fans to automatic on its own. If the **helper itself** stops, nothing is counting that
> lease; what covers it is the helper restarting and handing back whatever it finds, or the
> steps below. A stuck fan usually means Aeolus is still running and holding control — not
> that it has abandoned the fans in a bad state.

---

## 1. Are your fans actually stuck?

Worth checking before anything else. Fans running loud, or running near-silent, may be
correct behaviour:

- Apple's own thermal management runs fans hard under sustained load. Loud is not
  necessarily wrong.
- Recent Apple Silicon laptops run their fans very slowly, or not at all, when idle.
- A fan reading 0 RPM when the machine is cool and idle is normal on many Macs, and is
  measured on this project's own development machine: a `Mac16,5` reads a true 0 RPM on both
  fans through sleep and for about 38 seconds after the lid is reopened, then takes roughly
  four seconds to spin back up. A reading of 0 also says nothing about the minimum speed the
  firmware *declares* — that machine reads 0 while declaring 1350.

If the fan speed responds to load — rises when you compile something, falls when you stop
— it is under automatic control and there is nothing to fix.

## 2. Quit Aeolus

Quitting restores automatic control. That is a guarantee about the helper *attempting* it and
saying which fans it could not put back: the app is not the authority on fan state, and the
helper returns fans to automatic when the app's lease ends. On the current build the helper has
no SMC write path at all, so it can neither have put a fan into manual nor need to take it out.

Quit from the menu bar item, or:

```bash
osascript -e 'tell application "Aeolus" to quit'
```

Wait about 30 seconds and check whether the fans respond to load again.

## 3. Use the panic command

```bash
fanctl reset --all
```

This asks the helper to return every fan to automatic control and drop every lease. It needs
no handshake and no protocol-version match — that exemption is deliberate, so that an older
`fanctl` can still reach a newer helper with it — so it works over SSH, with the app not
running, and when the helper's own state is inconsistent.

> **Read what it prints. It reports what the helper *accepted*, never what your fans are
> doing.** The two are not the same thing, and the command will not claim the second on the
> helper's behalf.

**Exit 0 — "The helper accepted the reset request."** The helper took the request. That is
all it confirmed: the restore is the helper's to finish, and nothing in the reply says a fan
reached an automatic speed.

**On the current build nothing is restored, and that message is still honest.** The helper has
no SMC write path yet, so it answers this message as a no-op — see
[SAFETY.md § 7](SAFETY.md#7-panic-path) for what is still missing. Running it costs nothing and
it becomes the real thing the moment the write path lands; until then, if the fans are wrong,
go to step 5.

**Exit 1 — "The helper did not confirm the reset request."** Followed by the reason, and by
step 5's `bootout` line. The reasons worth knowing in advance:

- *Either the helper is not installed or not yet approved, or it refused this copy of
  `fanctl` because the signature did not match.* These possibilities are named together
  because they cannot be told apart from the client's side: macOS drops a connection whose
  peer fails the code-signing check with nothing delivered, exactly as it does when nothing
  was listening. Check System Settings → Login Items & Extensions first.
- *This build carries no Team ID.* A `fanctl` you built yourself with `swift build` cannot
  verify which process would answer, so it does not connect at all. That is expected, not a
  fault — [#82](https://github.com/blamechris/Aeolus/issues/82) is the signed build. Reads
  (`fanctl list`, `fanctl sensors`) need none of this and keep working.
- *The helper accepted the request and did not answer within 10 seconds.* Nothing can be said
  about whether it took effect; go to step 5.

If `fanctl` is not installed, it ships inside the app bundle:

```bash
/Applications/Aeolus.app/Contents/MacOS/fanctl reset --all
```

There is no per-fan form: `fanctl reset` without `--all` prints usage and exits, because
taking one fan back means holding it under a lease and this build has no write path to grant
one.

## 4. A specific fan says manual control is not available

If `fanctl` or the app reports that a fan cannot be taken under manual control, it names a
*reason* — a short identifier such as `restoreToAutomaticUnconfirmed` — alongside a plain
sentence. Find your reason below by that identifier; the list is exhaustive, so if a reason
isn't here, the identifier is one this document does not yet know, which is itself the
`unrecognised reason` case below.

**`writePathNotBuilt`** — This build of Aeolus has no path to write to the SMC yet, so no
fan can be taken under manual control. This is the answer every fan gives today; there is no
user action that changes it, and it is expected rather than a fault.

**`boundsImplausible`** — This fan's firmware-reported speed bounds did not pass a
plausibility check, so there is no safe range to control it within. There is no user action
that resolves this from a client; it is a property of what the firmware reported for this
fan.

**`reclaimedBySystem`** — The system has taken this fan back from manual control and Aeolus
is not driving it right now. There is no user action; it returns to Aeolus's control if the
system yields the fan again.

**`leaseHeldByAnotherClient`** — Another Aeolus client already holds the manual-control
lease. It becomes available again once that lease ends or is released.

**`selfRenewalNotBuilt`** — A self-renewing (always-alive) lease was requested and this
build does not implement one. Ask for a lease without self-renewal instead.

**`releaseInProgress`** — This fan is mid-handback: a previous lease just ended and the
write that returns it to automatic control has not completed yet. Retry in a moment; this
normally clears in milliseconds.

**`handbackUnconfirmed`** — Aeolus asked for this fan back and stopped waiting for an answer
before one arrived, so it does not yet know what mode the fan is in. The outstanding restore
is still running; retry shortly. A helper restart is not the first action — only reach for it
if this still stands after the machine wakes from sleep.

**`restoreToAutomaticUnconfirmed`** — Aeolus issued a restore-to-automatic write for this fan
and has not yet confirmed the fan is back under automatic control. The write may or may not
have been accepted by the firmware; nothing has read the fan's mode back yet. This ordinarily
clears within one supervisor cycle — retry shortly. If it persists, the fan may be stuck in
manual, another program may have taken it, or the firmware may be refusing the write; go to
step 3 (`fanctl reset --all`) if it does not clear.

**`restoreToAutomaticFailed`** — Aeolus tried to hand this fan back to automatic control and
the firmware never took the write, so Aeolus no longer knows what mode the fan is in. Run
`fanctl reset --all` (step 3) to ask the firmware for this fan again — a write it accepts
lifts the refusal. One it refuses again does not; continue with step 5 if that happens.

**`systemSleeping`** — The machine is going to sleep, or Aeolus believes it is, and every
fan has already been handed back to automatic control for the duration; new leases are
refused until the machine wakes. Retry after waking, not immediately. If it is still refused
after a wake, the helper likely missed the wake notification — go to step 5.

**`noThermalTelemetry`** — Aeolus cannot currently read a critical temperature, so it cannot
safely watch a fan under manual control and refuses new leases entirely. There is nothing to
do from here; it clears when the SMC answers again, and retrying does not speed that up. If
it does not clear, go to step 5.

**`supervisorBlind`** — Aeolus cannot currently read this one fan's own control state, so it
cannot tell whether something else has taken it back, and refuses a new lease over it. This
may clear on its own if the connection recovers; if it does not, go to step 5.

**`foreignManualControl`** — Something other than Aeolus — another fan-control tool, or
firmware that re-asserted manual mode — has put this fan under manual control. Quit or stop
that other program; Aeolus does not fight it for the fan.

**An unrecognised reason** — a short identifier this document has no section for above means
this `fanctl` or app build is older than the helper that answered it. The fan is not
available regardless of what the identifier says; update Aeolus and fanctl to matching
versions. If updating isn't possible yet, treat it exactly like any other refusal above and
continue with step 3.

## 5. Stop the helper

If the command above fails — or on the current build, instead of it — stop the daemon
directly.

**What actually returns the fans, because "its lease supervision cannot outlive the process"
was the wrong mechanism and is corrected here rather than dropped:** the SMC keeps the last
value written to it, so supervision ending is not by itself a restore. `bootout` delivers
`SIGTERM`, and the helper's orderly teardown refuses new control messages, releases every
lease, restores every fan, stops its supervisors, restores every fan once more, and exits. If
the helper dies without that chance, the next start reads every fan's mode and hands back
whatever it finds in manual. **On the current build neither of those writes can land** — there
is no SMC write path yet — so today this step works by the helper no longer being there to
hold anything, which is also why nothing on this build can have left a fan pinned in the first
place.

```bash
sudo launchctl bootout system/com.blamechris.Aeolus.Helper
```

Check it is gone:

```bash
sudo launchctl list | grep -i aeolus
```

## 6. Remove Aeolus entirely

The helper ships inside the app bundle, and its launchd job description points at
`Contents/MacOS/AeolusHelper` inside that bundle rather than at any path elsewhere on
disk. Deleting the app therefore takes the daemon's program with it: there is nothing left
for launchd to start.

The `bootout` line below is not redundant with that. It stops the daemon that is running
*now*, before the bundle it came from disappears, rather than leaving you to trust that
macOS notices.

```bash
osascript -e 'tell application "Aeolus" to quit'
sudo launchctl bootout system/com.blamechris.Aeolus.Helper 2>/dev/null
rm -rf /Applications/Aeolus.app
rm -rf ~/Library/Application\ Support/Aeolus
rm -f ~/Library/Preferences/com.blamechris.Aeolus.plist
```

Restart afterwards. With nothing left running to hold the fans, macOS resumes full
control.

## 7. Reboot

A restart clears any software holding the fans. Firmware resets the Apple Silicon force
key across power cycles anyway, so a reboot alone resolves most stuck states.

## 8. Reset the SMC

Only needed if fans remain wrong **after** a reboot with Aeolus removed. At that point the
cause is almost certainly not Aeolus — but the reset is harmless and rules it out.

### Apple Silicon (M1 and newer)

There is no separate SMC reset. Its function is handled by a full power cycle:

1. Shut down. **Shut down**, not restart.
2. Wait 30 seconds.
3. Power on.

If that does not help, reset NVRAM as well: shut down, then power on and immediately hold
**⌘ + ⌥ + P + R** for about 20 seconds.

### Intel — laptops with the T2 chip (2018 and later)

1. Shut down.
2. Hold **Control (left) + Option (left) + Shift (right)** for 7 seconds.
3. Keeping them held, also hold the **power button** for another 7 seconds.
4. Release everything, wait a few seconds, power on.

### Intel — laptops with a non-removable battery, pre-T2

1. Shut down.
2. Hold **Shift (left) + Control (left) + Option (left) + power button** for 10 seconds.
3. Release, then power on.

### Intel desktops — iMac, Mac mini, Mac Pro, Mac Studio

1. Shut down.
2. Unplug the power cord.
3. Wait 15 seconds.
4. Plug it back in, wait 5 seconds, power on.

---

## Still wrong?

If your fans are misbehaving after all of the above — with Aeolus uninstalled and the SMC
reset — the cause lies elsewhere: another fan utility, a hardware fault, a failing sensor,
or a blocked vent. Apple Diagnostics (hold **D** at power-on) will check the fans and
sensors themselves.

Please still [open an issue](https://github.com/blamechris/Aeolus/issues/new?template=bug.yml)
if Aeolus was involved. Include your model identifier, macOS version, what you had
configured, and which step above finally resolved it. A recovery that needed step 6 when
it should have needed step 2 is a bug in this software, and it is one we want to know
about.
