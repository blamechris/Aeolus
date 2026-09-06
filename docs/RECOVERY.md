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

## 3. Use the panic command — **not available yet**

> **This step does not work on the current build. Go to step 4.** `fanctl reset --all` parses
> and appears in the command tree, but its body exits with
> `Not implemented yet — see epic E10b` and writes nothing. It becomes real when
> [#15](https://github.com/blamechris/Aeolus/issues/15) wires the command to the helper
> message that already exists, and when the epics that build the SMC write path land. The
> step is left here, marked, rather than deleted, so that nobody is sent looking for a
> command this document promised and then quietly withdrew.

When it is available:

```bash
fanctl reset --all
```

This restores every fan to automatic, clears the Apple Silicon force key, and drops all
leases. It works when the app will not launch, when the helper's state is inconsistent,
and over SSH.

If `fanctl` is not installed, it ships inside the app bundle:

```bash
/Applications/Aeolus.app/Contents/MacOS/fanctl reset --all
```

## 4. Stop the helper

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

## 5. Remove Aeolus entirely

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

## 6. Reboot

A restart clears any software holding the fans. Firmware resets the Apple Silicon force
key across power cycles anyway, so a reboot alone resolves most stuck states.

## 7. Reset the SMC

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
configured, and which step above finally resolved it. A recovery that needed step 5 when
it should have needed step 2 is a bug in this software, and it is one we want to know
about.
