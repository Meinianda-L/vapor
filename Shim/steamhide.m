// Keeps Windows Steam's own processes out of the Dock while Vapor runs it headless.
//
// Wine's Mac driver turns a process into a regular (Dock) app the first time it shows a window
// (-[WineApplicationController transformProcessToForeground:] → -[NSApplication setActivationPolicy:]).
// Loaded into Steam's processes via DYLD_INSERT_LIBRARIES, this swizzles that call so steam.exe,
// steamwebhelper.exe and friends stay accessory apps: windows still work, the Dock icon never appears.
// Every other process (games included) is left alone; the check is on the Windows command line, which
// Wine writes into the process arguments.
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <unistd.h>

static int isSteamProcess(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, getpid()};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    char *buf = malloc(size);
    if (!buf || sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return 0; }
    int hit = 0;
    // Layout: argc, exec path, padding, argv… — scan everything after argc.
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

static IMP originalSetPolicy;

// NSApplicationActivationPolicy: 0 regular, 1 accessory. No AppKit link, so wineserver and other
// non-GUI processes that inherit the variable never load it.
static BOOL vapor_setActivationPolicy(id self, SEL _cmd, long policy) {
    if (policy == 0 && isSteamProcess()) policy = 1;
    return ((BOOL (*)(id, SEL, long))originalSetPolicy)(self, _cmd, policy);
}

static void swizzleIfReady(const struct mach_header *mh, intptr_t slide) {
    if (originalSetPolicy) return;
    Class app = objc_getClass("NSApplication");
    if (!app) return;
    Method m = class_getInstanceMethod(app, sel_registerName("setActivationPolicy:"));
    if (!m) return;
    originalSetPolicy = method_setImplementation(m, (IMP)vapor_setActivationPolicy);
}

__attribute__((constructor)) static void vapor_steamhide_init(void) {
    _dyld_register_func_for_add_image(swizzleIfReady);
}
