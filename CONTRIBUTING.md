# Contributing to Vapor

Thanks for helping. Vapor is a small codebase with a few firm rules; reading this first saves a round of review.

## Getting set up

```bash
swift build && swift test
.build/debug/VaporApp --snapshot /tmp/shots   # renders every screen offscreen; read the PNGs
./bundle.sh && open build/Vapor.app            # the real app
```

Vapor needs a Windows Steam to drive. Either let the app's first-run setup create one, or point `VAPOR_HOME` at a
scratch folder to keep test engines, prefixes and settings away from your real ones.

## Where things live

- `Sources/VaporKit/Engine` — Windows Steam's process (`WindowsSteam`), the Steam UI driver (`SteamUI`, with the
  injected agent in `agentSource`), store services (`SteamUI+Store`), Steam's strings and `steam://` links.
- `Sources/VaporKit/Wine` — Wine engines, graphics packs, downloads, engine variants, prefix setup.
- `Sources/VaporKit/Community` — HTML and JSON parsers for community pages.
- `Sources/VaporApp` — SwiftUI. `EngineModel` is the app's one view of Steam; `RootView` holds navigation, and every
  link goes through `AppState.open(_:)`, which picks a native page.

## Rules

- **Never touch a real account in tests.** No purchases, posts, wishlist or cart changes, sign-outs, game launches or
  installs against a live Steam unless that is the change being tested, and then only by hand.
- **No Steam-drawn UI.** Anything Steam would show in its own window gets a native screen or dialog; if you find a
  window that slips through, that is a bug.
- **Restrained, native UI.** Dark, type-led, macOS controls. No gradients, glows, emoji or decorative icons. Use
  Steam's own wording through `engine.strings("Key")` when a key exists.
- **Slow networks.** Many users reach Steam at 2–6 s per request. Cache, show quiet loading states, bound every wait
  and cancel work when a view goes away.
- **Text is localizable.** Chinese is the source language. Write UI text as `Text("…")` or `String(localized: "…")`,
  then run `Tools/l10n.sh` and add the English in `Resources/Localizable.xcstrings`. `Tools/l10n.sh check` lists what
  is untranslated.
- **No code from GPL projects** such as Heroic; read them for ideas, not for code.

## Sending a change

Keep pull requests focused. Describe what changed and how you checked it: tests, snapshot PNGs, or the game you ran.
For compatibility reports, use the issue template and include the game, renderer and Mac model.
