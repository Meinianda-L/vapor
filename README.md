# Vapor

Vapor is a macOS launcher for Windows-only Steam games on Apple Silicon. It runs Steam for Windows in a Wine prefix and gives you a native Mac interface for the store, library, installs and play. The aim is a free alternative to paid Wine wrappers, with better Steam support than general-purpose launchers.

## How it works

- **Headless Steam for Windows.** Vapor starts Steam for Windows in a Wine prefix with no window and signs in there. Steam still handles downloads, DRM and Steamworks.
- **Vapor's own interface.** The store, library, install flow and game properties are drawn by Vapor. Installs go through Steam's own install manager, so Vapor does not reimplement downloads.
- **Direct3D translation per game.** Each game runs on Apple's D3DMetal, DXMT or DXVK over MoltenVK or KosmicKrisp. Vapor picks the layer per game.
- **Frame generation and upscaling.** VaporBoost (`Boost/`) is injected into the game process. It intercepts presentation and adds MetalFX frame interpolation and upscaling.
- **Optional native bridge.** The `Bridge/` component lets Windows games call the Steam client already installed on the Mac, instead of Steam for Windows.

## Status

In development. Verified so far:

- Headless Steam for Windows starts and logs on.
- Games launched through a separate renderer engine connect to that Steam instance.
- Vapor's Steam UI driver installs and uninstalls through Steam's own install flow, with the install dialogs suppressed.
- VaporBoost passes its headless test suite.

Not yet tested end to end: a full game download and play started from the Vapor interface. This status comes from project notes dated 31 October 2026. Update it as work lands.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Rosetta 2. The Direct3D layers and the bridge run as x86_64 code.
- Only one Steam client can be online per account. Quit Steam for macOS before launching Vapor.

## Build

```bash
swift build      # VaporKit, the vapor CLI and VaporApp
swift test       # VaporKit tests
./bundle.sh      # release build of Vapor.app, written to build/
```

VaporBoost and the bridge have their own scripts: `Boost/build.sh` and `Bridge/build.sh`. The headless VaporBoost tests are in `Boost/test/run_tests.sh`.

## Repository layout

| Folder | What it is |
|---|---|
| [`Sources/VaporKit`](Sources/VaporKit) | Engine, Steam, compatibility and runtime logic: Windows Steam in Wine, the Steam UI driver, PE analysis, renderer ladder. |
| [`Sources/VaporApp`](Sources/VaporApp) | The macOS interface. |
| [`Sources/vapor`](Sources/vapor) | The `vapor` command-line tool. |
| [`Shim`](Shim) | Keeps Steam's Wine processes out of the Dock. |
| [`Boost`](Boost) | VaporBoost, a DYLD-injected present hook for frame generation and upscaling, with its test harnesses. |
| [`Bridge`](Bridge) | Optional steamclient bridge: a PE `steamclient64.dll` forwarding into the native macOS Steam client. See [`Bridge/README.md`](Bridge/README.md). |
| [`Tests`](Tests) | VaporKit tests. |

## Notes

Vapor is not affiliated with Valve. Steam is a trademark of Valve Corporation. Use Vapor only with games you own.
