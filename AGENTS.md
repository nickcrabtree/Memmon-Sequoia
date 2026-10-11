# Memmon-Sequoia: notes for agents

Read in this order: `~/code/AGENT_POLICY.md` (rules, all repos), `~/code/AGENTS.md`
(machines and cross-repo facts), then this file, then `WARP.md`.

`WARP.md` is the full guide to this repo: architecture of `src/main.swift`, build and
deploy steps, how to read the log, the display arrangements on Nick's desk, and known
limitations. Do not duplicate it here; this file holds only what an agent needs to get
oriented quickly and what was learned after `WARP.md` was written.

## Orientation in one minute

- Single Swift source: `src/main.swift` (about 1000 lines). `make` builds `Memmon.app`,
  `make test` runs the self-test (`--self-test`, no Accessibility needed).
- Installed copy: `/Applications/Memmon.app`. Build number = `git rev-list --count HEAD`
  at build time. Deploy procedure, including the Accessibility re-grant that every
  ad-hoc-signed build needs, is in `WARP.md` under "Deploy a new build".
- Log: `~/Library/Logs/Memmon/memmon.log`. Display signatures span several lines;
  `rg -v '^[0-9A-F]{8}-' memmon.log | tail -80` gives one line per event. To see a full
  event with its signature lines, `awk '/<start time>/,/<end time>/' memmon.log`.
- Layouts live in memory only. A restart forgets every layout.
- Killing the running app: `pgrep -fl Memmon.app`, then `kill <that pid>`. Never `pkill`
  or `killall` (global policy).

## How a lid close and reopen plays out (established 2026-10-11)

With external monitors and power connected, closing the lid does not sleep the Mac. It
is a display change only: the laptop display is removed (3 to 2 displays) and later
re-added (2 to 3). `willSleep` and `didWake` never fire; only
`applicationDidChangeScreenParameters` and, on reopen, `screensDidWake`. Expect no "Will
sleep" or "Did wake" lines in the log for this case.

What the log showed for a lid close while the screensaver was running, and a reopen
52 minutes later:

1. Lid close: the 3-display layout was preserved from the 2 s snapshot ("Preserved last
   stable snapshot", apps=6). The 2-display restore 1.6 s later logged
   `AX window mismatch ... ax=0` for every app: while the screensaver or lock screen is
   up, the Accessibility API exposes no windows, although `NSWindow.windowNumbers` still
   lists them. The dirty flag was cleared anyway, so retries 1 to 4 did nothing.
2. Lid open: one restore ran 2 s after `screensDidWake`, with `hasLayout=true` and no
   mismatch lines, almost certainly while the lock screen was still showing. Retries were
   skipped (restore-once design, commits 1157210 and cd48917). Nothing re-applied after
   unlock.
3. 75 s later the deferred auto save stored the un-restored positions as the 3-display
   layout, overwriting the good snapshot from step 1. From then on "Restore Saved Layout"
   reproduces the wrong positions.

Not established: whether the step 2 restore applied frames that macOS then undid, or
whether the set calls failed. The unified log (`log show ... process == "loginwindow"`)
gave no unlock timestamp.

Fixed 2026-10-11: Memmon now
tracks the lock state via the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
distributed notifications (initialised from the CGSession dictionary at launch). An
automatic restore while locked is deferred with the dirty flag left set, the settle save
is postponed, and the unlock handler runs whichever is owed. Every Accessibility set call
now logs its AXError and a read-back of the frame, so the next failure of this kind will
show in the log whether frames were applied, refused, or applied and then moved. Pure
decision logic (`restoreGate`, `unlockFollowUp`) is covered by `make test`. The lid
close and reopen case has not yet been exercised with the new build; the first real one
should be checked in the log for "Restore deferred", "Screen unlocked ... action=restore"
and the per-window "ok" lines.

Second finding, same day, from the first locked lid cycle on the new build: the lock gate worked
(deferred, then restored on unlock, 17 frames applied), but four Terminal windows went to the
wrong place. Their target frames were the good ones shifted by exactly the left monitor's origin
change between arrangements, so the 2 s snapshot preserved at lid close had been taken
mid-transition, after the window server moved Terminal's windows but before NSScreen reported
the display change. Fixed by rejecting any snapshot with a window off every display of its
signature (`windowsOffDisplays`, self-tested). The "set ok but readback=" log form is what
exposed this: the set calls succeeded and macOS clamped the frames to the menu bar.

## Comparison case that worked

On 2026-10-11 at 09:13 a reopen produced a second screen-parameters change 3 s after the
first, which re-dirtied the layout and ran a second restore at 09:13:15. When only one
restore runs, as at 11:21 the same day, the windows stay where macOS put them.
