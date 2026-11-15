// Headless test for the generated bridge paths (runs under Wine, no window):
//   * typed struct return: ISteamUser017::GetSteamID (MSVC hidden pointer vs SysV RAX)
//   * callback conversion: RequestCurrentStats -> UserStatsReceived_t (id 1101), whose
//     CSteamID sits at offset 16 on Win64 (pack 8) but 12 on macOS (pack 4).
// usage: callback_probe.exe <steam_api64.dll>   (SteamAppId in env)
#include <stdint.h>
typedef void *HANDLE;
typedef void *HMODULE;
typedef unsigned long DWORD;
typedef int BOOL;
typedef uint64_t u64;
#define IMPORT __declspec(dllimport)
IMPORT HANDLE GetStdHandle(DWORD);
IMPORT BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
IMPORT HMODULE LoadLibraryA(const char *);
IMPORT HMODULE GetModuleHandleA(const char *);
IMPORT void *GetProcAddress(HMODULE, const char *);
IMPORT void ExitProcess(unsigned);
IMPORT char *GetCommandLineA(void);
IMPORT void Sleep(DWORD);

int _fltused = 0;
static DWORD slen(const char *s) { DWORD n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { DWORD w; WriteFile(GetStdHandle((DWORD)-11), s, slen(s), &w, 0); }
static void putu(u64 v) { char b[24]; int i = 23; b[i] = 0; do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v); put(b + i); }

static const char *arg1(void) {
    char *c = GetCommandLineA();
    if (*c == '"') { c++; while (*c && *c != '"') c++; if (*c) c++; } else { while (*c && *c != ' ') c++; }
    while (*c == ' ') c++;
    char *e = c;
    if (*c == '"') { c++; e = c; while (*e && *e != '"') e++; } else { while (*e && *e != ' ') e++; }
    *e = 0;
    return c;
}

#define VT(o) (*(void ***)(o))
struct callback_msg { int32_t user; int32_t id; unsigned char *param; int32_t cub; };

void mainCRTStartup(void) {
    HMODULE api = LoadLibraryA(arg1());
    if (!api) { put("[FAIL] LoadLibrary\n"); ExitProcess(10); }
    int (*init)(void) = (int (*)(void))GetProcAddress(api, "SteamAPI_Init");
    void **(*client)(void) = (void **(*)(void))GetProcAddress(api, "SteamClient");
    int (*hUser)(void) = (int (*)(void))GetProcAddress(api, "SteamAPI_GetHSteamUser");
    int (*hPipe)(void) = (int (*)(void))GetProcAddress(api, "SteamAPI_GetHSteamPipe");
    if (!init || !init()) { put("[FAIL] SteamAPI_Init\n"); ExitProcess(2); }
    void **sc = client();
    int user = hUser(), pipe = hPipe();
    put("[ok] SteamAPI_Init pipe="); putu((u64)pipe); put(" user="); putu((u64)user); put("\n");

    // SteamClient017 slot 5 = GetISteamUser; SteamUser017 slot 2 = GetSteamID (hidden return pointer).
    void **su = ((void **(*)(void *, int, int, const char *))VT(sc)[5])(sc, user, pipe, "SteamUser017");
    u64 sid = 0;
    ((u64 *(*)(void *, u64 *))VT(su)[2])(su, &sid);
    put("[ok] GetSteamID (typed, hidden pointer) = "); putu(sid); put("\n");

    // SteamClient017 slot 13 = GetISteamUserStats; UserStats011 slot 0 = RequestCurrentStats.
    void **stats = ((void **(*)(void *, int, int, const char *))VT(sc)[13])(sc, user, pipe, "STEAMUSERSTATS_INTERFACE_VERSION011");
    int requested = ((unsigned char (*)(void *))VT(stats)[0])(stats);
    put("[ok] RequestCurrentStats -> "); putu((u64)requested); put("\n");

    HMODULE scdll = GetModuleHandleA("steamclient64.dll");
    int (*bget)(int, struct callback_msg *) = (int (*)(int, struct callback_msg *))GetProcAddress(scdll, "Steam_BGetCallback");
    int (*bfree)(int) = (int (*)(int))GetProcAddress(scdll, "Steam_FreeLastCallback");
    int got = 0;
    for (int tries = 0; tries < 200 && !got; tries++) {
        struct callback_msg msg = {0};
        while (bget(pipe, &msg)) {
            put("     callback id="); putu((u64)msg.id); put(" cub="); putu((u64)msg.cub); put("\n");
            if (msg.id == 1101) {
                u64 game = *(u64 *)(msg.param + 0);
                int32_t result = *(int32_t *)(msg.param + 8);
                u64 steam = *(u64 *)(msg.param + 16);          // Win64 layout
                put("[ok] UserStatsReceived_t game="); putu(game); put(" result="); putu((u64)result);
                put(" steamid="); putu(steam); put(steam == sid ? "  (matches GetSteamID)\n" : "  (MISMATCH)\n");
                got = 1;
            }
            bfree(pipe);
        }
        Sleep(50);
    }
    if (!got) put("[FAIL] no UserStatsReceived_t within 10s\n");
    ExitProcess(got ? 0 : 3);
}
