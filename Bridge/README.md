# Vapor steamclient bridge

Windows games running under Wine talk to the **native macOS Steam client**. No Windows Steam runs inside the prefix, which avoids the same-account `Session Replaced` conflict.

```
game.exe -> steam_api64.dll (the game's own)
         -> steamclient64.dll   PE, marked "Wine builtin DLL"        (pe/steamclient.c)
         -> __wine_unix_call
         -> steamclient64.so    x86_64 unix lib, same process        (unix/steamclient_unix.c)
         -> steamclient.dylib   macOS Steam's x86_64 slice, SysV ABI
         -> IPC to the running arm64 Steam client
```

`vapor-steamshim.exe` (`shim/steamshim.c`) plays the role of Proton's `steam.exe`:
1. It writes `HKCU\Software\Valve\Steam\ActiveProcess` (`pid`, `ActiveUser`, `SteamClientDll64`).
2. It runs the game and waits for it.
3. It clears `pid` on exit.

## How calls are forwarded

- **Pointers.** PE and unix code share one address space, so pointers pass through unchanged.
- **C exports.** All 38 C exports of steamclient are forwarded by index.
- **Interface objects.** The unix side recognises a returned interface object: its first word points at a vtable in steamclient's data segments, and that vtable's first entry points into steamclient's code. Reads use `mach_vm_read_overwrite`, so probing an integer return value cannot crash.
  - The PE side wraps the object in a proxy whose vtable is 256 generic thunks; slot N forwards to native slot N.
  - The version string it was requested with (e.g. `SteamUser019`) is captured from the call's arguments and stored on the proxy.
- **ABI fixups.** Methods whose Win64 and SysV signatures differ are looked up by (interface prefix, slot). The first entry is `ISteamUser::GetSteamID`:
  - MSVC returns the class through a hidden pointer;
  - Itanium returns the 8-byte CSteamID in RAX.

## Milestone 1 result (2026-10-31)

Setup:
- `steamworks_probe.exe` (headless) with the Portal 2 `steam_api64.dll`;
- Sikarugir Wine 10 + DXMT engine variant with the bridge overlaid, in a dedicated prefix;
- native Steam running, no Windows Steam.

Results:
- `SteamAPI_Init` ok, pipe 1, user 1, universe 1, IP country US, server time ok, `BLoggedOn=1`, clean shutdown.
- SteamID resolved correctly (76561198735163279).
- Native Steam logged `Game process added : AppID 620`, so the native client tracks the Windows game as running.

## Milestone 2: generated bridge (2026-10-31)

`gen/generate.sh <Proton/lsteamclient>` parses all 91 Steamworks SDK versions (Proton's checkout is used only as input data).

**What the generator produces**

- 212 interface versions, 6544 methods.
- Windows (MSVC) vtable order:
  - overloads are grouped and reversed;
  - a virtual destructor takes 1 MSVC slot but 2 Itanium slots.
- Per-method calling shapes:
  - 38 Win64 shapes. Thunks are typed, so floats arrive in XMM registers.
  - 74 SysV shapes, called through libffi. This covers CSteamID in RAX, CGameID passed by reference or returned via sret, by-value structs, and float/double arguments.
- Callback layouts: 224 distinct Win64 pack-8 ↔ macOS pack-4 layouts.

**Validation (`gen/validate.py`) against Proton's generated code**

- Windows vtable order matches for **212/212** interface versions.
- Conversion structs: all **68/68** that Proton converts on 64-bit are flagged.
- 49 more are flagged where only the tail padding differs (e.g. `PersonaStateChange_t`: 16 bytes on Win64, 12 on macOS). The native client needs its own size for call results, so these are converted too.
- `ValvePackingSentinel_t` comes out at 32/24 bytes, which is exactly Valve's own compile-time assert.

**Runtime test** (`test/callback_probe.c`, native Steam only):

- `ISteamUser017::GetSteamID` through the typed hidden-pointer path returns the right SteamID.
- `RequestCurrentStats` delivers `UserStatsReceived_t` (id 1101):
  - converted to the Win64 layout (cub 24);
  - game 620, result OK;
  - SteamID at Win64 offset 16 matches `GetSteamID`. It sits at offset 12 on macOS.

## Remaining limits

- Function pointers handed to the client (`SetWarningMessageHook`) are not wrapped.
- 64-bit only; a 32-bit `steamclient.dll` needs the WoW64 path.

- Callback interfaces passed as objects (`ISteamMatchmakingServerListResponse` and friends) are not wrapped yet.
- Structs nested inside converted structs are copied field-wise at top level only.

## Build and test

```bash
./build.sh
# install into an engine variant + prefix (see the session log for the exact commands)
SteamAppId=620 wine 'C:\windows\system32\vapor-steamshim.exe' <accountid> Z:\path\steamworks_probe.exe Z:\path\steam_api64.dll
```
