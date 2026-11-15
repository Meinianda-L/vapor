/* steamclient64.so — unix half of Vapor's steamclient bridge.
 *
 * Loaded by Wine's ntdll for the builtin steamclient64.dll. Runs in the game's
 * (x86_64, Rosetta) process and calls the macOS Steam client's x86_64
 * steamclient.dylib directly with the native SysV ABI.
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ffi/ffi.h>
#include <pthread.h>
#include "../bridge.h"
#include "../generated/bridge_tables.h"

typedef long NTSTATUS;

/* ---- generated native shapes -> libffi call interfaces ------------------------- */

struct shape {
    ffi_cif cif;
    ffi_type *types[20];
    char param[18];          /* token per parameter (after `this`) */
    int nparams;
    char ret;                /* v i f d g s */
    int ret_size;            /* for 's' */
    int sret_first;          /* CGameID return: explicit pointer before `this` */
    int struct_size[18];
};
static struct shape *shapes[MAC_SHAPE_COUNT];
static pthread_mutex_t shape_lock = PTHREAD_MUTEX_INITIALIZER;

static ffi_type *byte_struct(int size) {
    ffi_type *t = calloc(1, sizeof *t);
    ffi_type **el = calloc((size_t)size + 1, sizeof *el);
    for (int i = 0; i < size; i++) el[i] = &ffi_type_uint8;
    t->type = FFI_TYPE_STRUCT;
    t->elements = el;
    return t;
}

static struct shape *get_shape(uint32_t id) {
    if (id >= MAC_SHAPE_COUNT) return NULL;
    if (shapes[id]) return shapes[id];
    pthread_mutex_lock(&shape_lock);
    if (!shapes[id]) {
        struct shape *sh = calloc(1, sizeof *sh);
        const char *p = mac_shapes[id];
        const char *colon = strrchr(p, ':');
        int n = 0;
        while (p < colon) {
            char tok = *p;
            int size = 0;
            if (tok == 's') size = atoi(p + 1);
            sh->param[n] = tok;
            sh->struct_size[n] = size;
            n++;
            while (p < colon && *p != ',') p++;
            if (*p == ',') p++;
        }
        sh->nparams = n;
        sh->ret = colon[1];
        if (sh->ret == 's') sh->ret_size = atoi(colon + 2);
        int k = 0;
        sh->sret_first = sh->ret == 'g';
        if (sh->sret_first) sh->types[k++] = &ffi_type_pointer;
        sh->types[k++] = &ffi_type_pointer;                       /* this */
        for (int i = 0; i < n; i++) {
            switch (sh->param[i]) {
            case 'f': sh->types[k++] = &ffi_type_float; break;
            case 'd': sh->types[k++] = &ffi_type_double; break;
            case 'g': case 'n': sh->types[k++] = &ffi_type_pointer; break;
            case 's': sh->types[k++] = byte_struct(sh->struct_size[i]); break;
            default: sh->types[k++] = &ffi_type_uint64; break;
            }
        }
        ffi_type *rt = &ffi_type_uint64;
        switch (sh->ret) {
        case 'v': case 'g': rt = &ffi_type_void; break;
        case 'f': rt = &ffi_type_float; break;
        case 'd': rt = &ffi_type_double; break;
        case 's': rt = byte_struct(sh->ret_size); break;
        }
        if (ffi_prep_cif(&sh->cif, FFI_DEFAULT_ABI, (unsigned)k, rt, sh->types) != FFI_OK) {
            fprintf(stderr, "[vapor-bridge] ffi_prep_cif failed for shape %u (%s)\n", id, mac_shapes[id]);
            free(sh);
            sh = NULL;
        }
        shapes[id] = sh;
    }
    pthread_mutex_unlock(&shape_lock);
    return shapes[id];
}
typedef uint64_t u64;
typedef u64 (*fn8)(u64, u64, u64, u64, u64, u64, u64, u64);

static void *lib;
static fn8 exports[EXPORT_COUNT];
/* Address ranges of the native client image, used to recognise interface objects. */
static uintptr_t text_lo, text_hi, const_lo[2], const_hi[2];

static const char *export_names[] = {
#define NAME(n) #n,
    BRIDGE_EXPORTS(NAME)
#undef NAME
};

static void find_image_ranges(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "steamclient.dylib")) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        unsigned long size = 0;
        uint8_t *p = getsegmentdata(h, "__TEXT", &size);
        if (p) { text_lo = (uintptr_t)p; text_hi = text_lo + size; }
        const char *segs[2] = { "__DATA_CONST", "__DATA" };
        for (int s = 0; s < 2; s++) {
            p = getsegmentdata(h, segs[s], &size);
            if (p) { const_lo[s] = (uintptr_t)p; const_hi[s] = const_lo[s] + size; }
        }
        return;
    }
}

static int safe_read(uintptr_t addr, u64 *out) {
    mach_vm_size_t got = 0;
    if (addr < 0x1000 || (addr & 7)) return 0;
    return mach_vm_read_overwrite(mach_task_self(), addr, 8, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == 8;
}

static int in_const(uintptr_t a) {
    for (int s = 0; s < 2; s++) if (a >= const_lo[s] && a < const_hi[s]) return 1;
    return 0;
}

/* A native interface object: its first word points at a vtable in the client's
 * data segments, and that vtable's first entry points into the client's code. */
static int is_interface(u64 v) {
    u64 vtbl, fn;
    if (!text_lo || !safe_read(v, &vtbl) || !in_const(vtbl)) return 0;
    return safe_read(vtbl, &fn) && fn >= text_lo && fn < text_hi;
}

/* The version string an interface was requested with ("SteamUser019") is one of
 * the call's arguments; copy it so the PE side knows the proxy's interface. */
static void find_version_string(const u64 *args, int n, char out[64]) {
    out[0] = 0;
    for (int i = 0; i < n; i++) {
        char buf[64];
        mach_vm_size_t got = 0;
        if (args[i] < 0x10000 || mach_vm_read_overwrite(mach_task_self(), args[i], sizeof buf - 1,
                                                       (mach_vm_address_t)buf, &got) != KERN_SUCCESS) continue;
        buf[got] = 0;
        if (strncmp(buf, "Steam", 5) && strncmp(buf, "STEAM", 5)) continue;
        size_t len = strnlen(buf, sizeof buf - 1);
        if (len < 6 || len > 62) continue;
        memcpy(out, buf, len + 1);
        return;
    }
}

static NTSTATUS bridge_init(void *args) {
    struct bridge_init *p = args;
    if (lib) { p->status = 0; return 0; }
    char path[1024];
    if (p->dylib_path[0]) snprintf(path, sizeof path, "%s", p->dylib_path);
    else if (getenv("VAPOR_STEAMCLIENT")) snprintf(path, sizeof path, "%s", getenv("VAPOR_STEAMCLIENT"));
    else snprintf(path, sizeof path, "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                  getenv("HOME") ? getenv("HOME") : "");
    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        p->status = 1;
        snprintf(p->error, sizeof p->error, "%s", dlerror());
        return 0;
    }
    for (int i = 0; i < EXPORT_COUNT; i++) exports[i] = (fn8)dlsym(lib, export_names[i]);
    find_image_ranges();
    p->status = 0;
    if (getenv("VAPOR_BRIDGE_LOG")) fprintf(stderr, "[vapor-bridge] loaded %s\n", path);
    return 0;
}

static NTSTATUS bridge_call_export(void *args) {
    struct bridge_export *e = args;
    if (e->index >= EXPORT_COUNT || !exports[e->index]) { e->ret = 0; return 0; }
    u64 *a = e->args;
    e->ret = exports[e->index](a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    e->ret_is_interface = is_interface(e->ret);
    if (e->ret_is_interface) find_version_string(a, 8, e->ret_interface_name);
    if (getenv("VAPOR_BRIDGE_LOG"))
        fprintf(stderr, "[vapor-bridge] %s(%#llx, %#llx) -> %#llx%s %s\n", export_names[e->index],
                (unsigned long long)a[0], (unsigned long long)a[1], (unsigned long long)e->ret, e->ret_is_interface ? " [iface]" : "",
                e->ret_interface_name);
    return 0;
}

static NTSTATUS bridge_call_method(void *args) {
    struct bridge_method *m = args;
    u64 vtbl = *(u64 *)m->self;
    fn8 f = ((fn8 *)vtbl)[m->slot];
    u64 *a = m->args;
    m->ret = f(m->self, a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    m->ret_is_interface = is_interface(m->ret);
    if (m->ret_is_interface) find_version_string(a, BRIDGE_MAX_ARGS, m->ret_interface_name);
    if (getenv("VAPOR_BRIDGE_LOG"))
        fprintf(stderr, "[vapor-bridge]   %#llx slot %u (%#llx, %#llx) -> %#llx%s %s\n", (unsigned long long)m->self, m->slot,
                (unsigned long long)a[0], (unsigned long long)a[1], (unsigned long long)m->ret, m->ret_is_interface ? " [iface]" : "",
                m->ret_interface_name);
    return 0;
}

static NTSTATUS bridge_call_typed(void *args) {
    struct bridge_typed *t = args;
    struct shape *sh = get_shape(t->mac_shape);
    t->ret = 0;
    t->ret_is_interface = 0;
    if (!sh) return 0;
    void *fn = ((void **)*(u64 *)t->self)[t->native_slot];
    void *values[20];
    u64 self = t->self, retptr = t->retptr;
    u64 gameid_copy[18];
    int k = 0;
    if (sh->sret_first) values[k++] = &retptr;
    values[k++] = &self;
    for (int i = 0; i < sh->nparams; i++) {
        switch (sh->param[i]) {
        case 'g':                                   /* Windows passes CGameID by value; Itanium by reference */
            gameid_copy[i] = t->args[i];
            t->args[i] = (u64)&gameid_copy[i];
            values[k++] = &t->args[i];
            break;
        case 'n':                                   /* Windows callback pointers cannot be called from here */
            t->args[i] = 0;
            values[k++] = &t->args[i];
            break;
        case 's': {                                 /* MSVC: 1/2/4/8-byte structs by value, others by pointer */
            int size = sh->struct_size[i];
            values[k++] = (size == 1 || size == 2 || size == 4 || size == 8) ? (void *)&t->args[i] : (void *)t->args[i];
            break;
        }
        default:
            values[k++] = &t->args[i];              /* f/d values are stored as bit patterns in place */
        }
    }
    unsigned char rbuf[128];
    memset(rbuf, 0, sizeof rbuf);
    ffi_call(&sh->cif, FFI_FN(fn), rbuf, values);
    switch (sh->ret) {
    case 'i': memcpy(&t->ret, rbuf, 8); break;
    case 'f': { uint32_t b; memcpy(&b, rbuf, 4); t->ret = b; break; }
    case 'd': memcpy(&t->ret, rbuf, 8); break;
    case 's': if (t->retptr) memcpy((void *)t->retptr, rbuf, (size_t)sh->ret_size); break;
    default: break;                                 /* v, g (written through retptr) */
    }
    if (sh->ret == 'i') {
        t->ret_is_interface = is_interface(t->ret);
        if (t->ret_is_interface) find_version_string(t->args, sh->nparams, t->ret_interface_name);
    }
    if (getenv("VAPOR_BRIDGE_LOG"))
        fprintf(stderr, "[vapor-bridge]   typed %#llx slot %u shape %s -> %#llx%s %s\n", (unsigned long long)self,
                t->native_slot, mac_shapes[t->mac_shape], (unsigned long long)t->ret,
                t->ret_is_interface ? " [iface]" : "", t->ret_interface_name);
    return 0;
}

typedef NTSTATUS (*unixlib_entry_t)(void *);
__attribute__((visibility("default")))
const unixlib_entry_t __wine_unix_call_funcs[BRIDGE_FUNC_COUNT] = {
    bridge_init,
    bridge_call_export,
    bridge_call_method,
    bridge_call_typed,
};
