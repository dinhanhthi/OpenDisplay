# Contributing to OpenDisplay

Issues and pull requests are welcome. Please open an issue first for a larger change.

## Setup

You need a Mac with Apple silicon, macOS 26 or later, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug build
xcodebuild -project OpenDisplay.xcodeproj -scheme OpenDisplay -configuration Debug test
```

- `OpenDisplay.xcodeproj` is generated from `project.yml` and is not committed. Edit `project.yml`, and run `xcodegen generate` again after adding or removing a file.
- Don't pass `-derivedDataPath`: Xcode and the command line then share one build in the default DerivedData folder.
- `test` runs the unit tests of the pure functions in `App/Display/Logic`. It does not launch the app and changes no display.

## Signing

Debug and Release are both signed with a "Developer ID Application" identity, team `86H6CNLN4C`, set in `project.yml`. The app keeps the same identity across rebuilds, so macOS permissions granted to it stay valid. To build on your Mac, set your own `DEVELOPMENT_TEAM` (and `CODE_SIGN_IDENTITY` if you have no Developer ID certificate) in `project.yml`, and don't commit that change.

## Project layout

- `App/`: the app (AppKit entry, SwiftUI popover). `PopoverView.swift`, `DisplayCard.swift`, `HiDPISection.swift` and `FooterView.swift` are the UI.
- `App/Display/`: display access. DDC/CI, brightness, volume, rotation, color profiles, modes, and the HiDPI override installer. `PrivateAPI.swift` looks up the private functions at run time.
- `App/Display/Logic/`: pure functions (HiDPI presets, override file format, DDC packets, mode grouping), with tests in `Tests/OpenDisplayTests/`.
- `scripts/`: the release scripts, see [docs/RELEASING.md](docs/RELEASING.md).
- `tools/`: probes from the first HiDPI tests.

## Be careful with real displays

Some code changes system state, so read it before you run it:

- "Apply" and "Remove all" write system files with your administrator password (see "How HiDPI works" in the README).
- `tools/hidpi-override.sh install|undo`, `list-modes --set` and `rotate-probe` without `--inspect` change a display or system files. They were written for one test setup.
- The Debug flags `--debug-brightness <id>` and `--debug-main <id>` change a real display. `--open-popover` only opens the popover at launch.

## Code style

- Swift 6 with strict concurrency. Keep slow work (DDC/CI, file and system calls) off the main actor.
- A click shows its result in the same frame. If the work takes time, show a loading state, with a spinner that appears only after about 150 ms.
- Private interfaces must fail softly: a missing function hides the control or falls back. It must never stop the launch.
- Add a test in `Tests/OpenDisplayTests/` when you change a function in `App/Display/Logic/`.

## Commits and pull requests

- One-line commit messages: `<type>(<scope>): <summary>`, with type `feat`, `fix`, `docs`, `style`, `refactor`, `test` or `chore`.
- Say in the pull request what you ran on a real device, and on which displays.
- Add user-facing changes under `## [Unreleased]` in `CHANGELOG.md`.

Releases are made by the maintainer, see [docs/RELEASING.md](docs/RELEASING.md).
