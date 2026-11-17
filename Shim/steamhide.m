// Keeps Windows Steam's own processes out of the Dock and off the screen while Vapor runs it headless.
//
// Wine's Mac driver turns a process into a regular (Dock) app the first time it shows a window
// (-[WineApplicationController transformProcessToForeground:] → -[NSApplication setActivationPolicy:]).
// Loaded into Steam's processes via DYLD_INSERT_LIBRARIES, this swizzles that call so steam.exe,
// steamwebhelper.exe and friends stay accessory apps.
//
// The client's own processes (steam.exe, its helpers, wineboot) also never order a window onto the
// screen or activate: Win32 still sees the window shown, so steam.exe's message boxes and update
// progress keep working, and vapor-winwatch.exe reads and answers them for Vapor. A file named
// .vapor-show-windows in the prefix lets windows through again (Vapor creates it when the user asks
// to see Steam's window). Every other process (games included) is left alone; the checks are on the
// Windows command line, which Wine writes into the process arguments.
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <strings.h>
#import <sys/sysctl.h>
#import <unistd.h>

// The process's arguments as KERN_PROCARGS2 lays them out: argc, exec path, padding, argv…, env….
static char *procArgs(size_t *size) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, getpid()};
    *size = 0;
    if (sysctl(mib, 3, NULL, size, NULL, 0) != 0 || *size <= sizeof(int)) return NULL;
    char *buf = malloc(*size);
    if (buf && sysctl(mib, 3, buf, size, NULL, 0) == 0) return buf;
    free(buf);
    return NULL;
}

static int isSteamProcess(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    size_t size;
    char *buf = procArgs(&size);
    if (!buf) return 0;
    int hit = 0;
    // Scan everything after argc.
    for (size_t i = sizeof(int); i < size; i++) if (buf[i] >= 'A' && buf[i] <= 'Z') buf[i] += 32;
    const char *names[] = {"steam.exe", "steamwebhelper.exe", "steamerrorreporter", "steamservice.exe", "explorer.exe"};
    for (size_t i = sizeof(int); i < size && !hit; i++)
        for (size_t n = 0; n < sizeof names / sizeof *names && !hit; n++)
            if (strncmp(buf + i, names[n], strlen(names[n])) == 0) hit = 1;
    free(buf);
    // Wine rewrites argv after startup; only trust a positive answer once AppKit is in play.
    if (hit) cached = 1;
    return hit;
}

// Stricter than isSteamProcess: only the program itself (argv[0]) counts, so a game whose command line
// mentions steam.exe still shows its windows. VAPOR_HIDE_WINDOWS adds comma-separated names (tests).
// Asked only when a window is ordered, by which time Wine has rewritten argv, so both answers are kept.
static int isClientProcess(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    size_t size;
    char *buf = procArgs(&size);
    if (!buf) return 0;
    char *p = buf + sizeof(int), *end = buf + size;
    p += strnlen(p, end - p);
    while (p < end && !*p) p++;
    char name[128] = "";
    if (p < end) {
        const char *base = p;
        for (const char *q = p; q < end && *q; q++) if (*q == '\\' || *q == '/') base = q + 1;
        size_t n = 0;
        for (; base + n < end && base[n] && n < sizeof name - 1; n++)
            name[n] = (base[n] >= 'A' && base[n] <= 'Z') ? base[n] + 32 : base[n];
        name[n] = 0;
        if (n > 4 && strcmp(name + n - 4, ".exe") == 0) name[n - 4] = 0;
    }
    free(buf);
    int hit = 0;
    const char *names[] = {"steam", "steamwebhelper", "steamservice", "steamerrorreporter", "steamerrorreporter64", "wineboot"};
    for (size_t n = 0; n < sizeof names / sizeof *names && !hit; n++) hit = strcmp(name, names[n]) == 0;
    const char *extra = getenv("VAPOR_HIDE_WINDOWS");
    for (const char *s = extra; s && *s && !hit; s = strchr(s, ',') ? strchr(s, ',') + 1 : NULL) {
        size_t len = strchr(s, ',') ? (size_t)(strchr(s, ',') - s) : strlen(s);
        if (len > 4 && strncasecmp(s + len - 4, ".exe", 4) == 0) len -= 4;
        hit = len > 0 && len == strlen(name) && strncasecmp(s, name, len) == 0;
    }
    cached = hit;
    return hit;
}

static int keepOffScreen(void) {
    if (!isClientProcess()) return 0;
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix) return 1;
    char flag[1024];
    snprintf(flag, sizeof flag, "%s/.vapor-show-windows", prefix);
    return access(flag, F_OK) != 0;
}

static IMP originalSetPolicy;

// NSApplicationActivationPolicy: 0 regular, 1 accessory. No AppKit link, so wineserver and other
// non-GUI processes that inherit the variable never load it.
static BOOL vapor_setActivationPolicy(id self, SEL _cmd, long policy) {
    if (policy == 0 && isSteamProcess()) policy = 1;
    return ((BOOL (*)(id, SEL, long))originalSetPolicy)(self, _cmd, policy);
}

// Window ordering. WineWindow's orderBelow:orAbove:activate: is where the Mac driver shows a window (and
// activates the app); the NSWindow calls behind it are a second line.
static IMP originalOrderBelow, originalOrderFront, originalOrderFrontRegardless, originalMakeKeyAndOrderFront,
    originalOrderWindow, originalDeminiaturize, originalActivate, originalActivateIgnoring;

static void vapor_orderBelow(id self, SEL _cmd, id prev, id next, BOOL activate) {
    if (keepOffScreen()) return;
    ((void (*)(id, SEL, id, id, BOOL))originalOrderBelow)(self, _cmd, prev, next, activate);
}
static void vapor_orderFront(id self, SEL _cmd, id sender) {
    if (!keepOffScreen()) ((void (*)(id, SEL, id))originalOrderFront)(self, _cmd, sender);
}
static void vapor_makeKeyAndOrderFront(id self, SEL _cmd, id sender) {
    if (!keepOffScreen()) ((void (*)(id, SEL, id))originalMakeKeyAndOrderFront)(self, _cmd, sender);
}
static void vapor_deminiaturize(id self, SEL _cmd, id sender) {
    if (!keepOffScreen()) ((void (*)(id, SEL, id))originalDeminiaturize)(self, _cmd, sender);
}
static void vapor_orderFrontRegardless(id self, SEL _cmd) {
    if (!keepOffScreen()) ((void (*)(id, SEL))originalOrderFrontRegardless)(self, _cmd);
}
// NSWindowOrderingMode: 0 is NSWindowOut, which stays allowed.
static void vapor_orderWindow(id self, SEL _cmd, long place, long relativeTo) {
    if (place != 0 && keepOffScreen()) return;
    ((void (*)(id, SEL, long, long))originalOrderWindow)(self, _cmd, place, relativeTo);
}
static void vapor_activateIgnoring(id self, SEL _cmd, BOOL flag) {
    if (!keepOffScreen()) ((void (*)(id, SEL, BOOL))originalActivateIgnoring)(self, _cmd, flag);
}
static void vapor_activate(id self, SEL _cmd) {
    if (!keepOffScreen()) ((void (*)(id, SEL))originalActivate)(self, _cmd);
}

// Replaces `sel` for `cls` only: an inherited method gets an override on `cls` that calls the original.
static void hook(Class cls, const char *name, IMP replacement, IMP *original) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) *original = old;
    else *original = method_setImplementation(m, replacement);
}

static void swizzleIfReady(const struct mach_header *mh, intptr_t slide) {
    Class app = objc_getClass("NSApplication");
    if (app && !originalSetPolicy) {
        Method m = class_getInstanceMethod(app, sel_registerName("setActivationPolicy:"));
        if (m) originalSetPolicy = method_setImplementation(m, (IMP)vapor_setActivationPolicy);
    }
    // The Mac driver (winemac.so) loads after AppKit; it is the image that brings WineWindow.
    Class window = objc_getClass("WineWindow");
    if (!app || !window || originalOrderBelow) return;
    hook(window, "orderBelow:orAbove:activate:", (IMP)vapor_orderBelow, &originalOrderBelow);
    if (!originalOrderBelow) return;
    hook(window, "orderFront:", (IMP)vapor_orderFront, &originalOrderFront);
    hook(window, "orderFrontRegardless", (IMP)vapor_orderFrontRegardless, &originalOrderFrontRegardless);
    hook(window, "makeKeyAndOrderFront:", (IMP)vapor_makeKeyAndOrderFront, &originalMakeKeyAndOrderFront);
    hook(window, "orderWindow:relativeTo:", (IMP)vapor_orderWindow, &originalOrderWindow);
    hook(window, "deminiaturize:", (IMP)vapor_deminiaturize, &originalDeminiaturize);
    hook(app, "activateIgnoringOtherApps:", (IMP)vapor_activateIgnoring, &originalActivateIgnoring);
    hook(app, "activate", (IMP)vapor_activate, &originalActivate);
}

__attribute__((constructor)) static void vapor_steamhide_init(void) {
    _dyld_register_func_for_add_image(swizzleIfReady);
}
