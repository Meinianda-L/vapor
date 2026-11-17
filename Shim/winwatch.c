/* vapor-winwatch.exe — reports the native Win32 windows Windows Steam puts up (bootstrapper update
 * progress, message boxes, wineboot's wait window) and presses their buttons for Vapor.
 *
 * Runs in Steam's prefix with Steam's environment so it joins the same wineserver. libvapor-steamhide
 * keeps these windows off the Mac screen; to Windows they are still shown, so they can be read here.
 * Only windows with dialog controls (Static/Button/progress) count: CEF and Steam's helper windows
 * have none.
 *
 * stdout, one JSON object per line:
 *   {"event":"ready"}
 *   {"event":"show","hwnd":N,"pid":N,"process":"steam.exe","class":"#32770","title":"…",
 *    "texts":["…"],"buttons":[{"hwnd":N,"id":N,"label":"…","default":B,"enabled":B}],
 *    "progress":{"pos":N,"min":N,"max":N,"marquee":B}}      (again whenever anything in it changes)
 *   {"event":"gone","hwnd":N}
 * stdin, one command per line:  click <button hwnd>  |  close <window hwnd>
 *
 * usage: vapor-winwatch.exe [--once] [--watch <image name>]...
 *   --once   print the current windows and exit
 *   --watch  also report windows of that process (for tests); Steam's own processes always are
 */
#include <stdint.h>

typedef void *HANDLE;
typedef void *HWND;
typedef unsigned long DWORD;
typedef int BOOL;
typedef unsigned short WCHAR;
typedef intptr_t LPARAM;
typedef uintptr_t WPARAM;
typedef intptr_t LRESULT;
#define IMPORT __declspec(dllimport)
#define WINAPI __stdcall

IMPORT HANDLE WINAPI GetStdHandle(DWORD);
IMPORT BOOL WINAPI WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
IMPORT BOOL WINAPI ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
IMPORT HANDLE WINAPI CreateThread(void *, uintptr_t, DWORD (WINAPI *)(void *), void *, DWORD, DWORD *);
IMPORT void WINAPI ExitProcess(unsigned);
IMPORT HANDLE WINAPI OpenProcess(DWORD, BOOL, DWORD);
IMPORT BOOL WINAPI CloseHandle(HANDLE);
IMPORT BOOL WINAPI QueryFullProcessImageNameW(HANDLE, DWORD, WCHAR *, DWORD *);
IMPORT int WINAPI WideCharToMultiByte(unsigned, DWORD, const WCHAR *, int, char *, int, const char *, BOOL *);
IMPORT WCHAR *WINAPI GetCommandLineW(void);
IMPORT void WINAPI Sleep(DWORD);
IMPORT DWORD WINAPI GetTickCount(void);

IMPORT BOOL WINAPI EnumWindows(BOOL (WINAPI *)(HWND, LPARAM), LPARAM);
IMPORT BOOL WINAPI EnumChildWindows(HWND, BOOL (WINAPI *)(HWND, LPARAM), LPARAM);
IMPORT DWORD WINAPI GetWindowThreadProcessId(HWND, DWORD *);
IMPORT BOOL WINAPI IsWindow(HWND);
IMPORT BOOL WINAPI IsWindowVisible(HWND);
IMPORT BOOL WINAPI IsWindowEnabled(HWND);
IMPORT int WINAPI GetClassNameW(HWND, WCHAR *, int);
IMPORT int WINAPI GetWindowTextW(HWND, WCHAR *, int);
IMPORT long WINAPI GetWindowLongW(HWND, int);
IMPORT int WINAPI GetDlgCtrlID(HWND);
IMPORT HWND WINAPI GetParent(HWND);
IMPORT HWND WINAPI GetAncestor(HWND, unsigned);
IMPORT LRESULT WINAPI SendMessageTimeoutW(HWND, unsigned, WPARAM, LPARAM, unsigned, unsigned, uintptr_t *);
IMPORT BOOL WINAPI PostMessageW(HWND, unsigned, WPARAM, LPARAM);

#define WM_CLOSE 0x0010
#define WM_GETTEXT 0x000D
#define WM_COMMAND 0x0111
#define PBM_GETRANGE 0x0407
#define PBM_GETPOS 0x0408
#define PBS_MARQUEE 0x08
#define GWL_STYLE (-16)
#define SMTO_ABORTIFHUNG 0x2
#define GA_ROOT 2
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000
#define CP_UTF8 65001

int _fltused = 0;
void *memset(void *d, int c, unsigned long long n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, unsigned long long n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

static WCHAR lower(WCHAR c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int wieq(const WCHAR *a, const char *b) {
    while (*a && *b) if (lower(*a++) != (WCHAR)lower((WCHAR)(unsigned char)*b++)) return 0;
    return *a == 0 && *b == 0;
}
static int wweq(const WCHAR *a, const WCHAR *b) {
    while (*a && *b) if (lower(*a++) != lower(*b++)) return 0;
    return *a == 0 && *b == 0;
}

/* ---- output ---- */

typedef struct { char *p; unsigned n, cap; } Buf;
static void put(Buf *b, const char *s) { while (*s && b->n + 1 < b->cap) b->p[b->n++] = *s++; }
static void putn(Buf *b, long long v) {
    char t[24]; int i = 0; unsigned long long u = v < 0 ? (unsigned long long)-v : (unsigned long long)v;
    if (v < 0) put(b, "-");
    do t[i++] = (char)('0' + u % 10); while (u /= 10);
    while (i && b->n + 1 < b->cap) b->p[b->n++] = t[--i];
}
static void putstr(Buf *b, const WCHAR *w) {
    static char u[4096];   /* no stack probes in this freestanding build: keep frames small */
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, u, sizeof u, 0, 0);
    put(b, "\"");
    for (int i = 0; i < len - 1 && b->n + 8 < b->cap; i++) {
        unsigned char c = (unsigned char)u[i];
        if (c == '"' || c == '\\') { b->p[b->n++] = '\\'; b->p[b->n++] = (char)c; }
        else if (c == '\n') put(b, "\\n");
        else if (c == '\r') put(b, "\\r");
        else if (c == '\t') put(b, "\\t");
        else if (c < 0x20) { const char *hex = "0123456789abcdef"; put(b, "\\u00"); b->p[b->n++] = hex[c >> 4]; b->p[b->n++] = hex[c & 15]; }
        else b->p[b->n++] = (char)c;
    }
    put(b, "\"");
}
static void emit(Buf *b) {
    DWORD w;
    b->p[b->n++] = '\n';
    WriteFile(GetStdHandle((DWORD)-11), b->p, b->n, &w, 0);
}

/* ---- which processes ---- */

static const char *steamImages[] = {"steam.exe", "steamwebhelper.exe", "steamservice.exe",
                                    "steamerrorreporter.exe", "steamerrorreporter64.exe", "wineboot.exe"};
static const WCHAR *extraImages[8];
static int extraCount;

static void lookupImage(DWORD pid, WCHAR name[64]) {
    name[0] = 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (!h) return;
    WCHAR path[520]; DWORD len = 520;
    if (QueryFullProcessImageNameW(h, 0, path, &len)) {
        DWORD start = 0, n = 0;
        for (DWORD i = 0; i < len; i++) if (path[i] == '\\' || path[i] == '/') start = i + 1;
        while (start + n < len && n < 63) { name[n] = path[start + n]; n++; }
        name[n] = 0;
    }
    CloseHandle(h);
}

static int watched(const WCHAR *name) {
    for (unsigned i = 0; i < sizeof steamImages / sizeof *steamImages; i++) if (wieq(name, steamImages[i])) return 1;
    for (int i = 0; i < extraCount; i++) if (wweq(name, extraImages[i])) return 1;
    return 0;
}

/* The scanning thread's cache of image names; pids get reused, so it is dropped every few seconds. */
typedef struct { DWORD pid; WCHAR name[64]; } Proc;
static Proc procs[64];
static int procCount;
static DWORD procsAt;

static const WCHAR *imageName(DWORD pid) {
    if (GetTickCount() - procsAt > 5000) { procCount = 0; procsAt = GetTickCount(); }
    for (int i = 0; i < procCount; i++) if (procs[i].pid == pid) return procs[i].name;
    Proc *p = &procs[procCount < 64 ? procCount++ : 63];
    p->pid = pid;
    lookupImage(pid, p->name);
    return p->name;
}

/* Uncached, for the command thread. */
static int belongsToWatched(HWND hwnd) {
    DWORD pid = 0;
    WCHAR name[64];
    GetWindowThreadProcessId(hwnd, &pid);
    if (!pid) return 0;
    lookupImage(pid, name);
    return watched(name);
}

/* ---- reading a window ---- */

typedef struct { Buf *out; int texts, buttons, controls; HWND progress; } Scan;

static void text(HWND hwnd, WCHAR *t, int cap, int viaMessage) {
    t[0] = 0;
    if (viaMessage) {
        uintptr_t r = 0;
        if (!SendMessageTimeoutW(hwnd, WM_GETTEXT, (WPARAM)cap, (LPARAM)t, SMTO_ABORTIFHUNG, 200, &r)) t[0] = 0;
        else t[r < (uintptr_t)cap ? r : (uintptr_t)cap - 1] = 0;
    } else GetWindowTextW(hwnd, t, cap);
}

/* Pass 1 (texts) and pass 2 (buttons) keep each JSON array contiguous. */
static BOOL WINAPI addText(HWND c, LPARAM lp) {
    Scan *s = (Scan *)lp;
    if (!IsWindowVisible(c)) return 1;
    static WCHAR t[2048];
    WCHAR cls[64];
    GetClassNameW(c, cls, 64);
    long style = GetWindowLongW(c, GWL_STYLE);
    int isStatic = wieq(cls, "Static"), isEdit = wieq(cls, "Edit"), isButton = wieq(cls, "Button");
    if (isStatic || isEdit || isButton || wieq(cls, "msctls_progress32")) s->controls++;
    if (!s->progress && wieq(cls, "msctls_progress32")) s->progress = c;
    /* Push buttons are buttons; group boxes and check boxes read as text. */
    int pushButton = isButton && (style & 0xF) <= 1;
    if (!(isStatic || isEdit || (isButton && !pushButton))) return 1;
    if (isStatic && ((style & 0x1F) == 3 || (style & 0x1F) == 0xE)) return 1;   /* SS_ICON, SS_BITMAP */
    text(c, t, 2048, isEdit);
    if (!t[0]) return 1;
    put(s->out, s->texts++ ? "," : "");
    putstr(s->out, t);
    return 1;
}

static BOOL WINAPI addButton(HWND c, LPARAM lp) {
    Scan *s = (Scan *)lp;
    WCHAR cls[64], t[256];
    if (!IsWindowVisible(c) || !GetClassNameW(c, cls, 64) || !wieq(cls, "Button")) return 1;
    long style = GetWindowLongW(c, GWL_STYLE);
    if ((style & 0xF) > 1) return 1;
    text(c, t, 256, 0);
    put(s->out, s->buttons++ ? ",{\"hwnd\":" : "{\"hwnd\":");
    putn(s->out, (long long)(uintptr_t)c);
    put(s->out, ",\"id\":"); putn(s->out, GetDlgCtrlID(c));
    put(s->out, ",\"label\":"); putstr(s->out, t);
    put(s->out, (style & 0xF) == 1 ? ",\"default\":true" : ",\"default\":false");
    put(s->out, IsWindowEnabled(c) ? ",\"enabled\":true}" : ",\"enabled\":false}");
    return 1;
}

/* Writes the window's "show" line into out; returns 0 when it is not a dialog Vapor cares about. */
static int describe(HWND hwnd, Buf *out) {
    WCHAR cls[64], title[512];
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    GetClassNameW(hwnd, cls, 64);
    GetWindowTextW(hwnd, title, 512);
    put(out, "{\"event\":\"show\",\"hwnd\":"); putn(out, (long long)(uintptr_t)hwnd);
    put(out, ",\"pid\":"); putn(out, pid);
    put(out, ",\"process\":"); putstr(out, imageName(pid));
    put(out, ",\"class\":"); putstr(out, cls);
    put(out, ",\"title\":"); putstr(out, title);
    Scan s = {out, 0, 0, 0, 0};
    put(out, ",\"texts\":[");
    EnumChildWindows(hwnd, addText, (LPARAM)&s);
    put(out, "],\"buttons\":[");
    EnumChildWindows(hwnd, addButton, (LPARAM)&s);
    put(out, "]");
    if (s.progress) {
        uintptr_t pos = 0, lo = 0, hi = 0;
        SendMessageTimeoutW(s.progress, PBM_GETPOS, 0, 0, SMTO_ABORTIFHUNG, 200, &pos);
        SendMessageTimeoutW(s.progress, PBM_GETRANGE, 1, 0, SMTO_ABORTIFHUNG, 200, &lo);
        SendMessageTimeoutW(s.progress, PBM_GETRANGE, 0, 0, SMTO_ABORTIFHUNG, 200, &hi);
        put(out, ",\"progress\":{\"pos\":"); putn(out, (int)pos);
        put(out, ",\"min\":"); putn(out, (int)lo);
        put(out, ",\"max\":"); putn(out, (int)hi);
        put(out, GetWindowLongW(s.progress, GWL_STYLE) & PBS_MARQUEE ? ",\"marquee\":true}" : ",\"marquee\":false}");
    }
    put(out, "}");
    return s.controls > 0 || wieq(cls, "#32770") || wieq(cls, "BootstrapUpdateUIClass");
}

/* ---- tracking ---- */

#define MAXWIN 32
typedef struct { HWND hwnd; uint64_t hash; int seen; } Tracked;
static Tracked tracked[MAXWIN];
static int trackedCount;

static uint64_t fnv(const char *p, unsigned n) {
    uint64_t h = 1469598103934665603ull;
    while (n--) { h ^= (unsigned char)*p++; h *= 1099511628211ull; }
    return h;
}

static BOOL WINAPI visit(HWND hwnd, LPARAM lp) {
    (void)lp;
    DWORD pid = 0;
    if (!IsWindowVisible(hwnd) || !GetWindowThreadProcessId(hwnd, &pid) || !watched(imageName(pid))) return 1;
    static char line[65536];
    Buf b = {line, 0, sizeof line - 1};
    if (!describe(hwnd, &b)) return 1;
    uint64_t h = fnv(line, b.n);
    int i = 0;
    while (i < trackedCount && tracked[i].hwnd != hwnd) i++;
    if (i == trackedCount) {
        if (trackedCount == MAXWIN) return 1;
        trackedCount++;
        tracked[i].hwnd = hwnd;
        tracked[i].hash = h + 1;
    }
    tracked[i].seen = 1;
    if (tracked[i].hash != h) { tracked[i].hash = h; emit(&b); }
    return 1;
}

static void scan(void) {
    for (int i = 0; i < trackedCount; i++) tracked[i].seen = 0;
    EnumWindows(visit, 0);
    for (int i = 0; i < trackedCount; i++) {
        if (tracked[i].seen) continue;
        char line[64];
        Buf b = {line, 0, sizeof line - 1};
        put(&b, "{\"event\":\"gone\",\"hwnd\":"); putn(&b, (long long)(uintptr_t)tracked[i].hwnd); put(&b, "}");
        emit(&b);
        tracked[i--] = tracked[--trackedCount];
    }
}

/* ---- commands ---- */

static HWND parseHwnd(const char *p) {
    uintptr_t v = 0;
    while (*p == ' ') p++;
    while (*p >= '0' && *p <= '9') v = v * 10 + (uintptr_t)(*p++ - '0');
    return (HWND)v;
}

static int startsWith(const char *s, const char *prefix) { while (*prefix) if (*s++ != *prefix++) return 0; return 1; }

/* Only windows of watched processes can be pressed or closed. */
static void command(const char *line) {
    if (startsWith(line, "click ")) {
        HWND button = parseHwnd(line + 6), parent = button ? GetParent(button) : 0;
        if (!parent || !IsWindow(button) || !belongsToWatched(GetAncestor(button, GA_ROOT))) return;
        PostMessageW(parent, WM_COMMAND, (WPARAM)(GetDlgCtrlID(button) & 0xFFFF), (LPARAM)button);  /* BN_CLICKED = 0 */
    } else if (startsWith(line, "close ")) {
        HWND hwnd = parseHwnd(line + 6);
        if (hwnd && IsWindow(hwnd) && belongsToWatched(hwnd)) PostMessageW(hwnd, WM_CLOSE, 0, 0);
    }
}

/* Vapor going away closes our stdin; so do we. */
static DWORD WINAPI readCommands(void *unused) {
    (void)unused;
    char buf[512], line[512];
    unsigned n = 0;
    DWORD got;
    while (ReadFile(GetStdHandle((DWORD)-10), buf, sizeof buf, &got, 0) && got) {
        for (DWORD i = 0; i < got; i++) {
            if (buf[i] == '\n' || buf[i] == '\r') { line[n] = 0; if (n) command(line); n = 0; }
            else if (n < sizeof line - 1) line[n++] = buf[i];
        }
    }
    ExitProcess(0);
    return 0;
}

/* ---- arguments ---- */

static WCHAR *nextArg(WCHAR **p) {
    WCHAR *s = *p;
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) { *p = s; return 0; }
    WCHAR *start = s, *out = s;
    int quoted = 0;
    while (*s && (quoted || (*s != ' ' && *s != '\t'))) {
        if (*s == '"') quoted = !quoted; else *out++ = *s;
        s++;
    }
    if (*s) s++;
    *out = 0;
    *p = s;
    return start;
}

void mainCRTStartup(void) {
    WCHAR *cmd = GetCommandLineW(), *arg;
    int once = 0;
    nextArg(&cmd);
    while ((arg = nextArg(&cmd))) {
        if (wieq(arg, "--once")) once = 1;
        else if (wieq(arg, "--watch") && (arg = nextArg(&cmd)) && extraCount < 8) extraImages[extraCount++] = arg;
    }
    if (once) { scan(); ExitProcess(0); }
    char line[32];
    Buf b = {line, 0, sizeof line - 1};
    put(&b, "{\"event\":\"ready\"}");
    emit(&b);
    CreateThread(0, 0, readCommands, 0, 0, 0);
    for (;;) { scan(); Sleep(250); }
}
