# Changelog

All notable changes to OpenDisplay are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

- When the menu bar icon is shown and a new version is available, the icon gets a small green download badge and the popover's "Check for Updates…" button reads "Update to OpenDisplay <version>…" instead of an alert popping up.

## [0.1.0] - 2026-11-11

### Added

Of the controls below, an external monitor's brightness over DDC/CI and "Set as main" were run on a device and read back, and the HiDPI override file was tested by hand before the app was written. The other display controls, and "Apply" and "Remove all" from the app, have not been run on a device yet.

- Menu bar app with one popover and no settings window: a card for each connected display, the main display first.
- Flexible HiDPI sizes for external displays: tick sizes from a preset list and "Apply", or "Remove all". Both go through the macOS administrator password dialog. The app writes a display override file and turns on the WindowServer preference `DisplayResolutionEnabled`, and each size says whether it is active or needs a restart of the Mac or a reconnect of the display.
- Resolution and Refresh rate menus for each display, with HiDPI sizes marked.
- Brightness slider: the built-in display's own brightness, an external monitor's backlight over DDC/CI, or software dimming (marked "software") for a display with neither.
- Volume slider: an external monitor's speakers over DDC/CI, and the Mac's built-in audio output on the built-in display's card.
- Rotation menu (0°, 90°, 180°, 270°) for external displays.
- "Set as main" on every display that is not the main one.
- Color profile menu: the installed display profiles, and "Factory default".
- Footer: "Launch at login", "About OpenDisplay" shown in place, "Check for Updates…" through Sparkle, and "Quit".
