// A small C shim over QuickJS-ng that hides JSValue (passed by value, an
// unstable ABI across the Zig boundary) behind a plain interface, the same
// pattern as the jolt and gpupixel shims. The script runs hardened (no
// clock, no RNG) and fuel-bounded, so it can never hang or vary per run.
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

// QuickJS allocates on the C heap, invisible to the Zig leak gate; a counting
// malloc set makes a leaked runtime or value show as live bytes the vendor
// heap proof reads across a lifecycle. A 16-byte header holds each block's
// size for the free and realloc paths and keeps the payload 16-aligned.
static _Atomic size_t g_qjs_live_bytes = 0;

typedef struct { size_t size; size_t pad; } QjsHeader;

static void *goss_qjs_malloc(void *opaque, size_t size) {
    (void)opaque;
    QjsHeader *h = (QjsHeader *)malloc(size + sizeof(QjsHeader));
    if (!h) return NULL;
    h->size = size;
    atomic_fetch_add(&g_qjs_live_bytes, size);
    return h + 1;
}

static void goss_qjs_free(void *opaque, void *ptr) {
    (void)opaque;
    if (!ptr) return;
    QjsHeader *h = (QjsHeader *)ptr - 1;
    atomic_fetch_sub(&g_qjs_live_bytes, h->size);
    free(h);
}

static void *goss_qjs_realloc(void *opaque, void *ptr, size_t size) {
    (void)opaque;
    if (!ptr) return goss_qjs_malloc(opaque, size);
    if (size == 0) { goss_qjs_free(opaque, ptr); return NULL; }
    QjsHeader *h = (QjsHeader *)ptr - 1;
    size_t old = h->size;
    QjsHeader *n = (QjsHeader *)realloc(h, size + sizeof(QjsHeader));
    if (!n) return NULL;
    n->size = size;
    atomic_fetch_add(&g_qjs_live_bytes, size);
    atomic_fetch_sub(&g_qjs_live_bytes, old);
    return n + 1;
}

static void *goss_qjs_calloc(void *opaque, size_t count, size_t size) {
    if (size != 0 && count > ((size_t)-1) / size) return NULL;
    size_t total = count * size;
    void *p = goss_qjs_malloc(opaque, total);
    if (p) memset(p, 0, total);
    return p;
}

static size_t goss_qjs_usable_size(const void *ptr) {
    if (!ptr) return 0;
    const QjsHeader *h = (const QjsHeader *)ptr - 1;
    return h->size;
}

static const JSMallocFunctions goss_qjs_mf = {
    .js_calloc = goss_qjs_calloc,
    .js_malloc = goss_qjs_malloc,
    .js_free = goss_qjs_free,
    .js_realloc = goss_qjs_realloc,
    .js_malloc_usable_size = goss_qjs_usable_size,
};

// Live bytes on the QuickJS heap right now, read by the vendor-heap proof.
size_t goss_qjs_live_bytes(void) { return atomic_load(&g_qjs_live_bytes); }

// Fuel bounds CPU, not bytes: a hostile script could otherwise allocate
// hundreds of megabytes in one tick. Bytes and native stack get their
// own hard ceilings, generous for any real lens script.
#define GOSS_SCRIPT_MEMORY_LIMIT (32u * 1024u * 1024u)
#define GOSS_SCRIPT_STACK_LIMIT (512u * 1024u)

typedef struct GossScript {
    JSRuntime *rt;
    JSContext *ctx;
    long budget;
    long fuel_per_tick;
    int has_update;
    // The lens object, its signals and params children, and the update
    // function are built once and reused; each tick updates the cached
    // property values in place through cached atoms rather than allocating
    // three objects and re-interning every name every frame.
    JSValue lens;
    JSValue signals;
    JSValue params;
    JSValue update_fn;
    JSAtom *signal_atoms;
    JSAtom *param_atoms;
    int signal_atom_count;
    int param_atom_count;
    int cache_built;
} GossScript;

GossScript *goss_script_new(const char *source, size_t source_len, long fuel_per_tick);
void goss_script_free(GossScript *s);
int goss_script_tick(GossScript *s,
                     const char *const *signal_names, const double *signal_values, int signal_count,
                     const char *const *param_names, double *param_values, int param_count);

// A script failure is drained to stderr so lens authors see the reason;
// leaving it pending would also poison the next call into the context.
static void goss_drain_exception(JSContext *ctx, const char *where) {
    JSValue e = JS_GetException(ctx);
    const char *msg = JS_ToCString(ctx, e);
    fprintf(stderr, "gosslens script %s: %s\n", where, msg ? msg : "unknown exception");
    if (msg) JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, e);
}

// Non-zero return interrupts the running script; the budget is refilled
// before each eval and each tick, so runaway code stops but normal code
// gets a full allowance every frame.
static int goss_on_interrupt(JSRuntime *rt, void *opaque) {
    GossScript *s = (GossScript *)opaque;
    (void)rt;
    if (s->budget <= 0) return 1;
    s->budget--;
    return 0;
}

// Creates a hardened context and evaluates the lens script's top level,
// which is expected to define a global update(lens) function. Returns NULL
// on any failure (bad runtime, syntax error, no update function).
GossScript *goss_script_new(const char *source, size_t source_len, long fuel_per_tick) {
    GossScript *s = (GossScript *)calloc(1, sizeof(GossScript));
    if (!s) return NULL;
    s->rt = JS_NewRuntime2(&goss_qjs_mf, NULL);
    if (!s->rt) { free(s); return NULL; }
    s->ctx = JS_NewContext(s->rt);
    if (!s->ctx) { JS_FreeRuntime(s->rt); free(s); return NULL; }
    s->fuel_per_tick = fuel_per_tick > 0 ? fuel_per_tick : 1000000;
    JS_SetMemoryLimit(s->rt, GOSS_SCRIPT_MEMORY_LIMIT);
    JS_SetMaxStackSize(s->rt, GOSS_SCRIPT_STACK_LIMIT);
    JS_SetInterruptHandler(s->rt, goss_on_interrupt, s);

    s->budget = s->fuel_per_tick;
    const char *harden = "delete globalThis.Date; delete Math.random;";
    JSValue h = JS_Eval(s->ctx, harden, strlen(harden), "<harden>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(h)) goss_drain_exception(s->ctx, "harden");
    JS_FreeValue(s->ctx, h);

    // JS_Eval needs a null-terminated buffer even with an explicit length,
    // and the source slice from the lens is not, so copy it terminated.
    char *buf = (char *)malloc(source_len + 1);
    if (!buf) { goss_script_free(s); return NULL; }
    memcpy(buf, source, source_len);
    buf[source_len] = '\0';
    s->budget = s->fuel_per_tick;
    JSValue v = JS_Eval(s->ctx, buf, source_len, "<lens>", JS_EVAL_TYPE_GLOBAL);
    free(buf);
    int failed = JS_IsException(v);
    if (failed) goss_drain_exception(s->ctx, "eval");
    JS_FreeValue(s->ctx, v);
    if (failed) { goss_script_free(s); return NULL; }

    JSValue global = JS_GetGlobalObject(s->ctx);
    JSValue upd = JS_GetPropertyStr(s->ctx, global, "update");
    s->has_update = JS_IsFunction(s->ctx, upd);
    JS_FreeValue(s->ctx, upd);
    JS_FreeValue(s->ctx, global);
    if (!s->has_update) { goss_script_free(s); return NULL; }
    return s;
}

// Releases the cached tick objects and atoms; safe before the context is
// freed, and a no-op when the cache was never built.
static void goss_free_cache(GossScript *s) {
    if (!s->cache_built) return;
    JSContext *ctx = s->ctx;
    for (int i = 0; i < s->signal_atom_count; i++) JS_FreeAtom(ctx, s->signal_atoms[i]);
    for (int i = 0; i < s->param_atom_count; i++) JS_FreeAtom(ctx, s->param_atoms[i]);
    free(s->signal_atoms);
    free(s->param_atoms);
    s->signal_atoms = NULL;
    s->param_atoms = NULL;
    s->signal_atom_count = 0;
    s->param_atom_count = 0;
    JS_FreeValue(ctx, s->signals);
    JS_FreeValue(ctx, s->params);
    JS_FreeValue(ctx, s->lens);
    JS_FreeValue(ctx, s->update_fn);
    s->cache_built = 0;
}

// Builds the lens/signals/params objects, interns each name to a reusable
// atom, and caches the update function - once per name set, not per tick.
static int goss_build_cache(GossScript *s,
                            const char *const *signal_names, int signal_count,
                            const char *const *param_names, int param_count) {
    JSContext *ctx = s->ctx;
    goss_free_cache(s);
    s->signal_atoms = signal_count > 0 ? (JSAtom *)calloc((size_t)signal_count, sizeof(JSAtom)) : NULL;
    s->param_atoms = param_count > 0 ? (JSAtom *)calloc((size_t)param_count, sizeof(JSAtom)) : NULL;
    if ((signal_count > 0 && !s->signal_atoms) || (param_count > 0 && !s->param_atoms)) {
        free(s->signal_atoms);
        free(s->param_atoms);
        s->signal_atoms = NULL;
        s->param_atoms = NULL;
        return -1;
    }
    s->lens = JS_NewObject(ctx);
    s->signals = JS_NewObject(ctx);
    s->params = JS_NewObject(ctx);
    for (int i = 0; i < signal_count; i++) {
        s->signal_atoms[i] = JS_NewAtom(ctx, signal_names[i]);
        JS_SetProperty(ctx, s->signals, s->signal_atoms[i], JS_NewFloat64(ctx, 0.0));
    }
    for (int i = 0; i < param_count; i++) {
        s->param_atoms[i] = JS_NewAtom(ctx, param_names[i]);
        JS_SetProperty(ctx, s->params, s->param_atoms[i], JS_NewFloat64(ctx, 0.0));
    }
    s->signal_atom_count = signal_count;
    s->param_atom_count = param_count;
    JSValue global = JS_GetGlobalObject(ctx);
    s->update_fn = JS_GetPropertyStr(ctx, global, "update");
    JS_FreeValue(ctx, global);
    s->cache_built = 1;
    return 0;
}

void goss_script_free(GossScript *s) {
    if (!s) return;
    if (s->ctx) goss_free_cache(s);
    if (s->ctx) JS_FreeContext(s->ctx);
    if (s->rt) JS_FreeRuntime(s->rt);
    free(s);
}

// Runs update(lens) once. The host passes the current signals in and the
// current parameter values in/out: the script reads lens.signals.<name>
// and writes lens.params.<name>, and the written values are read back into
// param_values. Returns 0 on success, -1 on an exception or fuel timeout.
int goss_script_tick(GossScript *s,
                     const char *const *signal_names, const double *signal_values, int signal_count,
                     const char *const *param_names, double *param_values, int param_count) {
    if (!s || !s->has_update) return -1;
    JSContext *ctx = s->ctx;
    s->budget = s->fuel_per_tick;

    if (!s->cache_built || s->signal_atom_count != signal_count || s->param_atom_count != param_count) {
        if (goss_build_cache(s, signal_names, signal_count, param_names, param_count) != 0) return -1;
    }

    // Rebind the children each tick so a script that reassigned lens.signals
    // or lens.params sees the engine's own objects again, then write this
    // frame's values in place through the cached atoms.
    JS_SetPropertyStr(ctx, s->lens, "signals", JS_DupValue(ctx, s->signals));
    JS_SetPropertyStr(ctx, s->lens, "params", JS_DupValue(ctx, s->params));
    for (int i = 0; i < signal_count; i++)
        JS_SetProperty(ctx, s->signals, s->signal_atoms[i], JS_NewFloat64(ctx, signal_values[i]));
    for (int i = 0; i < param_count; i++)
        JS_SetProperty(ctx, s->params, s->param_atoms[i], JS_NewFloat64(ctx, param_values[i]));

    JSValue ret = JS_Call(ctx, s->update_fn, JS_UNDEFINED, 1, &s->lens);
    int rc = JS_IsException(ret) ? -1 : 0;
    if (rc != 0) goss_drain_exception(ctx, "update");
    JS_FreeValue(ctx, ret);

    if (rc == 0) {
        JSValue p = JS_GetPropertyStr(ctx, s->lens, "params");
        for (int i = 0; i < param_count; i++) {
            JSValue val = JS_GetProperty(ctx, p, s->param_atoms[i]);
            double d;
            if (JS_ToFloat64(ctx, &d, val) == 0) {
                param_values[i] = d;
            } else {
                goss_drain_exception(ctx, "param readback");
            }
            JS_FreeValue(ctx, val);
        }
        JS_FreeValue(ctx, p);
    }
    return rc;
}
