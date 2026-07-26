#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <jsc/jsc.h>
#include <sys/capability.h>
#include <wpe/webkit.h>
#include <wpe/headless/wpe-headless.h>
#include <wpe/wpe-platform.h>
#include <wpe/wayland/wpe-wayland.h>

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#define ENGINEOS_CHATGPT_APPLICATION_ID "com.engineos.ChatGPT"
#define ENGINEOS_CHATGPT_HOME_URI "https://chatgpt.com/"
#define ENGINEOS_CHATGPT_LOGIN_URI "https://chatgpt.com/auth/login"
#define ENGINEOS_CHATGPT_PROBE_URI "https://chatgpt.com/robots.txt"

typedef struct {
    GApplication *application;
    WebKitWebView *web_view;
    WebKitNetworkSession *network_session;
    WebKitWebContext *web_context;
    WPEDisplay *display;
    gboolean probe_web_authn;
    gboolean start_login;
    gboolean probe_started;
    gboolean held;
    guint probe_timeout_id;
    int exit_code;
} EngineOSChatGPT;

static gboolean option_probe_web_authn;
static gboolean option_start_login;
static gboolean option_self_test;
static gboolean option_print_version;

static const GOptionEntry option_entries[] = {
    { "probe-web-authn", 0, G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
        &option_probe_web_authn,
        "Run the PublicKeyCredential capability settlement probe", NULL },
    { "login", 0, G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
        &option_start_login, "Open ChatGPT's dedicated login route", NULL },
    { "self-test", 0, G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
        &option_self_test, "Run the URI policy contract", NULL },
    { "version", 0, G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE,
        &option_print_version, "Print application and WPE WebKit versions", NULL },
    { NULL }
};

static gboolean host_matches_domain(const gchar *host, const gchar *domain)
{
    gsize host_length;
    gsize domain_length;

    if (!host || !domain)
        return FALSE;
    if (g_ascii_strcasecmp(host, domain) == 0)
        return TRUE;

    host_length = strlen(host);
    domain_length = strlen(domain);
    if (host_length <= domain_length || host[host_length - domain_length - 1] != '.')
        return FALSE;
    return g_ascii_strcasecmp(host + host_length - domain_length, domain) == 0;
}

static gboolean uri_is_allowed(const gchar *uri)
{
    static const gchar *const domains[] = {
        "chatgpt.com",
        "openai.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "google.com",
        "googleapis.com",
        "googleusercontent.com",
        "gstatic.com",
        NULL
    };
    g_autoptr(GError) error = NULL;
    g_autoptr(GUri) parsed = NULL;
    const gchar *scheme;
    const gchar *host;

    if (!uri)
        return FALSE;
    if (g_str_equal(uri, "about:blank"))
        return TRUE;

    parsed = g_uri_parse(uri, G_URI_FLAGS_PARSE_RELAXED, &error);
    if (!parsed)
        return FALSE;
    scheme = g_uri_get_scheme(parsed);
    host = g_uri_get_host(parsed);
    if (!scheme || g_ascii_strcasecmp(scheme, "https") != 0 || !host)
        return FALSE;

    for (guint index = 0; domains[index]; index++) {
        if (host_matches_domain(host, domains[index]))
            return TRUE;
    }
    return FALSE;
}

static gchar *uri_for_log(const gchar *uri);

static int run_uri_policy_self_test(void)
{
    static const gchar *const allowed[] = {
        "https://chatgpt.com/",
        "https://auth.openai.com/authorize",
        "https://accounts.google.com/",
        "https://ssl.gstatic.com/",
        "https://lh3.googleusercontent.com/",
        "about:blank",
        NULL
    };
    g_autofree gchar *sanitized_uri = NULL;
    static const gchar *const blocked[] = {
        "http://chatgpt.com/",
        "https://chatgpt.com.evil.example/",
        "https://evilgoogle.com/",
        "https://example.com/",
        "file:///etc/passwd",
        "javascript:alert(1)",
        NULL
    };

    for (guint index = 0; allowed[index]; index++) {
        if (!uri_is_allowed(allowed[index])) {
            g_printerr("URI policy rejected allowed URI: %s\n", allowed[index]);
            return 1;
        }
    }
    for (guint index = 0; blocked[index]; index++) {
        if (uri_is_allowed(blocked[index])) {
            g_printerr("URI policy accepted blocked URI: %s\n", blocked[index]);
            return 1;
        }
    }
    sanitized_uri = uri_for_log(
        "https://accounts.google.com/o/oauth2/v2/auth?state=secret#fragment");
    if (!g_str_equal(sanitized_uri,
            "https://accounts.google.com/o/oauth2/v2/auth")) {
        g_printerr("URI log sanitizer retained sensitive URL components: %s\n",
            sanitized_uri);
        return 1;
    }
    g_print("engineos-chatgpt URI policy passed\n");
    return 0;
}

static gboolean drop_process_capabilities(void)
{
    cap_t capabilities = cap_init();

    if (!capabilities) {
        g_printerr("engineos-chatgpt could not allocate an empty capability set: %s\n",
            g_strerror(errno));
        return FALSE;
    }
    if (cap_set_proc(capabilities) != 0) {
        g_printerr("engineos-chatgpt could not drop inherited capabilities: %s\n",
            g_strerror(errno));
        cap_free(capabilities);
        return FALSE;
    }
    cap_free(capabilities);
    return TRUE;
}

static void finish_application(EngineOSChatGPT *state, int exit_code)
{
    state->exit_code = exit_code;
    if (state->probe_timeout_id) {
        g_source_remove(state->probe_timeout_id);
        state->probe_timeout_id = 0;
    }
    if (state->held) {
        g_application_release(state->application);
        state->held = FALSE;
    }
    g_application_quit(state->application);
}

static gchar *uri_host(const gchar *uri)
{
    g_autoptr(GError) error = NULL;
    g_autoptr(GUri) parsed = NULL;
    const gchar *host;

    if (!uri)
        return g_strdup("starting");
    parsed = g_uri_parse(uri, G_URI_FLAGS_PARSE_RELAXED, &error);
    if (!parsed)
        return g_strdup("invalid URI");
    host = g_uri_get_host(parsed);
    return g_strdup(host ? host : uri);
}

static gchar *uri_for_log(const gchar *uri)
{
    g_autoptr(GError) error = NULL;
    g_autoptr(GUri) parsed = NULL;
    const gchar *scheme;
    const gchar *host;
    const gchar *path;
    int port;

    if (!uri)
        return g_strdup("missing");
    if (g_str_equal(uri, "about:blank"))
        return g_strdup(uri);

    parsed = g_uri_parse(uri, G_URI_FLAGS_PARSE_RELAXED, &error);
    if (!parsed)
        return g_strdup("invalid");
    scheme = g_uri_get_scheme(parsed);
    host = g_uri_get_host(parsed);
    path = g_uri_get_path(parsed);
    port = g_uri_get_port(parsed);
    if (!scheme || !host)
        return g_strdup("invalid");
    if (port >= 0)
        return g_strdup_printf("%s://%s:%d%s", scheme, host, port,
            path ? path : "");
    return g_strdup_printf("%s://%s%s", scheme, host, path ? path : "");
}

static void update_toplevel_title(WebKitWebView *web_view)
{
    WPEView *view = webkit_web_view_get_wpe_view(web_view);
    WPEToplevel *toplevel;
    g_autofree gchar *host = NULL;
    g_autofree gchar *title = NULL;

    if (!view)
        return;
    toplevel = wpe_view_get_toplevel(view);
    if (!toplevel)
        return;
    host = uri_host(webkit_web_view_get_uri(web_view));
    title = g_strdup_printf("EngineOS ChatGPT — HTTPS — %s", host);
    wpe_toplevel_set_title(toplevel, title);
}

static void uri_changed(WebKitWebView *web_view, GParamSpec *spec, gpointer user_data)
{
    const gchar *uri = webkit_web_view_get_uri(web_view);
    g_autofree gchar *log_uri = uri_for_log(uri);

    (void)spec;
    (void)user_data;
    update_toplevel_title(web_view);
    if (uri)
        g_printerr("engineos-chatgpt event=uri uri=%s\n", log_uri);
}

static gboolean decide_policy(WebKitWebView *web_view,
    WebKitPolicyDecision *decision, WebKitPolicyDecisionType type,
    gpointer user_data)
{
    (void)user_data;

    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        WebKitNavigationAction *action =
            webkit_navigation_policy_decision_get_navigation_action(
                WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        WebKitURIRequest *request = webkit_navigation_action_get_request(action);
        const gchar *uri = request ? webkit_uri_request_get_uri(request) : NULL;
        g_autofree gchar *log_uri = uri_for_log(uri);

        webkit_policy_decision_ignore(decision);
        if (!uri_is_allowed(uri)) {
            g_printerr("engineos-chatgpt event=blocked-new-window uri=%s\n",
                log_uri);
            return TRUE;
        }
        g_printerr("engineos-chatgpt event=fold-new-window uri=%s\n", log_uri);
        webkit_web_view_load_uri(web_view, uri);
        return TRUE;
    }

    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        WebKitResponsePolicyDecision *response_decision =
            WEBKIT_RESPONSE_POLICY_DECISION(decision);
        if (webkit_response_policy_decision_is_main_frame_main_resource(
                response_decision)) {
            WebKitURIResponse *response =
                webkit_response_policy_decision_get_response(response_decision);
            const gchar *uri = response ? webkit_uri_response_get_uri(response) : NULL;
            g_autofree gchar *log_uri = uri_for_log(uri);

            if (!uri_is_allowed(uri)) {
                webkit_policy_decision_ignore(decision);
                g_printerr("engineos-chatgpt event=blocked-response uri=%s\n",
                    log_uri);
                return TRUE;
            }
            g_printerr("engineos-chatgpt event=top-level-response uri=%s status=%u\n",
                log_uri, webkit_uri_response_get_status_code(response));
        }
    }

    webkit_policy_decision_use(decision);
    return TRUE;
}

static gboolean permission_request(WebKitWebView *web_view,
    WebKitPermissionRequest *request, gpointer user_data)
{
    (void)web_view;
    (void)user_data;
    g_printerr("engineos-chatgpt event=permission-denied type=%s\n",
        G_OBJECT_TYPE_NAME(request));
    webkit_permission_request_deny(request);
    return TRUE;
}

static void download_started(WebKitNetworkSession *session,
    WebKitDownload *download, gpointer user_data)
{
    (void)session;
    (void)user_data;
    g_printerr("engineos-chatgpt event=download-denied\n");
    webkit_download_cancel(download);
}

static gboolean load_failed(WebKitWebView *web_view, WebKitLoadEvent load_event,
    const gchar *failing_uri, GError *error, gpointer user_data)
{
    g_autofree gchar *log_uri = uri_for_log(failing_uri);

    (void)web_view;
    (void)load_event;
    (void)user_data;
    g_printerr("engineos-chatgpt event=load-failed uri=%s error=%s\n",
        log_uri,
        error ? error->message : "unknown");
    return FALSE;
}

static void web_process_terminated(WebKitWebView *web_view,
    WebKitWebProcessTerminationReason reason, gpointer user_data)
{
    EngineOSChatGPT *state = user_data;

    (void)web_view;
    g_printerr("engineos-chatgpt event=web-process-terminated reason=%d\n",
        (int)reason);
    finish_application(state, 1);
}

static void web_view_close(WebKitWebView *web_view, gpointer user_data)
{
    EngineOSChatGPT *state = user_data;

    (void)web_view;
    finish_application(state, state->exit_code);
}

static gboolean handle_wpe_view_event(WPEView *view, WPEEvent *event,
    gpointer user_data)
{
    WebKitWebView *web_view = WEBKIT_WEB_VIEW(user_data);
    WPEModifiers modifiers;
    guint keyval;

    (void)view;
    if (wpe_event_get_event_type(event) != WPE_EVENT_KEYBOARD_KEY_DOWN)
        return FALSE;
    modifiers = wpe_event_get_modifiers(event);
    keyval = wpe_event_keyboard_get_keyval(event);

    if ((modifiers & WPE_MODIFIER_KEYBOARD_CONTROL) && keyval == WPE_KEY_q) {
        webkit_web_view_try_close(web_view);
        return TRUE;
    }
    if ((modifiers & WPE_MODIFIER_KEYBOARD_CONTROL) && keyval == WPE_KEY_r) {
        webkit_web_view_reload(web_view);
        return TRUE;
    }
    if ((modifiers & WPE_MODIFIER_KEYBOARD_ALT) && keyval == WPE_KEY_Left &&
        webkit_web_view_can_go_back(web_view)) {
        webkit_web_view_go_back(web_view);
        return TRUE;
    }
    if ((modifiers & WPE_MODIFIER_KEYBOARD_ALT) && keyval == WPE_KEY_Right &&
        webkit_web_view_can_go_forward(web_view)) {
        webkit_web_view_go_forward(web_view);
        return TRUE;
    }
    return FALSE;
}

static gboolean probe_timeout(gpointer user_data)
{
    EngineOSChatGPT *state = user_data;

    state->probe_timeout_id = 0;
    g_printerr("engineos-chatgpt WebAuthn probe timed out before completion\n");
    finish_application(state, 2);
    return G_SOURCE_REMOVE;
}

static void web_authn_probe_finished(GObject *object, GAsyncResult *result,
    gpointer user_data)
{
    EngineOSChatGPT *state = user_data;
    g_autoptr(GError) error = NULL;
    g_autoptr(JSCValue) value = NULL;
    g_autofree gchar *output = NULL;

    value = webkit_web_view_call_async_javascript_function_finish(
        WEBKIT_WEB_VIEW(object), result, &error);
    if (!value) {
        g_printerr("engineos-chatgpt WebAuthn probe failed: %s\n",
            error ? error->message : "unknown error");
        finish_application(state, 2);
        return;
    }
    output = jsc_value_to_string(value);
    g_print("WEBAUTHN_PROBE %s\n", output ? output : "null");
    if (!output || strstr(output, "\"state\":\"timeout\"") ||
        strstr(output, "\"state\":\"rejected\"")) {
        finish_application(state, 2);
        return;
    }
    finish_application(state, 0);
}

static void start_web_authn_probe(EngineOSChatGPT *state)
{
    static const gchar body[] =
        "const started = performance.now();"
        "const ua = navigator.userAgent;"
        "if (typeof PublicKeyCredential === 'undefined' || "
        "typeof PublicKeyCredential.getClientCapabilities !== 'function') "
        "return JSON.stringify({state:'absent',elapsedMs:Math.round(performance.now()-started),userAgent:ua});"
        "try {"
        "const outcome = await Promise.race(["
        "PublicKeyCredential.getClientCapabilities().then(value => ({state:'fulfilled',value})),"
        "new Promise(resolve => setTimeout(() => resolve({state:'timeout'}), 5000))"
        "]);"
        "return JSON.stringify({...outcome,elapsedMs:Math.round(performance.now()-started),userAgent:ua});"
        "} catch (error) {"
        "return JSON.stringify({state:'rejected',name:error.name,message:error.message,"
        "elapsedMs:Math.round(performance.now()-started),userAgent:ua});"
        "}";

    if (state->probe_started)
        return;
    state->probe_started = TRUE;
    state->probe_timeout_id = g_timeout_add_seconds(15, probe_timeout, state);
    webkit_web_view_call_async_javascript_function(state->web_view,
        body, -1, NULL, NULL, "engineos-chatgpt-probe", NULL,
        web_authn_probe_finished, state);
}

static void load_changed(WebKitWebView *web_view, WebKitLoadEvent load_event,
    gpointer user_data)
{
    EngineOSChatGPT *state = user_data;

    if (load_event == WEBKIT_LOAD_FINISHED) {
        const gchar *uri = webkit_web_view_get_uri(web_view);
        g_autofree gchar *log_uri = uri_for_log(uri);
        g_printerr("engineos-chatgpt event=load-finished uri=%s\n",
            log_uri);
        if (state->probe_web_authn)
            start_web_authn_probe(state);
    }
}

static void display_disconnected(WPEDisplay *display, GError *error,
    gpointer user_data)
{
    EngineOSChatGPT *state = user_data;

    (void)display;
    g_printerr("engineos-chatgpt event=display-disconnected error=%s\n",
        error ? error->message : "none");
    finish_application(state, 1);
}

static gboolean ensure_private_directory(const gchar *directory)
{
    if (g_mkdir_with_parents(directory, 0700) != 0) {
        g_printerr("engineos-chatgpt could not create %s: %s\n",
            directory, g_strerror(errno));
        return FALSE;
    }
    if (g_chmod(directory, 0700) != 0) {
        g_printerr("engineos-chatgpt could not secure %s: %s\n",
            directory, g_strerror(errno));
        return FALSE;
    }
    return TRUE;
}

static void activate(GApplication *application, gpointer user_data)
{
    EngineOSChatGPT *state = user_data;
    g_autoptr(GError) display_error = NULL;
    g_autofree gchar *data_directory = NULL;
    g_autofree gchar *cache_directory = NULL;
    g_autofree gchar *cookie_database = NULL;
    WebKitCookieManager *cookie_manager;
    WebKitSettings *settings;
    WebKitUserContentManager *content_manager;
    WPEView *wpe_view;

    state->application = application;
    g_application_hold(application);
    state->held = TRUE;

    state->display = state->probe_web_authn ? wpe_display_headless_new() :
        wpe_display_wayland_new();
    if (!state->display ||
        !wpe_display_connect(state->display, &display_error)) {
        g_printerr("engineos-chatgpt could not connect to %s display: %s\n",
            state->probe_web_authn ? "headless" : "Wayland",
            display_error ? display_error->message : "unknown error");
        finish_application(state, 1);
        return;
    }
    g_signal_connect(state->display, "disconnected",
        G_CALLBACK(display_disconnected), state);

    if (state->probe_web_authn) {
        state->network_session = webkit_network_session_new_ephemeral();
    } else {
        data_directory = g_build_filename(g_get_user_data_dir(),
            "engineos-chatgpt", NULL);
        cache_directory = g_build_filename(g_get_user_cache_dir(),
            "engineos-chatgpt", NULL);
        if (!ensure_private_directory(data_directory) ||
            !ensure_private_directory(cache_directory)) {
            finish_application(state, 1);
            return;
        }
        state->network_session = webkit_network_session_new(data_directory,
            cache_directory);
        webkit_network_session_set_persistent_credential_storage_enabled(
            state->network_session, TRUE);
        cookie_manager = webkit_network_session_get_cookie_manager(
            state->network_session);
        cookie_database = g_build_filename(data_directory, "cookies.sqlite", NULL);
        webkit_cookie_manager_set_persistent_storage(cookie_manager,
            cookie_database, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
        webkit_cookie_manager_set_accept_policy(cookie_manager,
            WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);
    }
    g_signal_connect(state->network_session, "download-started",
        G_CALLBACK(download_started), state);

    state->web_context = webkit_web_context_new();
    settings = webkit_settings_new_with_settings(
        "enable-developer-extras", FALSE,
        "enable-webgl", TRUE,
        "enable-media-stream", FALSE,
        "enable-webrtc", FALSE,
        "enable-encrypted-media", FALSE,
        NULL);
    content_manager = webkit_user_content_manager_new();
    state->web_view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "display", state->display,
        "web-context", state->web_context,
        "network-session", state->network_session,
        "settings", settings,
        "user-content-manager", content_manager,
        NULL));
    g_object_unref(settings);
    g_object_unref(content_manager);

    g_signal_connect(state->web_view, "notify::uri", G_CALLBACK(uri_changed),
        state);
    g_signal_connect(state->web_view, "decide-policy", G_CALLBACK(decide_policy),
        state);
    g_signal_connect(state->web_view, "permission-request",
        G_CALLBACK(permission_request), state);
    g_signal_connect(state->web_view, "load-changed", G_CALLBACK(load_changed),
        state);
    g_signal_connect(state->web_view, "load-failed", G_CALLBACK(load_failed),
        state);
    g_signal_connect(state->web_view, "web-process-terminated",
        G_CALLBACK(web_process_terminated), state);
    g_signal_connect(state->web_view, "close", G_CALLBACK(web_view_close), state);

    wpe_view = webkit_web_view_get_wpe_view(state->web_view);
    if (!wpe_view || !wpe_view_get_toplevel(wpe_view)) {
        g_printerr("engineos-chatgpt WPE view has no toplevel\n");
        finish_application(state, 1);
        return;
    }
    g_signal_connect(wpe_view, "event", G_CALLBACK(handle_wpe_view_event),
        state->web_view);
    update_toplevel_title(state->web_view);

    webkit_web_view_load_uri(state->web_view,
        state->probe_web_authn ? ENGINEOS_CHATGPT_PROBE_URI :
            (state->start_login ? ENGINEOS_CHATGPT_LOGIN_URI :
                ENGINEOS_CHATGPT_HOME_URI));
}

int main(int argc, char **argv)
{
    g_autoptr(GError) error = NULL;
    g_autoptr(GOptionContext) option_context = NULL;
    EngineOSChatGPT state = { 0 };
    GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
    int run_result;

    option_context = g_option_context_new("— single-purpose ChatGPT WPE client");
    g_option_context_add_main_entries(option_context, option_entries, NULL);
    if (!g_option_context_parse(option_context, &argc, &argv, &error)) {
        g_printerr("engineos-chatgpt: %s\n", error->message);
        return 64;
    }
    if (argc != 1) {
        g_printerr("engineos-chatgpt does not accept arbitrary URLs\n");
        return 64;
    }
    if (option_self_test)
        return run_uri_policy_self_test();
    if (option_print_version) {
        g_print("engineos-chatgpt 0.1.0 (WPE WebKit %u.%u.%u)\n",
            webkit_get_major_version(), webkit_get_minor_version(),
            webkit_get_micro_version());
        return 0;
    }

    state.probe_web_authn = option_probe_web_authn;
    state.start_login = option_start_login;
    state.exit_code = 0;
    if (!drop_process_capabilities())
        return 1;
    g_set_prgname("engineos-chatgpt");
    g_set_application_name("EngineOS ChatGPT");
    if (state.probe_web_authn || state.start_login)
        flags |= G_APPLICATION_NON_UNIQUE;
    state.application = g_application_new(ENGINEOS_CHATGPT_APPLICATION_ID, flags);
    g_signal_connect(state.application, "activate", G_CALLBACK(activate), &state);
    run_result = g_application_run(state.application, 0, NULL);

    g_clear_object(&state.web_view);
    g_clear_object(&state.web_context);
    g_clear_object(&state.network_session);
    g_clear_object(&state.display);
    g_clear_object(&state.application);
    return state.exit_code ? state.exit_code : run_result;
}
