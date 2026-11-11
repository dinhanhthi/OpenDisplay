<img src="assets/logo.png" width="128" alt="OpenDisplay logo">

# OpenDisplay
Unlock Flexible HiDPI scaling and manage your screens on macOS.

![OpenDisplay: a display's card in the menu bar popover, with its HiDPI resolutions open](assets/poster.png)

OpenDisplay is a small menu bar app. Click its icon to open one popover with a card for each display. There is no settings window and no Dock icon.

## Download

Get the DMG from the [latest release](https://github.com/dinhanhthi/OpenDisplay/releases/latest). The app updates itself through Sparkle ("Check for Updates…").

Requires a Mac with Apple silicon and macOS 26 or later.

## Features

Each display's card shows the controls that display supports:

- **HiDPI resolutions** for external displays: tick sizes from a preset list, then "Apply" (or "Remove all").
- **Resolution** and **Refresh rate** menus.
- **Brightness**: the built-in display's brightness, or an external monitor's backlight over DDC/CI. Otherwise the picture is dimmed in software.
- **Volume**: an external monitor's speakers over DDC/CI, or the Mac's built-in audio output.
- **Rotation** (0°, 90°, 180°, 270°) for external displays.
- **Set as main** and **Color profile**.

The footer has "Launch at login", "About OpenDisplay", "Check for Updates…" and "Quit".

## How HiDPI works

"Apply" asks for your administrator password (OpenDisplay never sees it), then writes two system files:

- a display override file: `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>`;
- the preference `DisplayResolutionEnabled` in `/Library/Preferences/com.apple.windowserver`.

Restart the Mac after the first "Apply". After that, new sizes only need a reconnect of the display. Each size shows its state: "Active", "Restart your Mac to activate", "Reconnect the display to activate" or "Not supported by this display".

A HiDPI size must be smaller than the panel's native size, and some monitors accept less. The override file belongs to a display model, so two monitors of the same model share it.

These files stay on the Mac when you delete OpenDisplay, so use "Remove all" first. To remove them by hand:

```sh
ls -R /Library/Displays/Contents/Resources/Overrides
sudo rm /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>
# Only when no other override file is left:
sudo defaults delete /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled
```

Then reconnect the display.

## Known limitations

- **Tested on one Mac (macOS 27.2) only.** An external monitor's brightness over DDC/CI and "Set as main" were checked on a device. The other controls, and "Apply" / "Remove all" from the app, were not yet.
- **Private macOS interfaces.** DDC/CI, the built-in display's brightness and rotation use private frameworks that may change with macOS. If one is missing, the control falls back or is hidden.
- **DDC/CI** does not work on a monitor that does not answer it, or on two identical monitors. Such displays are dimmed in software and have no volume slider.
- **Software dimming** does not change the backlight, and stops when you quit the app.
- **Sliders** do not follow changes made elsewhere at once. They update when the popover opens.

## Build

Needs Xcode and XcodeGen.

```sh
xcodegen generate
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug build
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug test
```

The project is generated from `project.yml`. The app is signed with a Developer ID identity; to build on another Mac, change `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `project.yml`. Releases: see [docs/RELEASING.md](docs/RELEASING.md).

## Author

[Anh-Thi DINH](https://github.com/dinhanhthi/OpenDisplay) · MIT License
