#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

enum engineos_shell_mode {
	ENGINEOS_SHELL_AUTO,
	ENGINEOS_SHELL_HEADLESS,
	ENGINEOS_SHELL_NESTED,
	ENGINEOS_SHELL_TTY,
};

enum engineos_surface_role {
	ENGINEOS_SURFACE_UNKNOWN,
	ENGINEOS_SURFACE_TERMINAL,
	ENGINEOS_SURFACE_ENGINE,
};

enum engineos_input_mode {
	ENGINEOS_INPUT_SHELL,
	ENGINEOS_INPUT_TERMINAL,
	ENGINEOS_INPUT_GAME,
};

enum engineos_bootstrap_mode {
	ENGINEOS_BOOTSTRAP_NONE,
	ENGINEOS_BOOTSTRAP_TERMINAL,
	ENGINEOS_BOOTSTRAP_ENGINE,
	ENGINEOS_BOOTSTRAP_ALL,
};

struct engineos_shell_server {
	struct wl_display *display;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_seat *seat;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_output_layout *output_layout;
	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wlr_scene *scene;
	struct wl_list outputs;
	struct wl_list views;
	struct wl_list keyboards;
	struct wl_list pointers;
	struct wl_listener new_output;
	struct wl_listener new_input;
	struct wl_listener new_xdg_surface;
	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;
	struct wl_listener request_cursor;
	struct engineos_shell_view *focused_view;
	const char *mode_name;
	const char *startup_cmd;
	const char *terminal_cmd;
	const char *engine_cmd;
	enum engineos_bootstrap_mode bootstrap_mode;
	enum engineos_input_mode input_mode;
	bool game_capture;
	int smoke_ms;
	unsigned int output_count;
	unsigned int keyboard_count;
	unsigned int pointer_count;
	unsigned int view_count;
};

struct engineos_shell_keyboard {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_input_device *device;
	struct wlr_keyboard *keyboard;
	struct wl_listener modifiers;
	struct wl_listener key;
	struct wl_listener destroy;
};

struct engineos_shell_pointer {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_input_device *device;
	struct wlr_pointer *wlr_pointer;
	struct wl_listener destroy;
};

struct engineos_shell_output {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_output *output;
	struct wlr_scene_output *scene_output;
	struct wl_listener frame;
	struct wl_listener destroy;
};

struct engineos_shell_view {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_xdg_surface *xdg_surface;
	struct wlr_scene_tree *scene_tree;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener commit;
	struct wl_listener destroy;
	enum engineos_surface_role role;
	bool mapped;
};

static const char *view_title(struct engineos_shell_view *view);
static const char *view_app_id(struct engineos_shell_view *view);
static void clear_keyboard_focus(struct engineos_shell_server *server);
static void clear_pointer_focus(struct engineos_shell_server *server,
	const char *reason);
static void focus_matching_role(struct engineos_shell_server *server,
	enum engineos_surface_role role);

static const char *mode_to_string(enum engineos_shell_mode mode) {
	switch (mode) {
	case ENGINEOS_SHELL_HEADLESS:
		return "headless";
	case ENGINEOS_SHELL_NESTED:
		return "nested";
	case ENGINEOS_SHELL_TTY:
		return "tty";
	case ENGINEOS_SHELL_AUTO:
	default:
		return "auto";
	}
}

static void usage(FILE *out, const char *argv0) {
	fprintf(out,
		"Usage: %s [--headless|--nested|--tty] [--smoke] [--smoke-ms N] [--startup CMD]\n"
		"          [--terminal CMD] [--engine CMD] [--bootstrap MODE]\n"
		"\n"
		"Start the EngineOS wlroots shell bootstrap.\n"
		"\n"
		"Options:\n"
		"  --headless      prefer the wlroots headless backend\n"
		"  --nested        prefer Wayland or X11 nesting\n"
		"  --tty           prefer direct DRM/libinput backends\n"
		"  --smoke         start and exit after one second\n"
		"  --smoke-ms N    start and exit after N milliseconds\n"
		"  --startup CMD   run CMD after the Wayland socket is ready\n"
		"  --terminal CMD  command launched by Alt+Return\n"
		"  --engine CMD    command launched by Alt+G\n"
		"  --bootstrap MODE  start none, terminal, engine, or all after shell startup\n"
		"  --version       print version\n"
		"  --help          print this help\n",
		argv0);
}

static const char *bootstrap_mode_name(enum engineos_bootstrap_mode mode) {
	switch (mode) {
	case ENGINEOS_BOOTSTRAP_TERMINAL:
		return "terminal";
	case ENGINEOS_BOOTSTRAP_ENGINE:
		return "engine";
	case ENGINEOS_BOOTSTRAP_ALL:
		return "all";
	case ENGINEOS_BOOTSTRAP_NONE:
	default:
		return "none";
	}
}

static bool parse_bootstrap_mode(const char *value,
		enum engineos_bootstrap_mode *mode) {
	if (strcmp(value, "none") == 0) {
		*mode = ENGINEOS_BOOTSTRAP_NONE;
		return true;
	}
	if (strcmp(value, "terminal") == 0) {
		*mode = ENGINEOS_BOOTSTRAP_TERMINAL;
		return true;
	}
	if (strcmp(value, "engine") == 0) {
		*mode = ENGINEOS_BOOTSTRAP_ENGINE;
		return true;
	}
	if (strcmp(value, "all") == 0) {
		*mode = ENGINEOS_BOOTSTRAP_ALL;
		return true;
	}
	return false;
}

static void setenv_if_missing(const char *name, const char *value) {
	if (getenv(name) == NULL) {
		setenv(name, value, 0);
	}
}

static void apply_mode_environment(enum engineos_shell_mode mode) {
	switch (mode) {
	case ENGINEOS_SHELL_HEADLESS:
		setenv_if_missing("WLR_BACKENDS", "headless");
		setenv_if_missing("WLR_HEADLESS_OUTPUTS", "1");
		break;
	case ENGINEOS_SHELL_NESTED:
		if (getenv("WLR_BACKENDS") == NULL) {
			if (getenv("WAYLAND_DISPLAY") != NULL) {
				setenv("WLR_BACKENDS", "wayland", 0);
			} else if (getenv("DISPLAY") != NULL) {
				setenv("WLR_BACKENDS", "x11", 0);
			}
		}
		break;
	case ENGINEOS_SHELL_TTY:
		setenv_if_missing("WLR_BACKENDS", "drm,libinput");
		break;
	case ENGINEOS_SHELL_AUTO:
	default:
		break;
	}
}

static int terminate_from_signal(int signal_number, void *data) {
	struct engineos_shell_server *server = data;
	wlr_log(WLR_INFO, "terminating on signal %d", signal_number);
	wl_display_terminate(server->display);
	return 0;
}

static int terminate_from_smoke_timer(void *data) {
	struct engineos_shell_server *server = data;
	wlr_log(WLR_INFO, "smoke timer elapsed after %d ms", server->smoke_ms);
	wl_display_terminate(server->display);
	return 0;
}

static void spawn_command(const char *label, const char *cmd) {
	if (cmd == NULL || cmd[0] == '\0') {
		wlr_log(WLR_INFO, "launch action ignored label=%s reason=no-command", label);
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		wlr_log(WLR_ERROR, "failed to fork command label=%s: %s",
			label, strerror(errno));
		return;
	}
	if (pid == 0) {
		setenv("XDG_SESSION_TYPE", "wayland", 1);
		setenv("GDK_BACKEND", "wayland", 0);
		setenv("QT_QPA_PLATFORM", "wayland", 0);
		setenv("SDL_VIDEODRIVER", "wayland", 0);
		setenv("CLUTTER_BACKEND", "wayland", 0);
		if (getenv("WAYLAND_DISPLAY") != NULL) {
			unsetenv("DISPLAY");
		}
		execl("/bin/sh", "/bin/sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	wlr_log(WLR_INFO, "launch action label=%s pid=%ld command=%s",
		label, (long)pid, cmd);
}

static const char *input_type_name(enum wlr_input_device_type type) {
	switch (type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		return "keyboard";
	case WLR_INPUT_DEVICE_POINTER:
		return "pointer";
	case WLR_INPUT_DEVICE_TOUCH:
		return "touch";
	case WLR_INPUT_DEVICE_TABLET:
		return "tablet";
	case WLR_INPUT_DEVICE_TABLET_PAD:
		return "tablet-pad";
	case WLR_INPUT_DEVICE_SWITCH:
		return "switch";
	default:
		return "unknown";
	}
}

static void update_seat_capabilities(struct engineos_shell_server *server) {
	uint32_t caps = 0;
	if (server->pointer_count > 0) {
		caps |= WL_SEAT_CAPABILITY_POINTER;
	}
	if (server->keyboard_count > 0) {
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	}
	wlr_seat_set_capabilities(server->seat, caps);
	wlr_log(WLR_INFO, "seat seat0 capabilities keyboard=%u pointer=%u caps=0x%x",
		server->keyboard_count, server->pointer_count, caps);
}

static void schedule_outputs(struct engineos_shell_server *server) {
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		wlr_output_schedule_frame(output->output);
	}
}

static const char *surface_role_name(enum engineos_surface_role role) {
	switch (role) {
	case ENGINEOS_SURFACE_TERMINAL:
		return "terminal";
	case ENGINEOS_SURFACE_ENGINE:
		return "engine";
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		return "unknown";
	}
}

static const char *input_mode_name(enum engineos_input_mode mode) {
	switch (mode) {
	case ENGINEOS_INPUT_SHELL:
		return "shell";
	case ENGINEOS_INPUT_TERMINAL:
		return "terminal";
	case ENGINEOS_INPUT_GAME:
		return "game";
	default:
		return "unknown";
	}
}

static void clear_pointer_focus(struct engineos_shell_server *server,
		const char *reason) {
	wlr_seat_pointer_notify_clear_focus(server->seat);
	wlr_log(WLR_INFO, "pointer focus cleared mode=%s capture=%s reason=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		reason != NULL ? reason : "unspecified");
}

static bool ascii_contains_ci(const char *haystack, const char *needle) {
	if (haystack == NULL || needle == NULL || needle[0] == '\0') {
		return false;
	}

	for (const char *h = haystack; *h != '\0'; h++) {
		const char *hp = h;
		const char *np = needle;
		while (*hp != '\0' && *np != '\0' &&
				tolower((unsigned char)*hp) == tolower((unsigned char)*np)) {
			hp++;
			np++;
		}
		if (*np == '\0') {
			return true;
		}
	}
	return false;
}

static struct engineos_shell_view *view_from_scene_node(
		struct engineos_shell_server *server, struct wlr_scene_node *node) {
	while (node != NULL) {
		struct engineos_shell_view *view;
		wl_list_for_each(view, &server->views, link) {
			if (view->scene_tree != NULL && node == &view->scene_tree->node) {
				return view;
			}
		}
		if (node->parent == NULL) {
			break;
		}
		node = &node->parent->node;
	}
	return NULL;
}

static struct engineos_shell_view *view_at_cursor(
		struct engineos_shell_server *server,
		struct wlr_surface **surface, double *sx, double *sy) {
	double nx = 0.0;
	double ny = 0.0;
	struct wlr_scene_node *node =
		wlr_scene_node_at(&server->scene->tree.node,
			server->cursor->x, server->cursor->y, &nx, &ny);
	if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
		return NULL;
	}

	struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(node);
	struct wlr_scene_surface *scene_surface =
		wlr_scene_surface_try_from_buffer(buffer);
	if (scene_surface == NULL || scene_surface->surface == NULL) {
		return NULL;
	}

	struct engineos_shell_view *view = view_from_scene_node(server, node);
	if (view == NULL || !view->mapped) {
		return NULL;
	}

	*surface = scene_surface->surface;
	*sx = nx;
	*sy = ny;
	return view;
}

static bool focused_view_pointer_coords(struct engineos_shell_server *server,
		struct wlr_surface **surface, double *sx, double *sy) {
	struct engineos_shell_view *view = server->focused_view;
	if (view == NULL || !view->mapped) {
		return false;
	}

	int vx = 0;
	int vy = 0;
	if (!wlr_scene_node_coords(&view->scene_tree->node, &vx, &vy)) {
		return false;
	}

	*surface = view->xdg_surface->surface;
	*sx = server->cursor->x - vx;
	*sy = server->cursor->y - vy;
	return true;
}

static void set_input_mode_for_clicked_view(struct engineos_shell_view *view) {
	struct engineos_shell_server *server = view->server;

	server->game_capture = false;
	switch (view->role) {
	case ENGINEOS_SURFACE_ENGINE:
		server->input_mode = ENGINEOS_INPUT_GAME;
		break;
	case ENGINEOS_SURFACE_TERMINAL:
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		server->input_mode = ENGINEOS_INPUT_TERMINAL;
		break;
	}

	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=click-focus role=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		surface_role_name(view->role));
}

static enum engineos_surface_role classify_view_role(struct engineos_shell_view *view) {
	const char *app_id = view_app_id(view);
	const char *title = view_title(view);

	if (ascii_contains_ci(app_id, "quake") ||
			ascii_contains_ci(title, "quake") ||
			ascii_contains_ci(app_id, "engine") ||
			ascii_contains_ci(title, "engine")) {
		return ENGINEOS_SURFACE_ENGINE;
	}
	if (ascii_contains_ci(app_id, "foot") ||
			ascii_contains_ci(app_id, "terminal") ||
			ascii_contains_ci(app_id, "alacritty") ||
			ascii_contains_ci(app_id, "kitty") ||
			ascii_contains_ci(app_id, "wezterm") ||
			ascii_contains_ci(app_id, "xterm") ||
			ascii_contains_ci(title, "terminal")) {
		return ENGINEOS_SURFACE_TERMINAL;
	}
	return ENGINEOS_SURFACE_UNKNOWN;
}

static void apply_view_layout(struct engineos_shell_view *view) {
	int x = 40;
	int y = 40;

	switch (view->role) {
	case ENGINEOS_SURFACE_TERMINAL:
		x = 40;
		y = 40;
		break;
	case ENGINEOS_SURFACE_ENGINE:
		x = 120;
		y = 80;
		break;
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		x = 40 + (int)(view->server->view_count * 24);
		y = 40 + (int)(view->server->view_count * 24);
		break;
	}
	wlr_scene_node_set_position(&view->scene_tree->node, x, y);
	wlr_log(WLR_INFO, "layout view role=%s x=%d y=%d title=%s app_id=%s",
		surface_role_name(view->role), x, y, view_title(view), view_app_id(view));
}

static void set_input_mode(struct engineos_shell_server *server,
		enum engineos_input_mode mode, const char *reason) {
	server->input_mode = mode;
	if (mode != ENGINEOS_INPUT_GAME) {
		server->game_capture = false;
	}

	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		reason != NULL ? reason : "unspecified");

	switch (mode) {
	case ENGINEOS_INPUT_SHELL:
		clear_keyboard_focus(server);
		break;
	case ENGINEOS_INPUT_TERMINAL:
		focus_matching_role(server, ENGINEOS_SURFACE_TERMINAL);
		break;
	case ENGINEOS_INPUT_GAME:
		focus_matching_role(server, ENGINEOS_SURFACE_ENGINE);
		break;
	}
}

static void toggle_game_capture(struct engineos_shell_server *server) {
	if (server->input_mode != ENGINEOS_INPUT_GAME) {
		set_input_mode(server, ENGINEOS_INPUT_GAME, "capture-toggle");
	}
	server->game_capture = !server->game_capture;
	wlr_log(WLR_INFO, "input capture=%s mode=%s reason=toggle",
		server->game_capture ? "game" : "none",
		input_mode_name(server->input_mode));
}

static void emergency_release(struct engineos_shell_server *server) {
	server->game_capture = false;
	set_input_mode(server, ENGINEOS_INPUT_SHELL, "emergency-release");
	wlr_log(WLR_INFO, "input emergency-release complete");
}

static void set_view_activated(struct engineos_shell_view *view, bool activated) {
	if (view != NULL && view->xdg_surface != NULL &&
			view->xdg_surface->toplevel != NULL) {
		wlr_xdg_toplevel_set_activated(view->xdg_surface->toplevel, activated);
	}
}

static void clear_keyboard_focus(struct engineos_shell_server *server) {
	if (server->focused_view != NULL && server->focused_view->mapped) {
		set_view_activated(server->focused_view, false);
	}
	server->focused_view = NULL;
	wlr_seat_keyboard_notify_clear_focus(server->seat);
	schedule_outputs(server);
	wlr_log(WLR_INFO, "focus cleared mode=%s capture=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none");
}

static void focus_view(struct engineos_shell_view *view) {
	if (view == NULL || !view->mapped) {
		return;
	}

	struct engineos_shell_server *server = view->server;
	if (server->focused_view != NULL && server->focused_view != view &&
			server->focused_view->mapped) {
		set_view_activated(server->focused_view, false);
	}

	server->focused_view = view;
	wlr_scene_node_raise_to_top(&view->scene_tree->node);
	set_view_activated(view, true);

	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
	if (keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(server->seat, view->xdg_surface->surface,
			keyboard->keycodes, keyboard->num_keycodes, &keyboard->modifiers);
	}

	schedule_outputs(server);
	wlr_log(WLR_INFO, "focus view mode=%s capture=%s role=%s title=%s app_id=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		surface_role_name(view->role), view_title(view), view_app_id(view));
}

static void focus_matching_role(struct engineos_shell_server *server,
		enum engineos_surface_role role) {
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (view->mapped && view->role == role) {
			focus_view(view);
			return;
		}
	}

	wlr_log(WLR_INFO, "focus role unavailable mode=%s requested_role=%s",
		input_mode_name(server->input_mode), surface_role_name(role));
	clear_keyboard_focus(server);
}

static void focus_next_view(struct engineos_shell_server *server) {
	if (wl_list_empty(&server->views)) {
		return;
	}

	struct engineos_shell_view *view;
	if (server->focused_view == NULL) {
		wl_list_for_each(view, &server->views, link) {
			if (view->mapped) {
				focus_view(view);
				return;
			}
		}
		return;
	}

	bool after_focused = false;
	wl_list_for_each(view, &server->views, link) {
		if (after_focused && view->mapped) {
			focus_view(view);
			return;
		}
		if (view == server->focused_view) {
			after_focused = true;
		}
	}
	wl_list_for_each(view, &server->views, link) {
		if (view->mapped) {
			focus_view(view);
			return;
		}
	}
}

static bool handle_keybinding(struct engineos_shell_server *server,
		xkb_keysym_t sym, uint32_t modifiers) {
	switch (sym) {
	case XKB_KEY_BackSpace:
		if ((modifiers & WLR_MODIFIER_CTRL) && (modifiers & WLR_MODIFIER_ALT)) {
			wlr_log(WLR_INFO, "keybinding ctrl+alt+backspace: emergency release");
			emergency_release(server);
			return true;
		}
		return false;
	default:
		break;
	}

	if (!(modifiers & WLR_MODIFIER_ALT)) {
		return false;
	}

	switch (sym) {
	case XKB_KEY_Escape:
		wlr_log(WLR_INFO, "keybinding alt+escape: terminate shell");
		wl_display_terminate(server->display);
		return true;
	case XKB_KEY_F1:
		wlr_log(WLR_INFO, "keybinding alt+f1: shell mode");
		set_input_mode(server, ENGINEOS_INPUT_SHELL, "alt+f1");
		return true;
	case XKB_KEY_F2:
		wlr_log(WLR_INFO, "keybinding alt+f2: terminal mode");
		set_input_mode(server, ENGINEOS_INPUT_TERMINAL, "alt+f2");
		return true;
	case XKB_KEY_F3:
		wlr_log(WLR_INFO, "keybinding alt+f3: game mode");
		set_input_mode(server, ENGINEOS_INPUT_GAME, "alt+f3");
		return true;
	case XKB_KEY_c:
	case XKB_KEY_C:
		wlr_log(WLR_INFO, "keybinding alt+c: toggle game capture");
		toggle_game_capture(server);
		return true;
	case XKB_KEY_Return:
		wlr_log(WLR_INFO, "keybinding alt+return: launch terminal");
		spawn_command("terminal", server->terminal_cmd);
		return true;
	case XKB_KEY_g:
	case XKB_KEY_G:
		wlr_log(WLR_INFO, "keybinding alt+g: launch engine");
		spawn_command("engine", server->engine_cmd);
		return true;
	case XKB_KEY_Tab:
		wlr_log(WLR_INFO, "keybinding alt+tab: cycle focus");
		focus_next_view(server);
		return true;
	default:
		return false;
	}
}

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_keyboard *keyboard =
		wl_container_of(listener, keyboard, modifiers);
	wlr_seat_set_keyboard(keyboard->server->seat, keyboard->keyboard);
	wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
		&keyboard->keyboard->modifiers);
}

static void keyboard_handle_key(struct wl_listener *listener, void *data) {
	struct engineos_shell_keyboard *keyboard =
		wl_container_of(listener, keyboard, key);
	struct engineos_shell_server *server = keyboard->server;
	struct wlr_keyboard_key_event *event = data;

	uint32_t keycode = event->keycode + 8;
	const xkb_keysym_t *syms;
	int nsyms = xkb_state_key_get_syms(keyboard->keyboard->xkb_state,
		keycode, &syms);
	uint32_t modifiers = wlr_keyboard_get_modifiers(keyboard->keyboard);
	bool handled = false;

	if (((modifiers & WLR_MODIFIER_ALT) || (modifiers & WLR_MODIFIER_CTRL)) &&
			event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		for (int i = 0; i < nsyms; i++) {
			handled = handle_keybinding(server, syms[i], modifiers) || handled;
		}
	}

	if (!handled && server->input_mode != ENGINEOS_INPUT_SHELL) {
		wlr_seat_set_keyboard(server->seat, keyboard->keyboard);
		wlr_seat_keyboard_notify_key(server->seat, event->time_msec,
			event->keycode, event->state);
	} else if (!handled) {
		wlr_log(WLR_INFO, "input swallowed mode=shell keycode=%u state=%u",
			event->keycode, event->state);
	}
}

static void keyboard_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_keyboard *keyboard =
		wl_container_of(listener, keyboard, destroy);
	struct engineos_shell_server *server = keyboard->server;

	wl_list_remove(&keyboard->link);
	wl_list_remove(&keyboard->modifiers.link);
	wl_list_remove(&keyboard->key.link);
	wl_list_remove(&keyboard->destroy.link);
	if (server->keyboard_count > 0) {
		server->keyboard_count--;
	}
	update_seat_capabilities(server);
	free(keyboard);
}

static void server_new_keyboard(struct engineos_shell_server *server,
		struct wlr_input_device *device) {
	struct engineos_shell_keyboard *keyboard = calloc(1, sizeof(*keyboard));
	if (keyboard == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate keyboard state");
		return;
	}
	keyboard->server = server;
	keyboard->device = device;
	keyboard->keyboard = wlr_keyboard_from_input_device(device);

	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (context == NULL) {
		wlr_log(WLR_ERROR, "failed to create XKB context");
		free(keyboard);
		return;
	}
	struct xkb_keymap *keymap =
		xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (keymap == NULL) {
		wlr_log(WLR_ERROR, "failed to create XKB keymap");
		xkb_context_unref(context);
		free(keyboard);
		return;
	}

	wlr_keyboard_set_keymap(keyboard->keyboard, keymap);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
	wlr_keyboard_set_repeat_info(keyboard->keyboard, 25, 600);

	keyboard->modifiers.notify = keyboard_handle_modifiers;
	wl_signal_add(&keyboard->keyboard->events.modifiers, &keyboard->modifiers);
	keyboard->key.notify = keyboard_handle_key;
	wl_signal_add(&keyboard->keyboard->events.key, &keyboard->key);
	keyboard->destroy.notify = keyboard_destroy;
	wl_signal_add(&device->events.destroy, &keyboard->destroy);
	wl_list_insert(&server->keyboards, &keyboard->link);

	server->keyboard_count++;
	wlr_seat_set_keyboard(server->seat, keyboard->keyboard);
	update_seat_capabilities(server);
	wlr_log(WLR_INFO, "keyboard configured name=%s", device->name != NULL ? device->name : "(unnamed)");

	if (server->focused_view != NULL && server->focused_view->mapped) {
		focus_view(server->focused_view);
	}
}

static const char *cursor_pointer_name(struct wlr_pointer *pointer) {
	if (pointer == NULL || pointer->base.name == NULL) {
		return "(unnamed)";
	}
	return pointer->base.name;
}

static void set_default_cursor(struct engineos_shell_server *server,
		const char *reason) {
	if (server->cursor_mgr == NULL) {
		return;
	}
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	wlr_log(WLR_INFO, "cursor image=default reason=%s",
		reason != NULL ? reason : "unspecified");
}

static void cursor_log_event(struct engineos_shell_server *server,
		const char *event_name, struct wlr_pointer *pointer) {
	wlr_log(WLR_INFO, "pointer %s mode=%s capture=%s focus=%s x=%.1f y=%.1f device=%s",
		event_name,
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		server->focused_view != NULL ? surface_role_name(server->focused_view->role) : "none",
		server->cursor->x, server->cursor->y,
		cursor_pointer_name(pointer));
}

static bool cursor_target(struct engineos_shell_server *server,
		struct wlr_surface **surface, double *sx, double *sy,
		struct engineos_shell_view **view) {
	*surface = NULL;
	*sx = 0.0;
	*sy = 0.0;
	*view = NULL;

	if (server->input_mode == ENGINEOS_INPUT_SHELL) {
		set_default_cursor(server, "shell-mode");
		clear_pointer_focus(server, "shell-mode");
		return false;
	}

	if (server->game_capture) {
		if (!focused_view_pointer_coords(server, surface, sx, sy)) {
			clear_pointer_focus(server, "capture-no-focused-view");
			return false;
		}
		*view = server->focused_view;
		return true;
	}

	*view = view_at_cursor(server, surface, sx, sy);
	if (*view == NULL || *surface == NULL) {
		set_default_cursor(server, "no-surface-under-cursor");
		clear_pointer_focus(server, "no-surface-under-cursor");
		return false;
	}
	return true;
}

static bool cursor_update_pointer_focus(struct engineos_shell_server *server,
		uint32_t time_msec, const char *reason) {
	struct wlr_surface *surface = NULL;
	double sx = 0.0;
	double sy = 0.0;
	struct engineos_shell_view *view = NULL;

	if (!cursor_target(server, &surface, &sx, &sy, &view)) {
		return false;
	}

	wlr_seat_pointer_notify_enter(server->seat, surface, sx, sy);
	wlr_seat_pointer_notify_motion(server->seat, time_msec, sx, sy);
	wlr_log(WLR_INFO, "pointer focus role=%s sx=%.1f sy=%.1f reason=%s",
		view != NULL ? surface_role_name(view->role) : "unknown",
		sx, sy, reason != NULL ? reason : "unspecified");
	return true;
}

static void cursor_handle_motion(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;

	wlr_cursor_move(server->cursor, &event->pointer->base,
		event->delta_x, event->delta_y);
	cursor_log_event(server, "motion", event->pointer);
	cursor_update_pointer_focus(server, event->time_msec, "motion");
}

static void cursor_handle_motion_absolute(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;

	wlr_cursor_warp_absolute(server->cursor, &event->pointer->base,
		event->x, event->y);
	cursor_log_event(server, "motion-absolute", event->pointer);
	cursor_update_pointer_focus(server, event->time_msec, "motion-absolute");
}

static void cursor_handle_button(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;

	cursor_log_event(server, "button", event->pointer);
	if (event->state == WL_POINTER_BUTTON_STATE_PRESSED &&
			!server->game_capture) {
		struct wlr_surface *surface = NULL;
		double sx = 0.0;
		double sy = 0.0;
		struct engineos_shell_view *view =
			view_at_cursor(server, &surface, &sx, &sy);
		if (view != NULL) {
			focus_view(view);
			set_input_mode_for_clicked_view(view);
			wlr_log(WLR_INFO, "pointer click-focus role=%s sx=%.1f sy=%.1f",
				surface_role_name(view->role), sx, sy);
		}
	}

	if (cursor_update_pointer_focus(server, event->time_msec, "button")) {
		wlr_seat_pointer_notify_button(server->seat, event->time_msec,
			event->button, event->state);
	}
}

static void cursor_handle_axis(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;

	cursor_log_event(server, "axis", event->pointer);
	if (cursor_update_pointer_focus(server, event->time_msec, "axis")) {
		wlr_seat_pointer_notify_axis(server->seat, event->time_msec,
			event->orientation, event->delta, event->delta_discrete,
			event->source, event->relative_direction);
	}
}

static void cursor_handle_frame(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_frame);

	cursor_log_event(server, "frame", NULL);
	if (server->input_mode != ENGINEOS_INPUT_SHELL) {
		wlr_seat_pointer_notify_frame(server->seat);
	}
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, request_cursor);
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	struct wlr_seat_client *focused_client =
		server->seat->pointer_state.focused_client;

	if (focused_client == event->seat_client) {
		wlr_cursor_set_surface(server->cursor, event->surface,
			event->hotspot_x, event->hotspot_y);
		wlr_log(WLR_INFO, "cursor image=client hotspot=%d,%d",
			event->hotspot_x, event->hotspot_y);
	} else {
		wlr_log(WLR_INFO, "cursor image request ignored reason=unfocused-client");
	}
}

static void pointer_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_pointer *pointer =
		wl_container_of(listener, pointer, destroy);
	struct engineos_shell_server *server = pointer->server;

	wlr_log(WLR_INFO, "pointer destroyed device=%s",
		pointer->device->name != NULL ? pointer->device->name : "(unnamed)");
	wlr_cursor_detach_input_device(server->cursor, pointer->device);
	wl_list_remove(&pointer->link);
	wl_list_remove(&pointer->destroy.link);
	if (server->pointer_count > 0) {
		server->pointer_count--;
	}
	update_seat_capabilities(server);
	free(pointer);
}

static void server_new_pointer(struct engineos_shell_server *server,
		struct wlr_input_device *device) {
	struct engineos_shell_pointer *pointer = calloc(1, sizeof(*pointer));
	if (pointer == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate pointer state");
		return;
	}
	pointer->server = server;
	pointer->device = device;
	pointer->wlr_pointer = wlr_pointer_from_input_device(device);

	wlr_cursor_attach_input_device(server->cursor, device);
	pointer->destroy.notify = pointer_destroy;
	wl_signal_add(&device->events.destroy, &pointer->destroy);
	wl_list_insert(&server->pointers, &pointer->link);

	server->pointer_count++;
	update_seat_capabilities(server);
	wlr_log(WLR_INFO, "pointer configured name=%s",
		device->name != NULL ? device->name : "(unnamed)");
}

static void output_frame(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_output *output =
		wl_container_of(listener, output, frame);

	if (!wlr_scene_output_commit(output->scene_output, NULL)) {
		wlr_log(WLR_ERROR, "failed to commit scene output name=%s",
			output->output->name[0] != '\0' ? output->output->name : "(unnamed)");
		return;
	}

	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(output->scene_output, &now);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_output *output =
		wl_container_of(listener, output, destroy);

	wlr_log(WLR_INFO, "output destroyed name=%s",
		output->output->name[0] != '\0' ? output->output->name : "(unnamed)");
	wl_list_remove(&output->link);
	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->destroy.link);
	if (output->scene_output != NULL) {
		wlr_scene_output_destroy(output->scene_output);
	}
	free(output);
}

static void server_new_output(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_output);
	struct wlr_output *output = data;
	server->output_count++;

	if (!wlr_output_init_render(output, server->allocator, server->renderer)) {
		wlr_log(WLR_ERROR, "failed to initialize output rendering name=%s",
			output->name[0] != '\0' ? output->name : "(unnamed)");
		return;
	}

	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, true);
	struct wlr_output_mode *selected_mode = NULL;
	if (!wl_list_empty(&output->modes)) {
		selected_mode = wlr_output_preferred_mode(output);
		if (selected_mode != NULL) {
			wlr_output_state_set_mode(&state, selected_mode);
		}
	}
	if (!wlr_output_commit_state(output, &state)) {
		wlr_output_state_finish(&state);
		wlr_log(WLR_ERROR, "failed to commit output name=%s",
			output->name[0] != '\0' ? output->name : "(unnamed)");
		return;
	}
	wlr_output_state_finish(&state);

	if (server->cursor_mgr != NULL) {
		if (wlr_xcursor_manager_load(server->cursor_mgr, output->scale)) {
			set_default_cursor(server, "output-added");
		} else {
			wlr_log(WLR_ERROR, "failed to load xcursor theme scale=%.2f",
				output->scale);
		}
	}

	wlr_output_layout_add_auto(server->output_layout, output);
	struct engineos_shell_output *shell_output = calloc(1, sizeof(*shell_output));
	if (shell_output == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate output state");
		return;
	}
	shell_output->server = server;
	shell_output->output = output;
	shell_output->scene_output = wlr_scene_output_create(server->scene, output);
	if (shell_output->scene_output == NULL) {
		wlr_log(WLR_ERROR, "failed to create scene output");
		free(shell_output);
		return;
	}
	struct wlr_output_layout_output *layout_output =
		wlr_output_layout_get(server->output_layout, output);
	if (layout_output != NULL) {
		wlr_scene_output_set_position(shell_output->scene_output,
			layout_output->x, layout_output->y);
	}
	shell_output->frame.notify = output_frame;
	wl_signal_add(&output->events.frame, &shell_output->frame);
	shell_output->destroy.notify = output_destroy;
	wl_signal_add(&output->events.destroy, &shell_output->destroy);
	wl_list_insert(&server->outputs, &shell_output->link);
	wlr_output_schedule_frame(output);

	int width = 0;
	int height = 0;
	wlr_output_effective_resolution(output, &width, &height);
	wlr_log(WLR_INFO,
		"output added count=%u name=%s description=%s size=%dx%d scale=%.2f",
		server->output_count,
		output->name[0] != '\0' ? output->name : "(unnamed)",
		output->description != NULL ? output->description : "(none)",
		width, height, output->scale);
	if (selected_mode != NULL) {
		wlr_log(WLR_INFO,
			"output selected connector=%s mode=%dx%d refresh_mhz=%d backend=%s",
			output->name[0] != '\0' ? output->name : "(unnamed)",
			selected_mode->width,
			selected_mode->height,
			selected_mode->refresh,
			getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto");
	} else {
		wlr_log(WLR_INFO,
			"output selected connector=%s mode=custom-or-unknown refresh_mhz=0 backend=%s",
			output->name[0] != '\0' ? output->name : "(unnamed)",
			getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto");
	}
}

static void server_new_input(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_input);
	struct wlr_input_device *device = data;

	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:
		server_new_keyboard(server, device);
		break;
	case WLR_INPUT_DEVICE_POINTER:
		server_new_pointer(server, device);
		break;
	default:
		break;
	}

	wlr_log(WLR_INFO, "input added type=%s name=%s",
		input_type_name(device->type),
		device->name != NULL ? device->name : "(unnamed)");
}

static const char *view_title(struct engineos_shell_view *view) {
	if (view->xdg_surface->toplevel == NULL ||
			view->xdg_surface->toplevel->title == NULL ||
			view->xdg_surface->toplevel->title[0] == '\0') {
		return "(untitled)";
	}
	return view->xdg_surface->toplevel->title;
}

static const char *view_app_id(struct engineos_shell_view *view) {
	if (view->xdg_surface->toplevel == NULL ||
			view->xdg_surface->toplevel->app_id == NULL ||
			view->xdg_surface->toplevel->app_id[0] == '\0') {
		return "(unknown)";
	}
	return view->xdg_surface->toplevel->app_id;
}

static void xdg_surface_map(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, map);
	view->mapped = true;
	view->role = classify_view_role(view);
	apply_view_layout(view);
	wlr_scene_node_set_enabled(&view->scene_tree->node, true);
	if ((view->role == ENGINEOS_SURFACE_TERMINAL &&
				view->server->input_mode == ENGINEOS_INPUT_TERMINAL) ||
			(view->role == ENGINEOS_SURFACE_ENGINE &&
				view->server->input_mode == ENGINEOS_INPUT_GAME) ||
			(view->server->focused_view == NULL &&
				view->server->input_mode != ENGINEOS_INPUT_SHELL)) {
		focus_view(view);
	}
	wlr_log(WLR_INFO, "view mapped role=%s title=%s app_id=%s mapped_total=%u",
		surface_role_name(view->role), view_title(view), view_app_id(view),
		view->server->view_count);
}

static void xdg_surface_unmap(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, unmap);
	view->mapped = false;
	wlr_scene_node_set_enabled(&view->scene_tree->node, false);
	if (view->server->focused_view == view) {
		view->server->focused_view = NULL;
		set_view_activated(view, false);
		wlr_seat_keyboard_notify_clear_focus(view->server->seat);
	}
	schedule_outputs(view->server);
	wlr_log(WLR_INFO, "view unmapped role=%s title=%s app_id=%s",
		surface_role_name(view->role), view_title(view), view_app_id(view));
}

static void xdg_surface_commit(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, commit);
	if (view->xdg_surface->initial_commit &&
			view->xdg_surface->toplevel != NULL) {
		wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel, 0, 0);
		wlr_log(WLR_INFO, "view initial configure role=%s title=%s app_id=%s",
			surface_role_name(view->role), view_title(view), view_app_id(view));
	}
}

static void xdg_surface_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, destroy);
	struct engineos_shell_server *server = view->server;

	wlr_log(WLR_INFO, "view destroyed role=%s title=%s app_id=%s",
		surface_role_name(view->role), view_title(view), view_app_id(view));
	if (server->focused_view == view) {
		server->focused_view = NULL;
		wlr_seat_keyboard_notify_clear_focus(server->seat);
	}
	if (view->scene_tree != NULL) {
		wlr_scene_node_destroy(&view->scene_tree->node);
	}
	wl_list_remove(&view->link);
	wl_list_remove(&view->map.link);
	wl_list_remove(&view->unmap.link);
	wl_list_remove(&view->commit.link);
	wl_list_remove(&view->destroy.link);
	if (server->view_count > 0) {
		server->view_count--;
	}
	free(view);
}

static void server_new_xdg_surface(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_xdg_surface);
	struct wlr_xdg_toplevel *toplevel = data;
	struct wlr_xdg_surface *xdg_surface = toplevel->base;

	struct engineos_shell_view *view = calloc(1, sizeof(*view));
	if (view == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate view");
		return;
	}

	view->server = server;
	view->xdg_surface = xdg_surface;
	view->role = ENGINEOS_SURFACE_UNKNOWN;
	view->scene_tree = wlr_scene_xdg_surface_create(&server->scene->tree, xdg_surface);
	if (view->scene_tree == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate scene tree for view");
		free(view);
		return;
	}
	view->scene_tree->node.data = view;
	wlr_scene_node_set_enabled(&view->scene_tree->node, false);
	wlr_scene_node_set_position(&view->scene_tree->node,
		40 + (int)(server->view_count * 24), 40 + (int)(server->view_count * 24));
	view->map.notify = xdg_surface_map;
	wl_signal_add(&xdg_surface->surface->events.map, &view->map);
	view->unmap.notify = xdg_surface_unmap;
	wl_signal_add(&xdg_surface->surface->events.unmap, &view->unmap);
	view->commit.notify = xdg_surface_commit;
	wl_signal_add(&xdg_surface->surface->events.commit, &view->commit);
	view->destroy.notify = xdg_surface_destroy;
	wl_signal_add(&toplevel->events.destroy, &view->destroy);
	wl_list_insert(&server->views, &view->link);
	server->view_count++;

	wlr_log(WLR_INFO, "view created count=%u role=toplevel surface_role=%s",
		server->view_count, surface_role_name(view->role));
}

static bool setup_server(struct engineos_shell_server *server) {
	server->display = wl_display_create();
	if (server->display == NULL) {
		fprintf(stderr, "engineos-shell: failed to create Wayland display\n");
		return false;
	}

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server->display);
	server->backend = wlr_backend_autocreate(event_loop, NULL);
	if (server->backend == NULL) {
		wlr_log(WLR_ERROR, "failed to create wlroots backend");
		return false;
	}

	server->renderer = wlr_renderer_autocreate(server->backend);
	if (server->renderer == NULL) {
		wlr_log(WLR_ERROR, "failed to create renderer");
		return false;
	}

	if (!wlr_renderer_init_wl_display(server->renderer, server->display)) {
		wlr_log(WLR_ERROR, "failed to initialize renderer globals");
		return false;
	}
	server->allocator = wlr_allocator_autocreate(server->backend, server->renderer);
	if (server->allocator == NULL) {
		wlr_log(WLR_ERROR, "failed to create allocator");
		return false;
	}

	wlr_compositor_create(server->display, 5, server->renderer);
	wlr_subcompositor_create(server->display);
	wlr_data_device_manager_create(server->display);
	server->output_layout = wlr_output_layout_create(server->display);
	if (server->output_layout == NULL) {
		wlr_log(WLR_ERROR, "failed to create output layout");
		return false;
	}
	server->cursor = wlr_cursor_create();
	if (server->cursor == NULL) {
		wlr_log(WLR_ERROR, "failed to create cursor");
		return false;
	}
	wlr_cursor_attach_output_layout(server->cursor, server->output_layout);
	server->cursor_mgr = wlr_xcursor_manager_create(NULL, 24);
	if (server->cursor_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create xcursor manager");
		return false;
	}
	server->cursor_motion.notify = cursor_handle_motion;
	wl_signal_add(&server->cursor->events.motion, &server->cursor_motion);
	server->cursor_motion_absolute.notify = cursor_handle_motion_absolute;
	wl_signal_add(&server->cursor->events.motion_absolute,
		&server->cursor_motion_absolute);
	server->cursor_button.notify = cursor_handle_button;
	wl_signal_add(&server->cursor->events.button, &server->cursor_button);
	server->cursor_axis.notify = cursor_handle_axis;
	wl_signal_add(&server->cursor->events.axis, &server->cursor_axis);
	server->cursor_frame.notify = cursor_handle_frame;
	wl_signal_add(&server->cursor->events.frame, &server->cursor_frame);
	server->scene = wlr_scene_create();
	if (server->scene == NULL) {
		wlr_log(WLR_ERROR, "failed to create scene graph");
		return false;
	}
	wl_list_init(&server->outputs);
	wl_list_init(&server->views);
	wl_list_init(&server->keyboards);
	wl_list_init(&server->pointers);
	server->xdg_shell = wlr_xdg_shell_create(server->display, 3);
	if (server->xdg_shell == NULL) {
		wlr_log(WLR_ERROR, "failed to create xdg-shell global");
		return false;
	}
	server->new_xdg_surface.notify = server_new_xdg_surface;
	wl_signal_add(&server->xdg_shell->events.new_toplevel, &server->new_xdg_surface);

	server->seat = wlr_seat_create(server->display, "seat0");
	if (server->seat == NULL) {
		wlr_log(WLR_ERROR, "failed to create Wayland seat");
		return false;
	}
	server->request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server->seat->events.request_set_cursor,
		&server->request_cursor);

	server->new_output.notify = server_new_output;
	wl_signal_add(&server->backend->events.new_output, &server->new_output);
	server->new_input.notify = server_new_input;
	wl_signal_add(&server->backend->events.new_input, &server->new_input);

	return true;
}

static void destroy_server(struct engineos_shell_server *server) {
	if (server->display != NULL) {
		wl_display_destroy_clients(server->display);
	}
	if (server->scene != NULL) {
		wlr_scene_node_destroy(&server->scene->tree.node);
		server->scene = NULL;
	}
	if (server->cursor_mgr != NULL) {
		wlr_xcursor_manager_destroy(server->cursor_mgr);
		server->cursor_mgr = NULL;
	}
	if (server->cursor != NULL) {
		wlr_cursor_destroy(server->cursor);
		server->cursor = NULL;
	}
	if (server->output_layout != NULL) {
		wlr_output_layout_destroy(server->output_layout);
		server->output_layout = NULL;
	}
	if (server->allocator != NULL) {
		wlr_allocator_destroy(server->allocator);
		server->allocator = NULL;
	}
	if (server->renderer != NULL) {
		wlr_renderer_destroy(server->renderer);
		server->renderer = NULL;
	}
	if (server->backend != NULL) {
		wlr_backend_destroy(server->backend);
		server->backend = NULL;
	}
	if (server->display != NULL) {
		wl_display_destroy(server->display);
		server->display = NULL;
	}
}

int main(int argc, char **argv) {
	enum engineos_shell_mode mode = ENGINEOS_SHELL_AUTO;
	struct engineos_shell_server server = {0};

	static const struct option options[] = {
		{"headless", no_argument, NULL, 'H'},
		{"nested", no_argument, NULL, 'N'},
		{"tty", no_argument, NULL, 'T'},
		{"smoke", no_argument, NULL, 's'},
		{"smoke-ms", required_argument, NULL, 'm'},
		{"startup", required_argument, NULL, 'c'},
		{"terminal", required_argument, NULL, 1000},
		{"engine", required_argument, NULL, 1001},
		{"bootstrap", required_argument, NULL, 1002},
		{"version", no_argument, NULL, 'v'},
		{"help", no_argument, NULL, 'h'},
		{0},
	};

	int opt;
	while ((opt = getopt_long(argc, argv, "HNTsm:c:vh", options, NULL)) != -1) {
		switch (opt) {
		case 'H':
			mode = ENGINEOS_SHELL_HEADLESS;
			break;
		case 'N':
			mode = ENGINEOS_SHELL_NESTED;
			break;
		case 'T':
			mode = ENGINEOS_SHELL_TTY;
			break;
		case 's':
			server.smoke_ms = 1000;
			break;
		case 'm':
			server.smoke_ms = atoi(optarg);
			if (server.smoke_ms <= 0) {
				fprintf(stderr, "engineos-shell: --smoke-ms must be positive\n");
				return 2;
			}
			break;
		case 'c':
			server.startup_cmd = optarg;
			break;
		case 1000:
			server.terminal_cmd = optarg;
			break;
		case 1001:
			server.engine_cmd = optarg;
			break;
		case 1002:
			if (!parse_bootstrap_mode(optarg, &server.bootstrap_mode)) {
				fprintf(stderr,
					"engineos-shell: --bootstrap must be none, terminal, engine, or all\n");
				return 2;
			}
			break;
		case 'v':
			puts("engineos-shell 0.1.0");
			return 0;
		case 'h':
			usage(stdout, argv[0]);
			return 0;
		default:
			usage(stderr, argv[0]);
			return 2;
		}
	}

	if (optind != argc) {
		usage(stderr, argv[0]);
		return 2;
	}

	server.mode_name = mode_to_string(mode);
	server.input_mode = ENGINEOS_INPUT_TERMINAL;
	apply_mode_environment(mode);
	wlr_log_init(WLR_DEBUG, NULL);

	if (!setup_server(&server)) {
		destroy_server(&server);
		return 1;
	}

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server.display);
	wl_event_loop_add_signal(event_loop, SIGINT, terminate_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGTERM, terminate_from_signal, &server);

	if (server.smoke_ms > 0) {
		struct wl_event_source *timer =
			wl_event_loop_add_timer(event_loop, terminate_from_smoke_timer, &server);
		if (timer == NULL) {
			wlr_log(WLR_ERROR, "failed to add smoke timer");
			destroy_server(&server);
			return 1;
		}
		wl_event_source_timer_update(timer, server.smoke_ms);
	}

	const char *socket = wl_display_add_socket_auto(server.display);
	if (socket == NULL) {
		wlr_log(WLR_ERROR, "failed to create Wayland socket");
		destroy_server(&server);
		return 1;
	}

	if (!wlr_backend_start(server.backend)) {
		wlr_log(WLR_ERROR, "failed to start wlroots backend");
		destroy_server(&server);
		return 1;
	}

	setenv("WAYLAND_DISPLAY", socket, 1);
	wlr_log(WLR_INFO, "engineos-shell mode=%s backend=%s wayland_display=%s",
		server.mode_name, getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto", socket);
	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=startup",
		input_mode_name(server.input_mode),
		server.game_capture ? "game" : "none");
	wlr_log(WLR_INFO, "launch commands terminal=%s engine=%s startup=%s",
		server.terminal_cmd != NULL ? server.terminal_cmd : "(none)",
		server.engine_cmd != NULL ? server.engine_cmd : "(none)",
		server.startup_cmd != NULL ? server.startup_cmd : "(none)");
	wlr_log(WLR_INFO, "bootstrap mode=%s",
		bootstrap_mode_name(server.bootstrap_mode));
	wlr_log(WLR_INFO, "client launch environment wayland_display=%s xdg_session_type=wayland display=unset",
		socket);
	spawn_command("startup", server.startup_cmd);
	if (server.bootstrap_mode == ENGINEOS_BOOTSTRAP_TERMINAL ||
			server.bootstrap_mode == ENGINEOS_BOOTSTRAP_ALL) {
		spawn_command("bootstrap-terminal", server.terminal_cmd);
	}
	if (server.bootstrap_mode == ENGINEOS_BOOTSTRAP_ENGINE ||
			server.bootstrap_mode == ENGINEOS_BOOTSTRAP_ALL) {
		spawn_command("bootstrap-engine", server.engine_cmd);
	}

	wl_display_run(server.display);
	wlr_log(WLR_INFO, "engineos-shell shutdown outputs=%u keyboards=%u pointers=%u views=%u",
		server.output_count, server.keyboard_count, server.pointer_count, server.view_count);
	destroy_server(&server);
	return 0;
}
