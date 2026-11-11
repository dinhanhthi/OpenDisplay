<img src="assets/logo.png" width="128" alt="OpenDisplay logo">

# OpenDisplay
Unlock Flexible HiDPI scaling and manage your screens on macOS. 

OpenDisplay is a small menu bar app. A click on its icon opens one popover: a card for each connected display, the main display first, and a footer. There is no settings window and no Dock icon.

## Features

Each display's card shows the controls that display supports:

- **HiDPI resolutions** (external displays): tick the HiDPI sizes you want from a preset list, then "Apply". "Remove all" takes them away again. See [How HiDPI works](#how-hidpi-works).
- **Resolution** and **Refresh rate** menus. HiDPI sizes are marked "HiDPI" in the Resolution menu.
- **Brightness** slider. It sets the built-in display's own brightness, or an external monitor's backlight over DDC/CI when the monitor answers it. A display with neither is dimmed in software, and its slider is marked "software".
- **Volume** slider. It sets an external monitor's speakers over DDC/CI when the monitor answers it, and the Mac's built-in audio output on the built-in display's card. A display with neither has no volume slider.
- **Rotation** menu (0°, 90°, 180°, 270°) on external displays.
- **Set as main**, on every display that is not the main one.
- **Color profile** menu: the installed display profiles, and "Factory default" to go back to the display's own profile.

The footer has "Launch at login", "About OpenDisplay" (version, author and repository link, shown in place), "Check for Updates…" and "Quit". Updates go through Sparkle; "Check for Updates…" stays disabled in a build without an update key.

## Requirements

- A Mac with Apple silicon.
- macOS 26 or later. Development happened on macOS 27.2 only, on one Mac; nothing was run on macOS 26. Not every control was run on a device there: the first item of [Known limitations](#known-limitations) says which.
- An administrator password, only to add or remove HiDPI sizes.

## How HiDPI works

OpenDisplay adds HiDPI sizes to an external display with a display override file, which macOS reads when the display connects. The sizes come from a preset list: there is no free input.

"The tests" below are tests of such an override file on one monitor and one Mac, made before the app was written.

### What "Apply" does

"Apply" shows the macOS administrator password dialog, with the text "OpenDisplay wants to change the display configuration for (display name)." The command runs through `/usr/bin/osascript`, and OpenDisplay never sees the password. "Cancel" changes nothing.

With the password, two things are written:

1. The override file of the display's model:

   ```
   /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>
   ```

   `<hex>` is the display's vendor id and product id, in lowercase hex without leading zeros. Each ticked size is one 12-byte entry of the file's `scale-resolutions` list: the width and the height of the size, both doubled, then the number 1, each as a big-endian 32-bit number. The file belongs to a display model, so two monitors of the same model share it. If the file already exists, its other keys and entries are kept. A file that OpenDisplay cannot read is left unchanged: the app says so, and "Apply" is disabled.
2. The WindowServer preference `DisplayResolutionEnabled`, set to YES in `/Library/Preferences/com.apple.windowserver`. In the tests, HiDPI sizes appeared only with this preference on.

### One restart, then a reconnect

- The first time, restart the Mac after "Apply". In the tests, the first sizes were looked for only after a restart, and they were there. Whether logging out, or a reconnect alone, is enough was not tested, so the app asks for the restart.
- Once the preference is in effect, new sizes need only a reconnect of the display: unplug its cable and plug it back in. In the tests, sizes added later appeared after a reconnect.

Each applied size says where it stands: "Active", "Restart your Mac to activate", "Reconnect the display to activate" or "Not supported by this display". The app asks for a restart while the preference is off, or when it was written after the last startup. An active size is in the Resolution menu, marked "HiDPI".

### The limit

A HiDPI size cannot exceed the panel's native size. The preset list has only sizes smaller than the native size in both width and height: 90, 80, 75, 70, 62.5, 60 and 50 % of the native size, and common sizes with the panel's aspect ratio.

The real ceiling can be lower. On the test monitor, a 3440x1440 panel, 3010x1260 was the largest size that was tried and accepted, 3440x1440 as a HiDPI size was refused, and nothing in between was tried. OpenDisplay knows the ceiling of that one model only. On another monitor, a size that macOS refuses stays on "Reconnect the display to activate".

### Removing it

From the app: "Remove all" (or "Apply" with nothing ticked) asks for the password again, then:

- deletes the override file when it holds only what OpenDisplay writes (the keys `DisplayVendorID`, `DisplayProductID`, `DisplayProductName` and `scale-resolutions` with the app's own entries). Otherwise the file is written again without the app's sizes, and the rest is kept;
- removes the `DisplayVendorID-<hex>` folder when the file was deleted and the folder is empty;
- when no override file is left under `Overrides`, deletes the `DisplayResolutionEnabled` preference, and the file `/Library/Preferences/com.apple.windowserver.plist` when no other key is left in it.

Then reconnect the display, as after "Apply". If the preference was deleted and you add sizes again later, the app asks for a restart again.

By hand, with the display's ids in place of `<hex>` (the first command lists the files that exist):

```sh
ls -R /Library/Displays/Contents/Resources/Overrides
sudo rm /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>
# Only when no other override file is left:
sudo defaults delete /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled
```

`sudo rm` deletes the whole file, with anything another tool wrote into it. Reconnect the display afterwards.

The override file and the preference are system files. They stay on the Mac when OpenDisplay is deleted, so remove the sizes first.

## Known limitations

- **Not run on a device yet.** Software dimming (including the restore at quit), setting the volume (over DDC/CI and on the built-in audio output), setting the built-in display's brightness, choosing a resolution or a refresh rate from the app's menus, rotating a display from the app, choosing a color profile and the loading of its list when the menu opens, and adding or removing HiDPI resolutions from the app (the override file itself was tested by hand before the app was written, see [How HiDPI works](#how-hidpi-works)). Run on a device and read back so far: an external monitor's brightness over DDC/CI, and "Set as main".
- **Private macOS interfaces.** DDC/CI (private `IOAVService` functions of IOKit), the built-in display's brightness (the private DisplayServices framework) and rotation (the private MonitorPanel framework) are not public API, and the override file's format and the `DisplayResolutionEnabled` preference were found by testing. Any of them may change between macOS versions. The private functions are looked up when the app runs, so a missing one does not stop the launch: the Rotation menu is hidden, brightness falls back to software dimming, and an external monitor has no volume slider.
- **Rotation relies on the private MonitorPanel framework.** The Rotation menu shows only on an external display that this framework can turn.
- **Two identical monitors cannot be told apart for DDC/CI.** A monitor is matched by the vendor, model and serial number it reports. When two monitors report the same three, neither gets DDC/CI: both are dimmed in software and have no volume slider.
- **A monitor that does not answer DDC/CI** is dimmed in software and has no volume slider.
- **Software dimming does not change the backlight.** It darkens the picture through the display's gamma table while OpenDisplay runs; at the slider's lowest position, each color channel stops at 15 % of its range. Quitting the app gives the normal picture back.
- **HiDPI sizes** are for external displays only, come from the preset list only, and belong to a display model, not to one monitor.
- **Sliders do not follow changes made elsewhere** (the monitor's own buttons, the keyboard, System Settings) at once. The values are read again when the popover opens, if the last read is more than 2 seconds old, and when a display is connected, removed or changed.
- **The built-in display's volume slider** sets the Mac's built-in audio output, whatever output is selected in System Settings.

## Build

The project needs Xcode and XcodeGen (the `xcodegen` command).

```sh
xcodegen generate
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug build
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug test
```

- `OpenDisplay.xcodeproj` is generated from `project.yml` and is not in the repository. Change `project.yml`, not the project, and run `xcodegen generate` again after adding or removing a file.
- `-derivedDataPath` is not used: the build goes to Xcode's default DerivedData folder, so Xcode and the command line share one build.
- `test` runs the unit tests of the pure functions in `App/Display/Logic`. It does not launch the app and changes no display.
- The app target is signed with a Developer ID identity set in `project.yml`. To build on another Mac, change `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` there.

## Author

[Anh-Thi DINH](https://github.com/dinhanhthi/OpenDisplay)
