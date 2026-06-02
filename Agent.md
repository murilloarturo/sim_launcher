# SimLauncher Agent Notes

## Product

SimLauncher is a native macOS menu bar app for quickly launching local Apple simulators and Android emulators. The app should stay compact, fast, and utilitarian.

## Design Direction

- Match the feel of the neighboring `KeepAwake` app: compact, restrained, and obvious.
- Keep the menu bar home UI as a compact window-style panel for consistency with the user's other menu apps.
- Simulator launching should happen through embedded menus: platform, then device category, then device.
- Keep the first screen useful. Do not add marketing screens or explanatory onboarding.
- Prefer native SwiftUI controls and SF Symbols.
- Keep copy short and operational.

## Architecture

- `Sources/SimLauncher/SimLauncher.swift` currently contains the app, services, parsers, and views.
- `SimulatorMenuController` owns menu state and coordinates refresh/launch actions.
- `AppleSimulatorCatalog` parses `xcrun simctl list devices --json` output and filters available Apple simulator categories such as iPhone and iPad.
- `AndroidEmulatorCatalog` parses `emulator -list-avds` output and resolves the emulator binary from `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `~/Library/Android/sdk`.
- `SimulatorService` owns launch behavior for both platforms.
- `scripts/simlauncherctl` is the agent-friendly automation surface for listing and launching devices through the app logic.

## Build and Test

```bash
swift test
./scripts/build_app.sh
```

Use XcodeGen for the app project:

```bash
xcodegen generate
open SimLauncher.xcodeproj
```

## Platform Commands

Agent helper:

```bash
./scripts/simlauncherctl list --json
./scripts/simlauncherctl launch --platform apple --id <UDID>
./scripts/simlauncherctl launch --platform android --id <AVD_NAME>
```

The global Codex skill `$simlauncher-devices` is installed at `/Users/arturo/.codex/skills/simlauncher-devices` and should be used when an agent needs to list or launch local mobile simulators.

Apple simulator discovery:

```bash
xcrun simctl list devices --json
```

Apple simulator launch:

```bash
xcrun simctl boot <UDID>
open -a Simulator
```

Android discovery:

```bash
emulator -list-avds
```

Android launch:

```bash
emulator -avd <AVD_NAME>
```

## Development Rules

- Keep changes small and consistent with the existing SwiftUI style.
- Add parser or service tests when changing discovery behavior.
- Keep `scripts/simlauncherctl` stable because skills and agents rely on it.
- Do not shell out through `/bin/sh` when `Process` can execute the tool directly.
- Keep command errors visible in the menu status text.
- Avoid blocking work that could make the menu feel frozen if discovery or launch logic grows heavier.
- Do not commit generated build output from `.build`, `dist`, or Xcode user data.

## Roadmap Ideas

- Favorites and recent launches
- Search/filter for large simulator lists
- Running Android emulator detection through `adb devices`
- Launch status history or a small diagnostics panel
- Signed and notarized release builds
