// A libwayland-client.so.0 shadow that sends the zwp_text_input_v3.disable() a
// client forgets to send when the compositor says its text input lost the
// focused surface.
//
// Hyprland activates the input method only on a false -> true edge of the text
// input's enabled state (CTextInputV3::setCommit in src/protocols/TextInputV3.cpp).
// A client that enables on focus and then never disables keeps that state true
// across a focus change, so the compositor never re-activates the input method,
// fcitx5 never re-arms its keyboard grab, and CJK input dies for the window's
// lifetime. That is stencil-hq/tern-sdk#95 (the Wayland half of #2, closed not
// planned), still open on Tern 0.9.5, and the reason modules/packages/tern.nix
// puts this file in Tern's LD_LIBRARY_PATH.
//
// Tern resolves the whole libwayland C API by name after
// dlopen("libwayland-client.so.0"), so a shadow library that LD_LIBRARY_PATH
// finds before the real one is what the process runs: the client's dlopen gets
// this object, and every dlsym on that handle resolves here first. The shadow
// intercepts the two array-form constructors, which is where it learns the text
// input, and the two ways a client can take events (a dispatcher, which Tern
// uses, or a listener array), which is where it learns that the text input left;
// everything else is delegated to the real library, this object's DT_NEEDED.
//
// On the text input's leave event it sends disable + commit, which is exactly
// what the protocol asks a client to do when it no longer has input focus, and
// flushes, so the compositor sees the state leave true before the client's own
// enable on the next enter puts it back — the edge that re-activates fcitx5.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Only the shapes needed to call through; wayland-client.h lives in the real
// library's dev output and would tie this file to a version.
struct wl_proxy;
struct wl_display;
struct wl_message;

struct wl_interface {
    const char *name;
    int version;
    int method_count;
    const void *methods;
    int event_count;
    const void *events;
};

union wl_argument {
    int32_t i;
    uint32_t u;
    int32_t f;
    const char *s;
    void *o;
    uint32_t n;
    void *a;
    int32_t h;
};

typedef struct wl_proxy *(*ctor_ver_fn)(struct wl_proxy *, uint32_t, union wl_argument *, const struct wl_interface *, int);
typedef struct wl_proxy *(*ctor_fn)(struct wl_proxy *, uint32_t, union wl_argument *, const struct wl_interface *);
typedef void (*marshal_array_fn)(struct wl_proxy *, uint32_t, union wl_argument *);
typedef int (*wl_dispatcher_fn)(const void *, void *, uint32_t, const struct wl_message *, union wl_argument *);
typedef int (*add_dispatcher_fn)(struct wl_proxy *, wl_dispatcher_fn, const void *, void *);
typedef int (*add_listener_fn)(struct wl_proxy *, void (**)(void), void *);
typedef struct wl_display *(*proxy_get_display_fn)(struct wl_proxy *);
typedef int (*display_flush_fn)(struct wl_display *);

// zwp_text_input_v3: the two events this shadow cares about, the event count of
// its listener array, and the two requests it sends.
enum { EV_ENTER = 0, EV_LEAVE = 1, EV_COUNT = 6, REQ_DISABLE = 2, REQ_COMMIT = 7 };

#define MAX_TARGETS 4

static FILE *LOG;
static struct wl_proxy *text_inputs[MAX_TARGETS];
static int text_input_count;
static int left;

struct hook {
    struct wl_proxy *proxy;
    wl_dispatcher_fn orig;
    void (**listener)(void);
    void *data;
};

static struct hook hooks[MAX_TARGETS];
static int hook_count;

// The real library comes from DT_NEEDED, which the build points at the store
// path of the same libwayland the client's RUNPATH names; RTLD_NEXT then finds
// it after this object in the search order.
#define REAL(type, var, name)               \
    static type var;                        \
    if (!var) {                             \
        var = (type)dlsym(RTLD_NEXT, name); \
        if (!var)                           \
            abort();                        \
    }

static void logf_(const char *fmt, ...) {
    if (!LOG)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(LOG, fmt, ap);
    va_end(ap);
    fflush(LOG);
}

__attribute__((constructor)) static void shim_init(void) {
    const char *path = getenv("WL_IME_SHIM_LOG");
    if (path && *path)
        LOG = fopen(path, "a");
}

static int is_text_input(struct wl_proxy *proxy) {
    for (int i = 0; i < text_input_count; i++)
        if (text_inputs[i] == proxy)
            return 1;
    return 0;
}

static struct hook *find_hook(struct wl_proxy *proxy) {
    for (int i = 0; i < hook_count; i++)
        if (hooks[i].proxy == proxy)
            return &hooks[i];
    return NULL;
}

// The request the client owes the compositor on leave: disable, committed, and
// pushed out now, so the enabled state is false before the client's next enable
// on the following enter.
static void send_disable(struct wl_proxy *proxy) {
    REAL(marshal_array_fn, marshal_array, "wl_proxy_marshal_array");
    REAL(proxy_get_display_fn, get_display, "wl_proxy_get_display");
    REAL(display_flush_fn, flush, "wl_display_flush");

    union wl_argument args[1];
    memset(args, 0, sizeof(args));
    marshal_array(proxy, REQ_DISABLE, args);
    marshal_array(proxy, REQ_COMMIT, args);

    struct wl_display *display = get_display(proxy);
    if (display)
        flush(display);

    logf_("sent disable+commit on %p\n", (void *)proxy);
}

static void on_event(struct wl_proxy *proxy, uint32_t opcode) {
    if (opcode == EV_LEAVE) {
        if (!left) {
            left = 1;
            send_disable(proxy);
        }
    } else if (opcode == EV_ENTER) {
        left = 0;
    }
}

// The client either installs a dispatcher for the proxy or a listener array;
// both are hooked for the text input alone, and both keep delivering what the
// client asked for.
static int our_dispatcher(const void *impl, void *proxy, uint32_t opcode, const struct wl_message *msg, union wl_argument *args) {
    struct hook *hook = find_hook((struct wl_proxy *)proxy);
    if (!hook)
        return 0;

    on_event((struct wl_proxy *)proxy, opcode);
    return hook->orig(impl, proxy, opcode, msg, args);
}

static void call_listener(struct wl_proxy *proxy, uint32_t opcode, void *surface) {
    struct hook *hook = find_hook(proxy);
    if (!hook || !hook->listener || !hook->listener[opcode])
        return;

    if (opcode == EV_ENTER)
        ((void (*)(void *, void *, void *))hook->listener[opcode])(hook->data, proxy, surface);
    else
        ((void (*)(void *, void *))hook->listener[opcode])(hook->data, proxy);
}

static void our_enter(void *data, void *proxy, void *surface) {
    (void)data;
    on_event((struct wl_proxy *)proxy, EV_ENTER);
    call_listener((struct wl_proxy *)proxy, EV_ENTER, surface);
}

static void our_leave(void *data, void *proxy) {
    (void)data;
    on_event((struct wl_proxy *)proxy, EV_LEAVE);
    call_listener((struct wl_proxy *)proxy, EV_LEAVE, NULL);
}

// The text input is created by zwp_text_input_manager_v3.get_text_input, whose
// constructor call names the interface; the returned proxy is the one to watch.
static void remember(struct wl_proxy *created, const struct wl_interface *iface) {
    if (!created || !iface || strcmp(iface->name, "zwp_text_input_v3") != 0)
        return;

    if (text_input_count < MAX_TARGETS)
        text_inputs[text_input_count++] = created;
    logf_("text input v3 %p\n", (void *)created);
}

struct wl_proxy *wl_proxy_marshal_array_constructor_versioned(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args,
                                                             const struct wl_interface *iface, int version) {
    REAL(ctor_ver_fn, real, "wl_proxy_marshal_array_constructor_versioned");
    struct wl_proxy *created = real(proxy, opcode, args, iface, version);
    remember(created, iface);
    return created;
}

struct wl_proxy *wl_proxy_marshal_array_constructor(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args,
                                                    const struct wl_interface *iface) {
    REAL(ctor_fn, real, "wl_proxy_marshal_array_constructor");
    struct wl_proxy *created = real(proxy, opcode, args, iface);
    remember(created, iface);
    return created;
}

int wl_proxy_add_dispatcher(struct wl_proxy *proxy, wl_dispatcher_fn dispatcher, const void *implementation, void *data) {
    REAL(add_dispatcher_fn, real, "wl_proxy_add_dispatcher");
    if (!is_text_input(proxy) || find_hook(proxy) || hook_count >= MAX_TARGETS)
        return real(proxy, dispatcher, implementation, data);

    hooks[hook_count].proxy = proxy;
    hooks[hook_count].orig  = dispatcher;
    hook_count++;
    logf_("hooked dispatcher on %p\n", (void *)proxy);
    return real(proxy, our_dispatcher, implementation, data);
}

int wl_proxy_add_listener(struct wl_proxy *proxy, void (**implementation)(void), void *data) {
    REAL(add_listener_fn, real, "wl_proxy_add_listener");
    if (!is_text_input(proxy) || !implementation || find_hook(proxy) || hook_count >= MAX_TARGETS)
        return real(proxy, implementation, data);

    void (**copy)(void) = calloc(EV_COUNT, sizeof(void (*)(void)));
    if (!copy)
        return real(proxy, implementation, data);

    memcpy(copy, implementation, EV_COUNT * sizeof(void (*)(void)));
    copy[EV_ENTER] = (void (*)(void))our_enter;
    copy[EV_LEAVE] = (void (*)(void))our_leave;

    hooks[hook_count].proxy    = proxy;
    hooks[hook_count].listener = implementation;
    hooks[hook_count].data     = data;
    hook_count++;
    logf_("hooked listener on %p\n", (void *)proxy);
    return real(proxy, copy, data);
}
