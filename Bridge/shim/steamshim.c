/* vapor-steamshim.exe — stands in for steam.exe inside the prefix (the role
 * Proton's steam.exe plays). Publishes the registry keys steam_api reads to
 * find a running client, pointing SteamClientDll64 at Vapor's bridge, then
 * runs the game and waits for it.
 *
 * usage: vapor-steamshim.exe <steam account id> <game command line...>
 */
#include <stdint.h>

typedef void *HANDLE;
typedef void *HKEY;
typedef unsigned long DWORD;
typedef int BOOL;
typedef uint64_t u64;
#define IMPORT __declspec(dllimport)

typedef struct { DWORD cb; char *res, *desktop, *title; DWORD x, y, w, h, cx, cy, fill, flags; unsigned short show, res2; void *res3; HANDLE in, out, err; } STARTUPINFOA;
typedef struct { HANDLE process, thread; DWORD pid, tid; } PROCESS_INFORMATION;

IMPORT char *GetCommandLineA(void);
IMPORT DWORD GetCurrentProcessId(void);
IMPORT BOOL CreateProcessA(const char *, char *, void *, void *, BOOL, DWORD, void *, const char *, STARTUPINFOA *, PROCESS_INFORMATION *);
IMPORT DWORD WaitForSingleObject(HANDLE, DWORD);
IMPORT BOOL GetExitCodeProcess(HANDLE, DWORD *);
IMPORT void ExitProcess(unsigned);
IMPORT HANDLE GetStdHandle(DWORD);
IMPORT BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
IMPORT long RegCreateKeyExA(HKEY, const char *, DWORD, char *, DWORD, DWORD, void *, HKEY *, DWORD *);
IMPORT long RegSetValueExA(HKEY, const char *, DWORD, DWORD, const void *, DWORD);
IMPORT long RegCloseKey(HKEY);

#define HKEY_CURRENT_USER ((HKEY)(uintptr_t)0x80000001)
#define KEY_ALL_ACCESS 0xF003F
#define REG_SZ 1
#define REG_DWORD 4

int _fltused = 0;
void *memset(void *d, int c, unsigned long long n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
static DWORD slen(const char *s) { DWORD n = 0; while (s[n]) n++; return n; }
static void say(const char *s) { DWORD w; WriteFile(GetStdHandle((DWORD)-11), s, slen(s), &w, 0); }

static void set_sz(HKEY k, const char *name, const char *v) { RegSetValueExA(k, name, 0, REG_SZ, v, slen(v) + 1); }
static void set_dw(HKEY k, const char *name, DWORD v) { RegSetValueExA(k, name, 0, REG_DWORD, &v, sizeof v); }

static char *skip_arg(char *p) {
    while (*p == ' ') p++;
    if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
    else while (*p && *p != ' ') p++;
    while (*p == ' ') p++;
    return p;
}

void mainCRTStartup(void) {
    char *cmd = skip_arg(GetCommandLineA());          /* drop our own name */
    DWORD account = 0;
    while (*cmd >= '0' && *cmd <= '9') account = account * 10 + (DWORD)(*cmd++ - '0');
    while (*cmd == ' ') cmd++;
    if (!*cmd) { say("usage: vapor-steamshim.exe <account id> <command line>\n"); ExitProcess(2); }

    HKEY k;
    if (!RegCreateKeyExA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", 0, 0, 0, KEY_ALL_ACCESS, 0, &k, 0)) {
        set_dw(k, "pid", GetCurrentProcessId());
        set_dw(k, "ActiveUser", account);
        set_sz(k, "SteamClientDll64", "C:\\windows\\system32\\steamclient64.dll");
        set_sz(k, "SteamClientDll", "C:\\windows\\syswow64\\steamclient.dll");
        set_sz(k, "Universe", "Public");
        RegCloseKey(k);
    }
    if (!RegCreateKeyExA(HKEY_CURRENT_USER, "Software\\Valve\\Steam", 0, 0, 0, KEY_ALL_ACCESS, 0, &k, 0)) {
        set_sz(k, "SteamPath", "C:\\windows\\system32");
        set_sz(k, "SteamExe", "C:\\windows\\system32\\vapor-steamshim.exe");
        RegCloseKey(k);
    }

    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si); si.cb = sizeof si;
    si.flags = 0x100; /* STARTF_USESTDHANDLES: the game shares our console */
    si.in = GetStdHandle((DWORD)-10); si.out = GetStdHandle((DWORD)-11); si.err = GetStdHandle((DWORD)-12);
    if (!CreateProcessA(0, cmd, 0, 0, 1, 0, 0, 0, &si, &pi)) { say("vapor-steamshim: CreateProcess failed\n"); ExitProcess(3); }
    WaitForSingleObject(pi.process, 0xFFFFFFFF);
    DWORD code = 0;
    GetExitCodeProcess(pi.process, &code);

    /* A client that is gone must not look alive to the next steam_api. */
    if (!RegCreateKeyExA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", 0, 0, 0, KEY_ALL_ACCESS, 0, &k, 0)) {
        set_dw(k, "pid", 0);
        RegCloseKey(k);
    }
    ExitProcess(code);
}
