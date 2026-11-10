# HiDPI spike state

Phase 1 spike: does a display override plist add a HiDPI 2560x1080 mode (5120x2160 backing, 100 Hz) to the LG ULTRAWIDE (vendor 0x1e6d, model 0x7826)? This file is tracked so a reboot loses nothing.

- Date: 2026-11-10
- Machine: M4 Pro, macOS 27.2.1
- Target path: `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d/DisplayProductID-7826`
- Variant first installed: A, one 16-byte entry `00001400 00000870 00000001 00200000` with the canary name `LG ULTRAWIDE od-spike`; macOS read the file but REFUSED this entry. The encoding that works is in `## Results` below (12 bytes), and that block is the only one later phases should use
- Undo: `tools/hidpi-override.sh undo`
- Verdict: PASS (variant B: one 12-byte entry `00001400 00000870 00000001`, installed together with the WindowServer preference DisplayResolutionEnabled, effective after a reboot; the tool set 2560x1080 HiDPI at 100 Hz with app scope and reverted)

## User steps

1. Quit BetterDisplay.
2. Run `tools/hidpi-override.sh install` at the repo root (in Claude Code: `! tools/hidpi-override.sh install`) and type the admin password into the system dialog.
3. Unplug the LG's cable, wait 5 seconds, plug it back in.
4. Say "done" in the session, or after a reboot run `/cf-plan-resume 2026-11-10-opendisplay-menubar-app`.

## Check 2026-11-10 12:50:41

```
installed-variant: none
installed-file: absent
BetterDisplay: not running
display id=2 vendor=0x1e6d model=0x7826 builtin=no main=yes rotation=0 native=3440x1440 largest-lodpi=3440x1440 name=LG ULTRAWIDE
added: 0
removed: 0
MISSING
```

awaiting: check after replug #1, variant A

## Check 2026-11-10 13:40:19

```
installed-variant: A
installed-file: identical
BetterDisplay: not running
display id=3 vendor=0x1e6d model=0x7826 builtin=no main=yes rotation=0 native=3440x1440 largest-lodpi=3440x1440 name=LG ULTRAWIDE od-spike
added: 0
removed: 0
MISSING
```

handled: MISSING for #1, variant A (canary name shown after the replug, so the file was read; no mode added or removed)
awaiting: check after reboot #2, variant A

## Check 2026-11-10 15:24:16

```
installed-variant: A
installed-file: identical
BetterDisplay: not running
display id=3 vendor=0x1e6d model=0x7826 builtin=no main=yes rotation=0 native=3440x1440 largest-lodpi=3440x1440 name=LG ULTRAWIDE od-spike
added: 0
removed: 0
MISSING
```

handled: MISSING for #2, variant A (after a reboot: canary name still shown, no mode added or removed; a reboot made no difference)

Note 2026-11-10: variant A (16-byte entry) was read but added no mode, after a replug and after a reboot. From variant B on, "install" also sets the WindowServer preference DisplayResolutionEnabled (it did not exist on this Mac before the spike; "undo" removes it), as the user decided.
awaiting: check after reboot #3, variant B with DisplayResolutionEnabled

## Check 2026-11-10 16:31:52

```
installed-variant: B
installed-file: identical
BetterDisplay: not running
windowserver-pref: 1
display id=3 vendor=0x1e6d model=0x7826 builtin=no main=yes rotation=0 native=3440x1440 largest-lodpi=3440x1440 name=LG ULTRAWIDE od-spike
added: 3
+ 2560x1080 5120x2160 100 HiDPI
+ 2560x1080 5120x2160 50 HiDPI
+ 2560x1080 5120x2160 85 HiDPI
removed: 0
FOUND 2560x1080 (5120x2160 px) @ 100 Hz HiDPI usable=yes
```

handled: FOUND for #3, variant B with DisplayResolutionEnabled (after a reboot: 2560x1080 with a 5120x2160 backing added at 100, 85 and 50 Hz, usable=yes; set OK scope=app, reverted OK)
awaiting: check after replug #1 of task 5, variant D

## Check 2026-11-10 17:42:25

```
installed-variant: D
installed-file: identical
BetterDisplay: not running
windowserver-pref: 1
display id=3 vendor=0x1e6d model=0x7826 builtin=no main=yes rotation=0 native=3440x1440 largest-lodpi=3440x1440 name=LG ULTRAWIDE
added: 12
+ 2150x900 4300x1800 100 HiDPI
+ 2150x900 4300x1800 50 HiDPI
+ 2150x900 4300x1800 85 HiDPI
+ 2560x1080 5120x2160 100 HiDPI
+ 2560x1080 5120x2160 50 HiDPI
+ 2560x1080 5120x2160 85 HiDPI
+ 2580x1080 5160x2160 100 HiDPI
+ 2580x1080 5160x2160 50 HiDPI
+ 2580x1080 5160x2160 85 HiDPI
+ 3010x1260 6020x2520 100 HiDPI
+ 3010x1260 6020x2520 50 HiDPI
+ 3010x1260 6020x2520 85 HiDPI
removed: 0
FOUND 2560x1080 (5120x2160 px) @ 100 Hz HiDPI usable=yes
```

handled: FOUND for #1 of task 5, variant D (after a replug only: four of the five entries became modes at 100, 85 and 50 Hz, all usable; the 6880x2880 entry was refused without dropping the others; the canary name is gone)

## Results

encoding: B, 12 bytes per entry: BE32 backing width, BE32 backing height, 00000001 (backing = 2 x the point size)
extra-keys: none in the plist; outside it, the WindowServer preference DisplayResolutionEnabled = YES in /Library/Preferences/com.apple.windowserver must be on (written as root; absent on this Mac before the spike)
reload: replug once DisplayResolutionEnabled is already in effect (file D showed its modes after a replug); the first time the preference was set, a reboot was done before any mode appeared (variant B was only checked after a reboot, so whether a logout would do is not known)
ceiling: 3010x1260 (6020x2520 backing) is the largest accepted size; a lower bound, since nothing between it and the refused size was tried
accepted: 2150x900, 2560x1080, 2580x1080, 3010x1260
refused: 3440x1440 at 2x (6880x2880 backing); also every entry of variant A (16-byte form, without the preference)
installed-sizes: 2560x1080, 2580x1080, 3010x1260, 2150x900, 3440x1440 (file D; the last one is declared but refused)
target-usable: yes
native-size-source: native-flag (header after file D: native=3440x1440 largest-lodpi=3440x1440, both unchanged from before the override)
2560-vs-2580: no note from the user yet
rotation: mp (MonitorPanel -[MPDisplay setOrientation:], argument type i, value in degrees; the ARZOPA went 0 -> 90 -> 0 and every display header was identical before and after)
