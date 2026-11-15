/* steamclient64.dll — PE half of Vapor's steamclient bridge (Wine builtin).
 *
 * Interface objects returned by the native client are wrapped in proxies. For a
 * known interface version the proxy's vtable is built from generated tables:
 * one typed thunk per Windows slot, which captures the Win64 arguments (floats
 * from XMM registers), maps the MSVC slot to the Itanium slot and calls the
 * native method through a generated SysV shape on the unix side. Unknown
 * interfaces fall back to untyped identity forwarding.
 *
 * Callback and call-result structs are converted between the Win64 (pack 8)
 * and macOS (pack 4) layouts using generated tables.
 */
#include <stdint.h>
#include "../bridge.h"
#define BRIDGE_PE
#include "../generated/bridge_tables.h"
#include "../generated/callbacks.h"

typedef void *HANDLE;
typedef void *HMODULE;
typedef long NTSTATUS;
typedef uint64_t u64;
typedef uint32_t u32;

#define IMPORT __declspec(dllimport)
IMPORT HMODULE GetModuleHandleA(const char *);
IMPORT void *GetProcAddress(HMODULE, const char *);
IMPORT void OutputDebugStringA(const char *);
IMPORT NTSTATUS NtQueryVirtualMemory(HANDLE, const void *, int, void *, u64, u64 *);

extern char __ImageBase;
int _fltused = 0;
void *memset(void *d, int c, unsigned long long n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, unsigned long long n) { unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }
static int str_cmp(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return (unsigned char)*a - (unsigned char)*b; }

static inline u64 f2b(float f) { union { float f; u32 u; } v; v.f = f; return v.u; }
static inline u64 d2b(double d) { union { double d; u64 u; } v; v.d = d; return v.u; }
static inline float b2f(u64 b) { union { float f; u32 u; } v; v.u = (u32)b; return v.f; }
__attribute__((unused)) static inline double b2d(u64 b) { union { double d; u64 u; } v; v.u = b; return v.d; }

typedef NTSTATUS (*unix_call_fn)(u64 handle, unsigned code, void *args);
static unix_call_fn dispatcher;
static u64 unix_handle;
static int init_state;          /* 0 = not tried, 1 = ok, -1 = failed */
#define MemoryWineUnixFuncs 1000

static int bridge_init(void) {
    if (init_state) return init_state > 0;
    init_state = -1;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    void **disp = ntdll ? GetProcAddress(ntdll, "__wine_unix_call_dispatcher") : 0;
    if (!disp || !*disp) { OutputDebugStringA("vapor-steamclient: no __wine_unix_call_dispatcher\n"); return 0; }
    dispatcher = (unix_call_fn)*disp;
    if (NtQueryVirtualMemory((HANDLE)-1, &__ImageBase, MemoryWineUnixFuncs, &unix_handle, sizeof unix_handle, 0)) {
        OutputDebugStringA("vapor-steamclient: unix library not found\n");
        return 0;
    }
    struct bridge_init p;
    memset(&p, 0, sizeof p);
    if (dispatcher(unix_handle, BRIDGE_INIT, &p) || p.status) {
        OutputDebugStringA("vapor-steamclient: native steamclient.dylib failed to load: ");
        OutputDebugStringA(p.error);
        OutputDebugStringA("\n");
        return 0;
    }
    init_state = 1;
    return 1;
}

/* ---- proxies --------------------------------------------------------------------------- */

struct proxy { void **vtbl; u64 native; const struct iface_desc *iface; char name[64]; };

#define MAX_PROXIES 1024
static struct proxy proxies[MAX_PROXIES];
static u32 proxy_count;
static u32 game_sdk;            /* newest SDK among interfaces the game asked for */
extern void *thunk_table[];

static const struct iface_desc *find_iface(const char *name) {
    int lo = 0, hi = IFACE_COUNT - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2, c = str_cmp(name, ifaces[mid].version);
        if (!c) return &ifaces[mid];
        if (c < 0) hi = mid - 1; else lo = mid + 1;
    }
    return 0;
}

static u64 pe_dispatch(struct proxy *s, u32 win_slot, u64 *a, void *retptr);
#include "../generated/pe_thunks.h"

static void *iface_vtables[IFACE_COUNT][PE_MAX_SLOT];

static void **vtable_for(const struct iface_desc *d) {
    void **vt = iface_vtables[d - ifaces];
    if (!vt[0])
        for (u32 i = 0; i < d->count && i < PE_MAX_SLOT; i++) vt[i] = th_tables[d->methods[i].pe_shape][i];
    return vt;
}

/* Same native object -> same proxy, so identity comparisons in games keep working. */
static void *wrap(u64 native, const char *name) {
    if (!native) return 0;
    for (u32 i = 0; i < proxy_count; i++) if (proxies[i].native == native) return &proxies[i];
    if (proxy_count == MAX_PROXIES) return 0;
    struct proxy *p = &proxies[proxy_count++];
    p->native = native;
    for (u32 i = 0; i < 63 && name[i]; i++) p->name[i] = name[i];
    p->iface = name[0] ? find_iface(name) : 0;
    if (p->iface) {
        p->vtbl = vtable_for(p->iface);
        if (p->iface->sdk > game_sdk) game_sdk = p->iface->sdk;
    } else {
        p->vtbl = thunk_table;
        OutputDebugStringA("vapor-steamclient: unknown interface version, using untyped forwarding: ");
        OutputDebugStringA(name[0] ? name : "(unnamed)");
        OutputDebugStringA("\n");
    }
    return p;
}

/* ---- callback / call-result struct conversion ---------------------------------------------- */

static const struct cb_layout *find_layout(int id, int win_size_hint) {
    const struct cb_layout *best = 0;
    for (u32 i = 0; i < CB_LAYOUT_COUNT; i++) {
        const struct cb_layout *l = &cb_layouts[i];
        if (l->id != id) continue;
        if (win_size_hint > 0 && l->win_size == win_size_hint) return l;
        if (!best && (!game_sdk || l->min_sdk <= game_sdk)) best = l;
    }
    return best;
}

static void mac_to_win(const struct cb_layout *l, const unsigned char *mac, unsigned char *win) {
    memset(win, 0, l->win_size);
    for (u32 i = 0; i < l->count; i++) {
        const struct cb_field *f = &cb_fields[l->first + i];
        memcpy(win + f->win_off, mac + f->mac_off, f->size);
    }
}

/* ISteam*Utils::GetAPICallResult(hCall, pCallback, cubCallback, iCallbackExpected, pbFailed) and
 * Steam_GetAPICallResult(pipe, hCall, ...): run with a macOS-sized buffer, convert into the game's. */
static unsigned char result_tmp[8192];

static const struct cb_layout *callresult_layout(int expected, int cub) {
    const struct cb_layout *l = find_layout(expected, cub);
    return (l && l->mac_size <= sizeof result_tmp && l->win_size <= (u32)cub) ? l : 0;
}

/* ---- typed dispatch ------------------------------------------------------------------------- */

static u64 call_typed(struct proxy *s, const struct method_desc *d, u64 *a, void *retptr) {
    struct bridge_typed t;
    memset(&t, 0, sizeof t);
    t.self = s->native;
    t.native_slot = d->native_slot;
    t.mac_shape = d->mac_shape;
    for (int i = 0; i < 16; i++) t.args[i] = a[i];
    t.retptr = (u64)retptr;
    dispatcher(unix_handle, BRIDGE_CALL_TYPED, &t);
    if (t.ret_is_interface) return (u64)wrap(t.ret, t.ret_interface_name);
    return t.ret;
}

static u64 pe_dispatch(struct proxy *s, u32 win_slot, u64 *a, void *retptr) {
    if (!s->iface || win_slot >= s->iface->count) return 0;
    const struct method_desc *d = &s->iface->methods[win_slot];
    if (d->native_slot == 0xFFFF) return 0;

    if (d->flags & METHOD_CALLRESULT) {
        const struct cb_layout *l = callresult_layout((int)a[3], (int)a[2]);
        if (l) {
            void *game_buf = (void *)a[1];
            a[1] = (u64)result_tmp;
            a[2] = l->mac_size;
            u64 ok = call_typed(s, d, a, retptr);
            if (ok & 0xFF) mac_to_win(l, result_tmp, game_buf);
            return ok;
        }
    }
    u64 r = call_typed(s, d, a, retptr);
    /* Hidden-pointer returns whose native shape returns a plain value (CSteamID in RAX). */
    if (retptr) {
        const char *shape = mac_shapes[d->mac_shape];
        const char *colon = shape; while (*colon) colon++;
        while (colon > shape && colon[-1] != ':') colon--;
        if (*colon == 'i') *(u64 *)retptr = r;
    }
    return r;
}

/* ---- untyped fallback (unknown interface versions) -------------------------------------------------- */

static u64 call_method(u32 slot, struct proxy *self, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6, u64 a7) {
    struct bridge_method m;
    memset(&m, 0, sizeof m);
    m.self = self->native; m.slot = slot;
    u64 args[BRIDGE_MAX_ARGS] = { a1, a2, a3, a4, a5, a6, a7 };
    for (int i = 0; i < BRIDGE_MAX_ARGS; i++) m.args[i] = args[i];
    dispatcher(unix_handle, BRIDGE_CALL_METHOD, &m);
    return m.ret_is_interface ? (u64)wrap(m.ret, m.ret_interface_name) : m.ret;
}

#define T(n) static u64 thunk_##n(struct proxy *s, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6, u64 a7) \
    { return call_method(n, s, a1, a2, a3, a4, a5, a6, a7); }
#define T8(b) T(b##0) T(b##1) T(b##2) T(b##3) T(b##4) T(b##5) T(b##6) T(b##7)
#define T64(b) T8(b##0) T8(b##1) T8(b##2) T8(b##3) T8(b##4) T8(b##5) T8(b##6) T8(b##7)
T64(0) T64(1) T64(2) T64(3)
#undef T
#define T(n) (void *)thunk_##n,
void *thunk_table[256] = { T64(0) T64(1) T64(2) T64(3) };

/* ---- C exports ------------------------------------------------------------------------------------- */

static u64 call_export(u32 index, u64 *args) {
    if (!bridge_init()) return 0;
    struct bridge_export e;
    memset(&e, 0, sizeof e);
    e.index = index;
    for (int i = 0; i < 8; i++) e.args[i] = args[i];
    dispatcher(unix_handle, BRIDGE_CALL_EXPORT, &e);
    return e.ret_is_interface ? (u64)wrap(e.ret, e.ret_interface_name) : e.ret;
}

/* CallbackMsg_t has the same offsets on both platforms; only its payload needs converting. */
struct callback_msg { int32_t user; int32_t id; unsigned char *param; int32_t cub; };
static unsigned char callback_buf[65536];

static u64 export_BGetCallback(u64 *args) {
    u64 ok = call_export(EXPORT_Steam_BGetCallback, args);
    struct callback_msg *msg = (struct callback_msg *)args[1];
    if ((ok & 0xFF) && msg && msg->param) {
        const struct cb_layout *l = find_layout(msg->id, 0);
        if (l && msg->cub >= l->mac_size) {
            mac_to_win(l, msg->param, callback_buf);
            msg->param = callback_buf;
            msg->cub = l->win_size;
        }
    }
    return ok;
}

static u64 export_GetAPICallResult(u64 *args) {
    /* (pipe, hCall, pCallback, cubCallback, iCallbackExpected, pbFailed) */
    const struct cb_layout *l = callresult_layout((int)args[4], (int)args[3]);
    if (!l) return call_export(EXPORT_Steam_GetAPICallResult, args);
    void *game_buf = (void *)args[2];
    args[2] = (u64)result_tmp;
    args[3] = l->mac_size;
    u64 ok = call_export(EXPORT_Steam_GetAPICallResult, args);
    if (ok & 0xFF) mac_to_win(l, result_tmp, game_buf);
    return ok;
}

#define DEFINE_EXPORT(name) \
    __declspec(dllexport) u64 name(u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6, u64 a7, u64 a8) { \
        u64 args[8] = { a1, a2, a3, a4, a5, a6, a7, a8 }; \
        if (EXPORT_##name == EXPORT_Steam_BGetCallback) return export_BGetCallback(args); \
        if (EXPORT_##name == EXPORT_Steam_GetAPICallResult) return export_GetAPICallResult(args); \
        return call_export(EXPORT_##name, args); }
BRIDGE_EXPORTS(DEFINE_EXPORT)

int DllMain(void *inst, u32 reason, void *reserved) { (void)inst; (void)reason; (void)reserved; return 1; }
