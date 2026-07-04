#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <png.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <drm_fourcc.h>
#include <jpeglib.h>
#include <wayland-server-core.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_control_v1.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

#ifndef XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION
#define XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION 4
#endif
#ifndef XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION
#define XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION 5
#endif
#ifndef XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION
#define XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION 6
#endif

enum engineos_shell_mode {
	ENGINEOS_SHELL_AUTO,
	ENGINEOS_SHELL_HEADLESS,
	ENGINEOS_SHELL_NESTED,
	ENGINEOS_SHELL_TTY,
};

enum engineos_surface_role {
	ENGINEOS_SURFACE_UNKNOWN,
	ENGINEOS_SURFACE_TERMINAL,
	ENGINEOS_SURFACE_TERMINAL_SECONDARY,
	ENGINEOS_SURFACE_CUBE,
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
	ENGINEOS_BOOTSTRAP_LAUNCHPAD,
};

struct engineos_view_geometry {
	int x;
	int y;
	int width;
	int height;
	bool fullscreen;
	const char *layout;
};

struct engineos_layout_request {
	bool pane;
	bool output;
	bool fullscreen;
	int pane_left;
	int pane_top;
	int pane_width;
	int pane_height;
	int window_width;
	int window_height;
	char source[32];
};

struct engineos_preview_bounds {
	bool set;
	int x;
	int y;
	int width;
	int height;
	int window_width;
	int window_height;
};

struct engineos_preview_surface {
	struct wlr_scene_buffer *scene_buffer;
	struct wlr_buffer *buffer;
	char *path;
	char *owner;
	char *mode;
	int x;
	int y;
	int width;
	int height;
	int image_width;
	int image_height;
	int opacity_percent;
};

struct engineos_shell_server {
	struct wl_display *display;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_seat *seat;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_data_device_manager *data_device_mgr;
	struct wlr_data_control_manager_v1 *data_control_mgr;
	struct wlr_primary_selection_v1_device_manager *primary_selection_mgr;
	struct wlr_output_layout *output_layout;
	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
	struct wlr_pointer_constraints_v1 *pointer_constraints;
	struct wlr_pointer_constraint_v1 *active_pointer_constraint;
	struct wlr_scene *scene;
	struct wl_list outputs;
	struct wl_list views;
	struct wl_list keyboards;
	struct wl_list pointers;
	struct wl_list launches;
	struct wl_listener new_output;
	struct wl_listener new_input;
	struct wl_listener new_xdg_surface;
	struct wl_listener new_xdg_popup;
	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;
	struct wl_listener request_cursor;
	struct wl_listener request_set_selection;
	struct wl_listener request_set_primary_selection;
	struct wl_listener new_relative_pointer;
	struct wl_listener new_pointer_constraint;
	struct wl_listener active_pointer_constraint_destroy;
	struct engineos_shell_view *focused_view;
	struct engineos_shell_view *moving_view;
	double move_grab_x;
	double move_grab_y;
	const char *mode_name;
	const char *startup_cmd;
	const char *terminal_cmd;
	const char *terminal_secondary_cmd;
	const char *cube_cmd;
	const char *engine_cmd;
	char *state_dir;
	char *state_file;
	char *preview_socket_path;
	struct wl_event_source *preview_socket_source;
	int preview_socket_fd;
	struct engineos_preview_surface preview;
	struct engineos_preview_surface wallpaper;
	enum engineos_bootstrap_mode bootstrap_mode;
	enum engineos_input_mode input_mode;
	enum engineos_surface_role active_slot;
	enum engineos_surface_role pending_slot;
	bool game_capture;
	bool cursor_hidden;
	int smoke_ms;
	unsigned int output_count;
	unsigned int keyboard_count;
	unsigned int pointer_count;
	unsigned int view_count;
};

struct engineos_shell_launch {
	struct wl_list link;
	pid_t pid;
	enum engineos_surface_role role;
	char *label;
	char *command;
	bool mapped;
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

struct engineos_shell_popup {
	struct wlr_xdg_popup *xdg_popup;
	struct wl_listener commit;
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
	struct wl_listener request_maximize;
	struct wl_listener request_fullscreen;
	struct wl_listener request_minimize;
	struct wl_listener request_move;
	struct wl_listener request_resize;
	struct wl_listener request_show_window_menu;
	enum engineos_surface_role role;
	int x;
	int y;
	int width;
	int height;
	int saved_x;
	int saved_y;
	int saved_width;
	int saved_height;
	bool has_floating_geometry;
	bool mapped;
	bool fullscreen;
	bool maximized;
	bool minimized;
};

struct engineos_pixel_buffer {
	struct wlr_buffer base;
	unsigned char *data;
	size_t stride;
	uint32_t format;
};

static const char *view_title(struct engineos_shell_view *view);
static const char *view_app_id(struct engineos_shell_view *view);
static const char *surface_role_name(enum engineos_surface_role role);
static bool is_launchpad_role(enum engineos_surface_role role);
static bool is_terminal_role(enum engineos_surface_role role);
static char *join_state_path(const char *dir, const char *name);
static bool mkdir_p(const char *path, mode_t mode);
static bool compute_view_geometry(struct engineos_shell_view *view,
	struct engineos_view_geometry *geometry);
static bool is_persistent_panel_geometry(enum engineos_surface_role role,
	const struct engineos_view_geometry *geometry);
static bool is_managed_floating_view(struct engineos_shell_view *view);
static void apply_view_layout(struct engineos_shell_view *view);
static void schedule_outputs(struct engineos_shell_server *server);
static void set_toplevel_suspended(struct wlr_xdg_toplevel *toplevel,
	bool suspended);
static void clear_keyboard_focus(struct engineos_shell_server *server);
static void clear_pointer_focus(struct engineos_shell_server *server,
	const char *reason);
static bool should_lock_game_cursor(struct engineos_shell_server *server);
static void sync_cursor_image(struct engineos_shell_server *server,
	const char *reason);
static bool confine_cursor_to_view(struct engineos_shell_server *server,
	struct engineos_shell_view *view, const char *reason);
static void sync_pointer_constraint(struct engineos_shell_server *server,
	const char *reason);
static void set_view_activated(struct engineos_shell_view *view, bool activated);
static void focus_view(struct engineos_shell_view *view);
static void set_active_slot(struct engineos_shell_server *server,
	enum engineos_surface_role role, const char *reason);
static void apply_launchpad_visibility(struct engineos_shell_server *server,
	const char *reason);
static void hide_image_preview(struct engineos_shell_server *server,
	const char *reason);
static void launch_or_activate_slot(struct engineos_shell_server *server,
	enum engineos_surface_role role, const char *reason);
static void write_shell_state(struct engineos_shell_server *server,
	const char *reason);
static bool init_preview_ipc(struct engineos_shell_server *server);
static void close_preview_ipc(struct engineos_shell_server *server,
	bool unlink_socket, bool free_path);

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
		"          [--terminal CMD] [--terminal-secondary CMD] [--cube CMD] [--engine CMD]\n"
		"          [--bootstrap MODE]\n"
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
		"  --terminal-secondary CMD  command launched by Alt+4\n"
		"  --cube CMD      command launched by Alt+2\n"
		"  --engine CMD    command launched by Alt+G\n"
		"  --bootstrap MODE  start none, terminal, engine, or launchpad after shell startup\n"
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
	case ENGINEOS_BOOTSTRAP_LAUNCHPAD:
		return "launchpad";
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
	if (strcmp(value, "launchpad") == 0 || strcmp(value, "all") == 0) {
		*mode = ENGINEOS_BOOTSTRAP_LAUNCHPAD;
		return true;
	}
	return false;
}

static void remove_listener_if_linked(struct wl_listener *listener) {
	if (listener->link.prev != NULL && listener->link.next != NULL) {
		wl_list_remove(&listener->link);
		listener->link.prev = NULL;
		listener->link.next = NULL;
	}
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

static int relayout_from_signal(int signal_number, void *data) {
	struct engineos_shell_server *server = data;
	wlr_log(WLR_INFO, "layout sync requested signal=%d", signal_number);
	close_preview_ipc(server, true, true);
	if (init_preview_ipc(server)) {
		wlr_log(WLR_INFO, "preview ipc refreshed reason=layout-sync-signal");
	} else {
		wlr_log(WLR_ERROR,
			"preview ipc refresh failed reason=layout-sync-signal");
	}
	apply_launchpad_visibility(server, "layout-sync-signal");
	write_shell_state(server, "layout-sync-signal");
	return 0;
}

static int terminate_from_smoke_timer(void *data) {
	struct engineos_shell_server *server = data;
	wlr_log(WLR_INFO, "smoke timer elapsed after %d ms", server->smoke_ms);
	wl_display_terminate(server->display);
	return 0;
}

static int64_t monotonic_msec(void) {
	struct timespec now = {0};
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool wait_for_initial_outputs(struct engineos_shell_server *server,
		int timeout_ms) {
	if (server->output_count > 0) {
		return true;
	}

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server->display);
	int64_t deadline = monotonic_msec() + timeout_ms;
	wlr_log(WLR_INFO, "waiting for initial outputs timeout_ms=%d",
		timeout_ms);
	while (server->output_count == 0) {
		int64_t remaining = deadline - monotonic_msec();
		if (remaining <= 0) {
			wlr_log(WLR_ERROR,
				"no outputs available after backend start timeout_ms=%d",
				timeout_ms);
			return false;
		}
		int dispatch_timeout = remaining < 50 ? (int)remaining : 50;
		if (wl_event_loop_dispatch(event_loop, dispatch_timeout) < 0) {
			wlr_log(WLR_ERROR,
				"event dispatch failed while waiting for outputs");
			return false;
		}
	}

	wlr_log(WLR_INFO, "initial outputs ready count=%u",
		server->output_count);
	return true;
}

static struct engineos_shell_launch *find_launch_by_pid(
		struct engineos_shell_server *server, pid_t pid) {
	struct engineos_shell_launch *launch;
	wl_list_for_each(launch, &server->launches, link) {
		if (launch->pid == pid) {
			return launch;
		}
	}
	return NULL;
}

static void mark_launch_role_mapped(struct engineos_shell_server *server,
		enum engineos_surface_role role) {
	struct engineos_shell_launch *launch;
	wl_list_for_each_reverse(launch, &server->launches, link) {
		if (launch->role == role && !launch->mapped) {
			launch->mapped = true;
			wlr_log(WLR_INFO,
				"launch action mapped label=%s role=%s pid=%ld",
				launch->label, surface_role_name(launch->role),
				(long)launch->pid);
			write_shell_state(server, "launch-mapped");
			return;
		}
	}
}

static void free_launch(struct engineos_shell_launch *launch) {
	if (launch == NULL) {
		return;
	}
	wl_list_remove(&launch->link);
	free(launch->label);
	free(launch->command);
	free(launch);
}

static const char *wait_status_name(int status) {
	if (WIFEXITED(status)) {
		return "exited";
	}
	if (WIFSIGNALED(status)) {
		return "signaled";
	}
	return "unknown";
}

static int wait_status_code(int status) {
	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}
	if (WIFSIGNALED(status)) {
		return WTERMSIG(status);
	}
	return -1;
}

static int reap_child_processes(int signal_number, void *data) {
	(void)signal_number;
	struct engineos_shell_server *server = data;
	int status = 0;
	pid_t pid;

	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		struct engineos_shell_launch *launch = find_launch_by_pid(server, pid);
		if (launch == NULL) {
			wlr_log(WLR_INFO,
				"launch action exit label=unknown role=unknown pid=%ld status=%s code=%d mapped=unknown",
				(long)pid, wait_status_name(status),
				wait_status_code(status));
			continue;
		}

		wlr_log(WLR_INFO,
			"launch action exit label=%s role=%s pid=%ld status=%s code=%d mapped=%s command=%s",
			launch->label, surface_role_name(launch->role), (long)pid,
			wait_status_name(status), wait_status_code(status),
			launch->mapped ? "true" : "false", launch->command);

		if (is_launchpad_role(launch->role) && !launch->mapped) {
			if (server->pending_slot == launch->role) {
				server->pending_slot = ENGINEOS_SURFACE_UNKNOWN;
			}
			wlr_log(WLR_INFO,
				"launchpad slot unavailable role=%s reason=process-exited-before-map status=%s code=%d",
				surface_role_name(launch->role), wait_status_name(status),
				wait_status_code(status));
			apply_launchpad_visibility(server, "launch-exited-before-map");
		}

		write_shell_state(server, "launch-exit");
		free_launch(launch);
	}

	if (pid < 0 && errno != ECHILD) {
		wlr_log(WLR_ERROR, "waitpid failed while reaping children: %s",
			strerror(errno));
	}

	return 0;
}

static void spawn_command(struct engineos_shell_server *server, const char *label,
		enum engineos_surface_role role, const char *cmd) {
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

	struct engineos_shell_launch *launch = calloc(1, sizeof(*launch));
	if (launch == NULL) {
		wlr_log(WLR_ERROR,
			"launch action untracked label=%s role=%s pid=%ld reason=oom command=%s",
			label, surface_role_name(role), (long)pid, cmd);
		return;
	}
	launch->pid = pid;
	launch->role = role;
	launch->label = strdup(label);
	launch->command = strdup(cmd);
	if (launch->label == NULL || launch->command == NULL) {
		wlr_log(WLR_ERROR,
			"launch action untracked label=%s role=%s pid=%ld reason=oom command=%s",
			label, surface_role_name(role), (long)pid, cmd);
		free(launch->label);
		free(launch->command);
		free(launch);
		return;
	}
	wl_list_insert(&server->launches, &launch->link);

	wlr_log(WLR_INFO,
		"launch action label=%s role=%s pid=%ld command=%s",
		label, surface_role_name(role), (long)pid, cmd);
	write_shell_state(server, "launch-spawned");
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
	case ENGINEOS_SURFACE_TERMINAL_SECONDARY:
		return "terminal-secondary";
	case ENGINEOS_SURFACE_CUBE:
		return "cube";
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

static const char *pointer_constraint_type_name(
		enum wlr_pointer_constraint_v1_type type) {
	switch (type) {
	case WLR_POINTER_CONSTRAINT_V1_LOCKED:
		return "locked";
	case WLR_POINTER_CONSTRAINT_V1_CONFINED:
		return "confined";
	default:
		return "unknown";
	}
}

static bool is_launchpad_role(enum engineos_surface_role role) {
	return role == ENGINEOS_SURFACE_TERMINAL ||
		role == ENGINEOS_SURFACE_TERMINAL_SECONDARY ||
		role == ENGINEOS_SURFACE_CUBE ||
		role == ENGINEOS_SURFACE_ENGINE;
}

static bool is_terminal_role(enum engineos_surface_role role) {
	return role == ENGINEOS_SURFACE_TERMINAL ||
		role == ENGINEOS_SURFACE_TERMINAL_SECONDARY;
}

static const char *slot_command(struct engineos_shell_server *server,
		enum engineos_surface_role role) {
	switch (role) {
	case ENGINEOS_SURFACE_TERMINAL:
		return server->terminal_cmd;
	case ENGINEOS_SURFACE_TERMINAL_SECONDARY:
		return server->terminal_secondary_cmd;
	case ENGINEOS_SURFACE_CUBE:
		return server->cube_cmd;
	case ENGINEOS_SURFACE_ENGINE:
		return server->engine_cmd;
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		return NULL;
	}
}

static void primary_output_size(struct engineos_shell_server *server,
		int *width, int *height) {
	*width = 1280;
	*height = 720;

	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		wlr_output_effective_resolution(output->output, width, height);
		if (*width <= 0) {
			*width = 1280;
		}
		if (*height <= 0) {
			*height = 720;
		}
		return;
	}
}

static void output_geometry_for_role(struct engineos_shell_server *server,
		enum engineos_surface_role role, int *x, int *y, int *width, int *height) {
	*x = 0;
	*y = 0;
	*width = 1280;
	*height = 720;

	struct engineos_shell_output *selected = NULL;
	int selected_x = 0;
	int selected_y = 0;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		struct wlr_output_layout_output *layout_output =
			wlr_output_layout_get(server->output_layout, output->output);
		int candidate_x = layout_output != NULL ? layout_output->x : 0;
		int candidate_y = layout_output != NULL ? layout_output->y : 0;

		if (selected == NULL) {
			selected = output;
			selected_x = candidate_x;
			selected_y = candidate_y;
			continue;
		}

		if (role == ENGINEOS_SURFACE_TERMINAL_SECONDARY) {
			if (candidate_x > selected_x) {
				selected = output;
				selected_x = candidate_x;
				selected_y = candidate_y;
			}
		} else if (candidate_x < selected_x) {
			selected = output;
			selected_x = candidate_x;
			selected_y = candidate_y;
		}
	}

	if (selected == NULL) {
		primary_output_size(server, width, height);
		return;
	}

	*x = selected_x;
	*y = selected_y;
	wlr_output_effective_resolution(selected->output, width, height);
	if (*width <= 0) {
		*width = 1280;
	}
	if (*height <= 0) {
		*height = 720;
	}
}

static bool is_managed_floating_view(struct engineos_shell_view *view) {
	return view != NULL && !is_launchpad_role(view->role);
}

static void ensure_floating_geometry(struct engineos_shell_view *view) {
	if (view == NULL || view->has_floating_geometry) {
		return;
	}

	int output_x = 0;
	int output_y = 0;
	int output_width = 1280;
	int output_height = 720;
	output_geometry_for_role(view->server, ENGINEOS_SURFACE_TERMINAL,
		&output_x, &output_y, &output_width, &output_height);

	int width = (output_width * 3) / 4;
	int height = (output_height * 3) / 4;
	if (width > 1200) {
		width = 1200;
	}
	if (height > 820) {
		height = 820;
	}
	if (output_width >= 720 && width < 640) {
		width = 640;
	}
	if (output_height >= 560 && height < 480) {
		height = 480;
	}
	if (width > output_width) {
		width = output_width;
	}
	if (height > output_height) {
		height = output_height;
	}

	int margin = output_width > 160 && output_height > 120 ? 40 : 0;
	int available_x = output_width - width - margin;
	int available_y = output_height - height - margin;
	unsigned int index = view->server->view_count > 0 ?
		view->server->view_count - 1 : 0;
	int cascade = (int)(index * 32);

	view->x = output_x + margin +
		(available_x > 0 ? cascade % available_x : 0);
	view->y = output_y + margin +
		(available_y > 0 ? cascade % available_y : 0);
	view->width = width;
	view->height = height;
	view->saved_x = view->x;
	view->saved_y = view->y;
	view->saved_width = view->width;
	view->saved_height = view->height;
	view->has_floating_geometry = true;
}

static void floating_output_geometry(struct engineos_shell_view *view,
		int *x, int *y, int *width, int *height) {
	output_geometry_for_role(view->server, ENGINEOS_SURFACE_TERMINAL,
		x, y, width, height);
}

static void save_floating_geometry(struct engineos_shell_view *view) {
	if (view == NULL || !view->has_floating_geometry) {
		return;
	}
	if (view->maximized || view->fullscreen) {
		return;
	}
	view->saved_x = view->x;
	view->saved_y = view->y;
	view->saved_width = view->width;
	view->saved_height = view->height;
}

static void set_floating_maximized(struct engineos_shell_view *view,
		bool maximized, const char *reason) {
	if (!is_managed_floating_view(view)) {
		return;
	}
	ensure_floating_geometry(view);
	if (view->maximized == maximized) {
		apply_view_layout(view);
		return;
	}

	if (maximized) {
		save_floating_geometry(view);
		int x = 0;
		int y = 0;
		int width = 0;
		int height = 0;
		floating_output_geometry(view, &x, &y, &width, &height);
		view->x = x;
		view->y = y;
		view->width = width;
		view->height = height;
		view->maximized = true;
	} else {
		view->maximized = false;
		view->x = view->saved_x;
		view->y = view->saved_y;
		view->width = view->saved_width;
		view->height = view->saved_height;
	}

	if (view->minimized) {
		view->minimized = false;
	}
	wlr_log(WLR_INFO,
		"window maximize role=%s maximized=%s reason=%s title=%s app_id=%s",
		surface_role_name(view->role), view->maximized ? "true" : "false",
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
	apply_view_layout(view);
	write_shell_state(view->server, reason != NULL ? reason : "window-maximize");
}

static void set_view_minimized(struct engineos_shell_view *view,
		bool minimized, const char *reason) {
	if (view == NULL || !view->mapped) {
		return;
	}
	if (is_launchpad_role(view->role) && minimized) {
		wlr_log(WLR_INFO,
			"window minimize ignored role=%s reason=launchpad-slot title=%s app_id=%s",
			surface_role_name(view->role), view_title(view), view_app_id(view));
		return;
	}
	view->minimized = minimized;
	wlr_scene_node_set_enabled(&view->scene_tree->node, !minimized);
	if (view->xdg_surface != NULL && view->xdg_surface->toplevel != NULL) {
		set_toplevel_suspended(view->xdg_surface->toplevel, minimized);
	}
	if (minimized && view->server->focused_view == view) {
		view->server->focused_view = NULL;
		set_view_activated(view, false);
		wlr_seat_keyboard_notify_clear_focus(view->server->seat);
	}
	wlr_log(WLR_INFO,
		"window minimize role=%s minimized=%s reason=%s title=%s app_id=%s",
		surface_role_name(view->role), minimized ? "true" : "false",
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
	schedule_outputs(view->server);
	write_shell_state(view->server, reason != NULL ? reason : "window-minimize");
}

static bool parse_nonnegative_int(const char *value, int *out) {
	if (value == NULL || value[0] == '\0') {
		return false;
	}

	errno = 0;
	char *end = NULL;
	long parsed = strtol(value, &end, 10);
	if (errno != 0 || end == value) {
		return false;
	}
	while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') {
		end++;
	}
	if (*end != '\0' || parsed < 0 || parsed > INT_MAX) {
		return false;
	}

	*out = (int)parsed;
	return true;
}

static bool read_layout_request(struct engineos_shell_server *server,
		enum engineos_surface_role role,
		struct engineos_layout_request *request) {
	memset(request, 0, sizeof(*request));
	snprintf(request->source, sizeof(request->source), "%s", "unknown");

	if (server->state_dir == NULL) {
		return false;
	}

	char request_name[96];
	snprintf(request_name, sizeof(request_name), "launch-bounds/%s.env",
		surface_role_name(role));
	char *path = join_state_path(server->state_dir, request_name);
	if (path == NULL) {
		return false;
	}

	FILE *file = fopen(path, "r");
	free(path);
	if (file == NULL) {
		return false;
	}

	bool role_matches = true;
	char line[256];
	while (fgets(line, sizeof(line), file) != NULL) {
		char key[64] = {0};
		char value[128] = {0};
		if (sscanf(line, " %63[^=]=%127[^\n]", key, value) != 2) {
			continue;
		}

		if (strcmp(key, "role") == 0) {
			role_matches = strcmp(value, surface_role_name(role)) == 0;
		} else if (strcmp(key, "mode") == 0) {
			request->pane = strcmp(value, "pane") == 0;
			request->output = strcmp(value, "output") == 0;
			request->fullscreen = strcmp(value, "fullscreen") == 0;
		} else if (strcmp(key, "source") == 0) {
			snprintf(request->source, sizeof(request->source), "%.31s", value);
		} else if (strcmp(key, "pane_left") == 0) {
			parse_nonnegative_int(value, &request->pane_left);
		} else if (strcmp(key, "pane_top") == 0) {
			parse_nonnegative_int(value, &request->pane_top);
		} else if (strcmp(key, "pane_width") == 0) {
			parse_nonnegative_int(value, &request->pane_width);
		} else if (strcmp(key, "pane_height") == 0) {
			parse_nonnegative_int(value, &request->pane_height);
		} else if (strcmp(key, "window_width") == 0) {
			parse_nonnegative_int(value, &request->window_width);
		} else if (strcmp(key, "window_height") == 0) {
			parse_nonnegative_int(value, &request->window_height);
		}
	}
	fclose(file);

	if (!role_matches) {
		return false;
	}
	if (request->fullscreen) {
		return true;
	}
	if (request->output) {
		return true;
	}
	return request->pane &&
		request->pane_width > 0 &&
		request->pane_height > 0 &&
		request->window_width > 0 &&
		request->window_height > 0;
}

static bool apply_pane_geometry(
		const struct engineos_layout_request *request,
		const struct engineos_view_geometry *output_geometry,
		struct engineos_view_geometry *geometry) {
	long x_offset = ((long)output_geometry->width * request->pane_left) /
		request->window_width;
	long y_offset = ((long)output_geometry->height * request->pane_top) /
		request->window_height;
	long width = ((long)output_geometry->width * request->pane_width +
		request->window_width - 1) / request->window_width;
	long height = ((long)output_geometry->height * request->pane_height +
		request->window_height - 1) / request->window_height;

	if (width <= 0 || height <= 0 ||
			x_offset < 0 || y_offset < 0 ||
			x_offset > INT_MAX || y_offset > INT_MAX ||
			width > INT_MAX || height > INT_MAX) {
		return false;
	}

	geometry->x = output_geometry->x + (int)x_offset;
	geometry->y = output_geometry->y + (int)y_offset;
	geometry->width = (int)width;
	geometry->height = (int)height;

	int output_right = output_geometry->x + output_geometry->width;
	int output_bottom = output_geometry->y + output_geometry->height;
	if (geometry->x < output_geometry->x) {
		geometry->x = output_geometry->x;
	}
	if (geometry->y < output_geometry->y) {
		geometry->y = output_geometry->y;
	}
	if (geometry->x + geometry->width > output_right) {
		geometry->width = output_right - geometry->x;
	}
	if (geometry->y + geometry->height > output_bottom) {
		geometry->height = output_bottom - geometry->y;
	}
	if (geometry->width <= 0 || geometry->height <= 0) {
		return false;
	}

	geometry->fullscreen = false;
	geometry->layout = "tmux-pane";
	return true;
}

static bool compute_view_geometry(struct engineos_shell_view *view,
		struct engineos_view_geometry *geometry) {
	geometry->x = 40;
	geometry->y = 40;
	geometry->width = 0;
	geometry->height = 0;
	geometry->fullscreen = view->fullscreen;
	geometry->layout = "floating";

	if (!is_launchpad_role(view->role)) {
		ensure_floating_geometry(view);
		if (view->fullscreen) {
			floating_output_geometry(view, &geometry->x, &geometry->y,
				&geometry->width, &geometry->height);
			geometry->fullscreen = true;
			geometry->layout = "fullscreen";
		} else {
			geometry->x = view->x;
			geometry->y = view->y;
			geometry->width = view->width;
			geometry->height = view->height;
			geometry->fullscreen = false;
			geometry->layout = view->maximized ? "maximized" : "floating";
		}
		return true;
	}

	output_geometry_for_role(view->server, view->role, &geometry->x,
		&geometry->y, &geometry->width, &geometry->height);
	geometry->layout = "output";

	if (view->role != ENGINEOS_SURFACE_CUBE &&
			view->role != ENGINEOS_SURFACE_ENGINE) {
		return true;
	}

	struct engineos_layout_request request;
	bool has_request = read_layout_request(view->server, view->role, &request);
	if (has_request && request.fullscreen) {
		geometry->fullscreen = true;
		geometry->layout = "fullscreen-request";
		return true;
	}
	if (has_request && request.output) {
		geometry->layout = "output-request";
		return true;
	}
	if (geometry->fullscreen) {
		geometry->layout = "fullscreen";
		return true;
	}
	if (has_request && request.pane) {
		struct engineos_view_geometry output_geometry = *geometry;
		if (apply_pane_geometry(&request, &output_geometry, geometry)) {
			return true;
		}
	}

	return true;
}

static bool is_persistent_panel_geometry(enum engineos_surface_role role,
		const struct engineos_view_geometry *geometry) {
	if (geometry == NULL || geometry->fullscreen ||
			geometry->layout == NULL ||
			strcmp(geometry->layout, "tmux-pane") != 0) {
		return false;
	}
	return role == ENGINEOS_SURFACE_CUBE || role == ENGINEOS_SURFACE_ENGINE;
}

static bool view_geometry_visible(struct engineos_shell_server *server,
		struct engineos_shell_view *view,
		const struct engineos_view_geometry *geometry) {
	if (view == NULL || !view->mapped) {
		return false;
	}
	if (view->minimized) {
		return false;
	}
	if (server->active_slot == view->role || is_terminal_role(view->role)) {
		return true;
	}
	return is_persistent_panel_geometry(view->role, geometry);
}

static struct engineos_shell_view *find_mapped_role(
		struct engineos_shell_server *server,
		enum engineos_surface_role role) {
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (view->mapped && view->role == role) {
			return view;
		}
	}
	return NULL;
}

static char *join_state_path(const char *dir, const char *name) {
	size_t dir_len = strlen(dir);
	size_t name_len = strlen(name);
	bool slash = dir_len > 0 && dir[dir_len - 1] == '/';
	size_t len = dir_len + (slash ? 0 : 1) + name_len + 1;
	char *path = malloc(len);
	if (path == NULL) {
		return NULL;
	}
	snprintf(path, len, "%s%s%s", dir, slash ? "" : "/", name);
	return path;
}

static bool init_shell_state_path(struct engineos_shell_server *server) {
	const char *state_dir = getenv("ENGINEOS_STATE_DIR");
	if (state_dir != NULL && state_dir[0] != '\0') {
		server->state_dir = strdup(state_dir);
	} else {
		const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
		if (runtime_dir != NULL && runtime_dir[0] != '\0') {
			server->state_dir = join_state_path(runtime_dir, "engineos");
		} else {
			server->state_dir = strdup("/tmp/engineos");
		}
	}
	if (server->state_dir == NULL) {
		return false;
	}

	server->state_file = join_state_path(server->state_dir, "shell-state.json");
	return server->state_file != NULL;
}

static void json_write_string(FILE *file, const char *value) {
	fputc('"', file);
	if (value != NULL) {
		for (const unsigned char *p = (const unsigned char *)value; *p != '\0'; p++) {
			switch (*p) {
			case '\\':
				fputs("\\\\", file);
				break;
			case '"':
				fputs("\\\"", file);
				break;
			case '\n':
				fputs("\\n", file);
				break;
			case '\r':
				fputs("\\r", file);
				break;
			case '\t':
				fputs("\\t", file);
				break;
			default:
				if (*p < 0x20) {
					fprintf(file, "\\u%04x", *p);
				} else {
					fputc(*p, file);
				}
				break;
			}
		}
	}
	fputc('"', file);
}

static void write_slot_state(FILE *file, struct engineos_shell_server *server,
		enum engineos_surface_role role) {
	struct engineos_shell_view *view = find_mapped_role(server, role);
	bool mapped = view != NULL;
	struct engineos_view_geometry geometry = {0};
	if (mapped) {
		compute_view_geometry(view, &geometry);
	}
	bool visible = mapped && view_geometry_visible(server, view, &geometry);

	fprintf(file, "    \"%s\": {", surface_role_name(role));
	fprintf(file, "\"mapped\": %s", mapped ? "true" : "false");
	fprintf(file, ", \"visible\": %s", visible ? "true" : "false");
	fprintf(file, ", \"layout\": ");
	json_write_string(file, mapped ? geometry.layout : "");
	fprintf(file, ", \"fullscreen\": %s", mapped && geometry.fullscreen ? "true" : "false");
	fprintf(file, ", \"x\": %d", mapped ? geometry.x : 0);
	fprintf(file, ", \"y\": %d", mapped ? geometry.y : 0);
	fprintf(file, ", \"width\": %d", mapped ? geometry.width : 0);
	fprintf(file, ", \"height\": %d", mapped ? geometry.height : 0);
	fprintf(file, ", \"title\": ");
	json_write_string(file, mapped ? view_title(view) : "");
	fprintf(file, ", \"app_id\": ");
	json_write_string(file, mapped ? view_app_id(view) : "");
	fprintf(file, "}");
}

static bool mkdir_p(const char *path, mode_t mode) {
	if (path == NULL || path[0] == '\0') {
		return false;
	}

	char *copy = strdup(path);
	if (copy == NULL) {
		return false;
	}

	for (char *p = copy + 1; *p != '\0'; p++) {
		if (*p != '/') {
			continue;
		}
		*p = '\0';
		if (mkdir(copy, mode) < 0 && errno != EEXIST) {
			free(copy);
			return false;
		}
		*p = '/';
	}

	bool ok = mkdir(copy, mode) == 0 || errno == EEXIST;
	free(copy);
	return ok;
}

static void pixel_buffer_destroy(struct wlr_buffer *wlr_buffer) {
	struct engineos_pixel_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	free(buffer->data);
	wlr_buffer_finish(&buffer->base);
	free(buffer);
}

static bool pixel_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
		uint32_t flags, void **data, uint32_t *format, size_t *stride) {
	struct engineos_pixel_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	if ((flags & WLR_BUFFER_DATA_PTR_ACCESS_READ) == 0) {
		return false;
	}
	*data = buffer->data;
	*format = buffer->format;
	*stride = buffer->stride;
	return true;
}

static void pixel_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer) {
	(void)wlr_buffer;
}

static const struct wlr_buffer_impl pixel_buffer_impl = {
	.destroy = pixel_buffer_destroy,
	.begin_data_ptr_access = pixel_buffer_begin_data_ptr_access,
	.end_data_ptr_access = pixel_buffer_end_data_ptr_access,
};

static struct wlr_buffer *create_pixel_buffer_from_rgba(
		const unsigned char *source, int width, int height, size_t source_stride) {
	struct engineos_pixel_buffer *buffer = calloc(1, sizeof(*buffer));
	if (buffer == NULL) {
		return NULL;
	}
	buffer->format = DRM_FORMAT_ABGR8888;
	buffer->stride = (size_t)width * 4;
	size_t data_size = buffer->stride * (size_t)height;
	buffer->data = malloc(data_size);
	if (buffer->data == NULL) {
		free(buffer);
		return NULL;
	}

	for (int y = 0; y < height; y++) {
		const unsigned char *src = source + (size_t)y * source_stride;
		unsigned char *dst = buffer->data + (size_t)y * buffer->stride;
		memcpy(dst, src, buffer->stride);
	}

	wlr_buffer_init(&buffer->base, &pixel_buffer_impl, width, height);
	return &buffer->base;
}

static bool image_dimensions_allowed(int width, int height,
		char *error, size_t error_size) {
	if (width <= 0 || height <= 0) {
		snprintf(error, error_size, "image dimensions are invalid");
		return false;
	}
	if (width > 4096 || height > 4096 ||
			(int64_t)width * (int64_t)height > 16777216) {
		snprintf(error, error_size, "image dimensions too large: %dx%d",
			width, height);
		return false;
	}
	return true;
}

static struct wlr_buffer *decode_png_preview(FILE *file,
		int *image_width, int *image_height, char *error, size_t error_size) {
	unsigned char signature[8];
	if (fread(signature, 1, sizeof(signature), file) != sizeof(signature) ||
			png_sig_cmp(signature, 0, sizeof(signature)) != 0) {
		snprintf(error, error_size, "not a PNG image");
		return NULL;
	}

	png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING,
		NULL, NULL, NULL);
	if (png == NULL) {
		snprintf(error, error_size, "failed to initialize PNG decoder");
		return NULL;
	}
	png_infop info = png_create_info_struct(png);
	if (info == NULL) {
		png_destroy_read_struct(&png, NULL, NULL);
		snprintf(error, error_size, "failed to initialize PNG info");
		return NULL;
	}
	if (setjmp(png_jmpbuf(png))) {
		png_destroy_read_struct(&png, &info, NULL);
		snprintf(error, error_size, "PNG decode failed");
		return NULL;
	}

	png_init_io(png, file);
	png_set_sig_bytes(png, sizeof(signature));
	png_read_info(png, info);

	png_uint_32 width = png_get_image_width(png, info);
	png_uint_32 height = png_get_image_height(png, info);
	int bit_depth = png_get_bit_depth(png, info);
	int color_type = png_get_color_type(png, info);
	if (width > INT_MAX || height > INT_MAX ||
			!image_dimensions_allowed((int)width, (int)height,
				error, error_size)) {
		png_destroy_read_struct(&png, &info, NULL);
		return NULL;
	}

	if (bit_depth == 16) {
		png_set_strip_16(png);
	}
	if (color_type == PNG_COLOR_TYPE_PALETTE) {
		png_set_palette_to_rgb(png);
	}
	if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) {
		png_set_expand_gray_1_2_4_to_8(png);
	}
	if (png_get_valid(png, info, PNG_INFO_tRNS)) {
		png_set_tRNS_to_alpha(png);
	}
	if (color_type == PNG_COLOR_TYPE_GRAY ||
			color_type == PNG_COLOR_TYPE_GRAY_ALPHA) {
		png_set_gray_to_rgb(png);
	}
	if ((color_type & PNG_COLOR_MASK_ALPHA) == 0 &&
			!png_get_valid(png, info, PNG_INFO_tRNS)) {
		png_set_filler(png, 0xff, PNG_FILLER_AFTER);
	}

	png_read_update_info(png, info);
	size_t stride = png_get_rowbytes(png, info);
	if (stride != (size_t)width * 4) {
		png_destroy_read_struct(&png, &info, NULL);
		snprintf(error, error_size, "PNG decoder did not produce RGBA pixels");
		return NULL;
	}

	unsigned char *pixels = malloc(stride * (size_t)height);
	png_bytep *rows = calloc((size_t)height, sizeof(*rows));
	if (pixels == NULL || rows == NULL) {
		free(pixels);
		free(rows);
		png_destroy_read_struct(&png, &info, NULL);
		snprintf(error, error_size, "failed to allocate PNG pixels");
		return NULL;
	}
	for (png_uint_32 y = 0; y < height; y++) {
		rows[y] = pixels + (size_t)y * stride;
	}
	png_read_image(png, rows);
	png_read_end(png, NULL);
	free(rows);
	png_destroy_read_struct(&png, &info, NULL);

	struct wlr_buffer *buffer =
		create_pixel_buffer_from_rgba(pixels, (int)width, (int)height, stride);
	free(pixels);
	if (buffer == NULL) {
		snprintf(error, error_size, "failed to allocate image buffer");
		return NULL;
	}
	*image_width = (int)width;
	*image_height = (int)height;
	return buffer;
}

struct engineos_jpeg_error {
	struct jpeg_error_mgr pub;
	jmp_buf jump;
};

static void jpeg_error_exit(j_common_ptr cinfo) {
	struct engineos_jpeg_error *error =
		(struct engineos_jpeg_error *)cinfo->err;
	longjmp(error->jump, 1);
}

static struct wlr_buffer *decode_jpeg_preview(FILE *file,
		int *image_width, int *image_height, char *error, size_t error_size) {
	struct jpeg_decompress_struct cinfo = {0};
	struct engineos_jpeg_error jpeg_error = {0};
	cinfo.err = jpeg_std_error(&jpeg_error.pub);
	jpeg_error.pub.error_exit = jpeg_error_exit;
	if (setjmp(jpeg_error.jump)) {
		jpeg_destroy_decompress(&cinfo);
		snprintf(error, error_size, "JPEG decode failed");
		return NULL;
	}

	jpeg_create_decompress(&cinfo);
	jpeg_stdio_src(&cinfo, file);
	jpeg_read_header(&cinfo, TRUE);
	cinfo.out_color_space = JCS_RGB;
	jpeg_start_decompress(&cinfo);

	if (cinfo.output_width > INT_MAX || cinfo.output_height > INT_MAX ||
			!image_dimensions_allowed((int)cinfo.output_width,
				(int)cinfo.output_height, error, error_size)) {
		jpeg_destroy_decompress(&cinfo);
		return NULL;
	}

	int width = (int)cinfo.output_width;
	int height = (int)cinfo.output_height;
	size_t stride = (size_t)width * 4;
	unsigned char *pixels = malloc(stride * (size_t)height);
	JSAMPARRAY scanline = (*cinfo.mem->alloc_sarray)((j_common_ptr)&cinfo,
		JPOOL_IMAGE, (JDIMENSION)width * 3, 1);
	if (pixels == NULL || scanline == NULL) {
		free(pixels);
		jpeg_destroy_decompress(&cinfo);
		snprintf(error, error_size, "failed to allocate JPEG pixels");
		return NULL;
	}

	while (cinfo.output_scanline < cinfo.output_height) {
		JDIMENSION y = cinfo.output_scanline;
		jpeg_read_scanlines(&cinfo, scanline, 1);
		unsigned char *dst = pixels + (size_t)y * stride;
		for (int x = 0; x < width; x++) {
			dst[(size_t)x * 4 + 0] = scanline[0][(size_t)x * 3 + 0];
			dst[(size_t)x * 4 + 1] = scanline[0][(size_t)x * 3 + 1];
			dst[(size_t)x * 4 + 2] = scanline[0][(size_t)x * 3 + 2];
			dst[(size_t)x * 4 + 3] = 255;
		}
	}
	jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);

	struct wlr_buffer *buffer =
		create_pixel_buffer_from_rgba(pixels, width, height, stride);
	free(pixels);
	if (buffer == NULL) {
		snprintf(error, error_size, "failed to allocate image buffer");
		return NULL;
	}
	*image_width = width;
	*image_height = height;
	return buffer;
}

static struct wlr_buffer *decode_image_preview(const char *path,
		int *image_width, int *image_height, char *error, size_t error_size) {
	FILE *file = fopen(path, "rb");
	if (file == NULL) {
		snprintf(error, error_size, "failed to open image: %s",
			strerror(errno));
		return NULL;
	}

	unsigned char signature[8] = {0};
	if (fread(signature, 1, sizeof(signature), file) != sizeof(signature)) {
		fclose(file);
		snprintf(error, error_size, "image file is too short");
		return NULL;
	}
	rewind(file);

	struct wlr_buffer *buffer = NULL;
	if (png_sig_cmp(signature, 0, sizeof(signature)) == 0) {
		buffer = decode_png_preview(file, image_width, image_height,
			error, error_size);
	} else if (signature[0] == 0xff && signature[1] == 0xd8 &&
			signature[2] == 0xff) {
		buffer = decode_jpeg_preview(file, image_width, image_height,
			error, error_size);
	} else {
		snprintf(error, error_size, "unsupported image type");
	}
	fclose(file);
	return buffer;
}

static bool json_extract_string(const char *json, const char *key,
		char *out, size_t out_size) {
	char pattern[64];
	snprintf(pattern, sizeof(pattern), "\"%s\"", key);
	const char *pos = strstr(json, pattern);
	if (pos == NULL) {
		return false;
	}
	pos = strchr(pos + strlen(pattern), ':');
	if (pos == NULL) {
		return false;
	}
	pos++;
	while (*pos == ' ' || *pos == '\t' || *pos == '\r' || *pos == '\n') {
		pos++;
	}
	if (*pos != '"') {
		return false;
	}
	pos++;

	size_t used = 0;
	while (*pos != '\0' && *pos != '"') {
		char c = *pos++;
		if (c == '\\') {
			c = *pos++;
			switch (c) {
			case '"':
			case '\\':
			case '/':
				break;
			case 'n':
				c = '\n';
				break;
			case 'r':
				c = '\r';
				break;
			case 't':
				c = '\t';
				break;
			default:
				return false;
			}
		}
		if (used + 1 >= out_size) {
			return false;
		}
		out[used++] = c;
	}
	if (*pos != '"') {
		return false;
	}
	out[used] = '\0';
	return true;
}

static bool json_extract_int(const char *json, const char *key, int *out) {
	char pattern[64];
	snprintf(pattern, sizeof(pattern), "\"%s\"", key);
	const char *pos = strstr(json, pattern);
	if (pos == NULL) {
		return false;
	}
	pos = strchr(pos + strlen(pattern), ':');
	if (pos == NULL) {
		return false;
	}
	pos++;
	while (*pos == ' ' || *pos == '\t' || *pos == '\r' || *pos == '\n') {
		pos++;
	}

	errno = 0;
	char *end = NULL;
	long parsed = strtol(pos, &end, 10);
	if (errno != 0 || end == pos || parsed < 0 || parsed > INT_MAX) {
		return false;
	}
	*out = (int)parsed;
	return true;
}

static bool request_preview_bounds(const char *json,
		struct engineos_preview_bounds *bounds) {
	memset(bounds, 0, sizeof(*bounds));
	if (!json_extract_int(json, "x", &bounds->x) ||
			!json_extract_int(json, "y", &bounds->y) ||
			!json_extract_int(json, "width", &bounds->width) ||
			!json_extract_int(json, "height", &bounds->height)) {
		return false;
	}
	json_extract_int(json, "window_width", &bounds->window_width);
	json_extract_int(json, "window_height", &bounds->window_height);
	if (bounds->width <= 0 || bounds->height <= 0) {
		return false;
	}
	bounds->set = true;
	return true;
}

static int request_opacity_percent(const char *json, int fallback) {
	int value = fallback;
	if (!json_extract_int(json, "opacity", &value)) {
		return fallback;
	}
	if (value < 0) {
		return 0;
	}
	if (value > 100) {
		return 100;
	}
	return value;
}

static void clamp_box_to_output(struct engineos_view_geometry *box,
		const struct engineos_view_geometry *output) {
	int output_right = output->x + output->width;
	int output_bottom = output->y + output->height;
	if (box->x < output->x) {
		box->x = output->x;
	}
	if (box->y < output->y) {
		box->y = output->y;
	}
	if (box->x + box->width > output_right) {
		box->width = output_right - box->x;
	}
	if (box->y + box->height > output_bottom) {
		box->height = output_bottom - box->y;
	}
	if (box->width < 0) {
		box->width = 0;
	}
	if (box->height < 0) {
		box->height = 0;
	}
}

static enum engineos_surface_role parse_surface_role(const char *value) {
	if (value == NULL) {
		return ENGINEOS_SURFACE_UNKNOWN;
	}
	if (strcmp(value, "terminal") == 0) {
		return ENGINEOS_SURFACE_TERMINAL;
	}
	if (strcmp(value, "terminal-secondary") == 0) {
		return ENGINEOS_SURFACE_TERMINAL_SECONDARY;
	}
	if (strcmp(value, "cube") == 0) {
		return ENGINEOS_SURFACE_CUBE;
	}
	if (strcmp(value, "engine") == 0) {
		return ENGINEOS_SURFACE_ENGINE;
	}
	return ENGINEOS_SURFACE_UNKNOWN;
}

static enum engineos_surface_role preview_anchor_role(
		struct engineos_shell_server *server, const char *slot) {
	enum engineos_surface_role role = parse_surface_role(slot);
	if (is_terminal_role(role)) {
		return role;
	}
	if (server->focused_view != NULL && server->focused_view->mapped &&
			is_terminal_role(server->focused_view->role)) {
		return server->focused_view->role;
	}
	if (is_terminal_role(server->active_slot)) {
		return server->active_slot;
	}
	return ENGINEOS_SURFACE_TERMINAL;
}

static bool compute_preview_box(struct engineos_shell_server *server,
		const char *slot,
		const struct engineos_preview_bounds *bounds,
		struct engineos_view_geometry *box) {
	enum engineos_surface_role anchor_role = preview_anchor_role(server, slot);
	bool explicit_anchor = is_terminal_role(parse_surface_role(slot));
	struct engineos_view_geometry output = {0};
	output_geometry_for_role(server, anchor_role,
		&output.x, &output.y, &output.width, &output.height);

	*box = output;
	box->layout = "preview";
	box->fullscreen = false;

	if (bounds != NULL && bounds->set &&
			bounds->window_width > 0 && bounds->window_height > 0) {
		struct engineos_layout_request request = {0};
		request.pane = true;
		request.pane_left = bounds->x;
		request.pane_top = bounds->y;
		request.pane_width = bounds->width;
		request.pane_height = bounds->height;
		request.window_width = bounds->window_width;
		request.window_height = bounds->window_height;
		if (!apply_pane_geometry(&request, &output, box)) {
			return false;
		}
	} else if (!explicit_anchor && server->focused_view != NULL &&
			is_terminal_role(server->focused_view->role)) {
		struct engineos_view_geometry focused = {0};
		if (compute_view_geometry(server->focused_view, &focused) &&
				focused.width > 0 && focused.height > 0) {
			*box = focused;
			box->layout = "preview-focused-terminal";
		}
	}

	clamp_box_to_output(box, &output);
	return box->width > 0 && box->height > 0;
}

static void reset_image_surface(struct engineos_preview_surface *surface) {
	if (surface->scene_buffer != NULL) {
		wlr_scene_node_destroy(&surface->scene_buffer->node);
		surface->scene_buffer = NULL;
	}
	if (surface->buffer != NULL) {
		wlr_buffer_drop(surface->buffer);
		surface->buffer = NULL;
	}
	free(surface->path);
	surface->path = NULL;
	free(surface->owner);
	surface->owner = NULL;
	free(surface->mode);
	surface->mode = NULL;
	surface->x = 0;
	surface->y = 0;
	surface->width = 0;
	surface->height = 0;
	surface->image_width = 0;
	surface->image_height = 0;
	surface->opacity_percent = 0;
}

static void hide_image_preview(struct engineos_shell_server *server,
		const char *reason) {
	reset_image_surface(&server->preview);
	wlr_log(WLR_INFO, "image preview hidden reason=%s",
		reason != NULL ? reason : "unspecified");
	schedule_outputs(server);
}

static void hide_wallpaper(struct engineos_shell_server *server,
		const char *reason) {
	reset_image_surface(&server->wallpaper);
	wlr_log(WLR_INFO, "wallpaper hidden reason=%s",
		reason != NULL ? reason : "unspecified");
	write_shell_state(server, reason != NULL ? reason : "wallpaper-hidden");
	schedule_outputs(server);
}

static bool show_image_preview(struct engineos_shell_server *server,
		const char *path, const char *slot, const char *owner,
		const struct engineos_preview_bounds *bounds, char *error,
		size_t error_size) {
	if (path == NULL || path[0] != '/') {
		snprintf(error, error_size, "preview path must be absolute");
		return false;
	}
	struct stat st;
	if (stat(path, &st) < 0 || !S_ISREG(st.st_mode)) {
		snprintf(error, error_size, "preview path is not a readable file");
		return false;
	}

	struct engineos_view_geometry box = {0};
	if (!compute_preview_box(server, slot, bounds, &box)) {
		snprintf(error, error_size, "preview bounds are outside the active output");
		return false;
	}

	int image_width = 0;
	int image_height = 0;
	struct wlr_buffer *buffer =
		decode_image_preview(path, &image_width, &image_height, error, error_size);
	if (buffer == NULL) {
		return false;
	}

	long dest_width = box.width;
	long dest_height = ((long)box.width * image_height) / image_width;
	if (dest_height > box.height) {
		dest_height = box.height;
		dest_width = ((long)box.height * image_width) / image_height;
	}
	if (dest_width <= 0 || dest_height <= 0 ||
			dest_width > INT_MAX || dest_height > INT_MAX) {
		wlr_buffer_drop(buffer);
		snprintf(error, error_size, "preview destination size is invalid");
		return false;
	}

	hide_image_preview(server, "replace");
	server->preview.buffer = buffer;
	server->preview.scene_buffer =
		wlr_scene_buffer_create(&server->scene->tree, buffer);
	if (server->preview.scene_buffer == NULL) {
		wlr_buffer_drop(buffer);
		server->preview.buffer = NULL;
		snprintf(error, error_size, "failed to create preview scene buffer");
		return false;
	}

	server->preview.path = strdup(path);
	server->preview.owner = owner != NULL && owner[0] != '\0' ?
		strdup(owner) : NULL;
	server->preview.x = box.x + (box.width - (int)dest_width) / 2;
	server->preview.y = box.y + (box.height - (int)dest_height) / 2;
	server->preview.width = (int)dest_width;
	server->preview.height = (int)dest_height;
	server->preview.image_width = image_width;
	server->preview.image_height = image_height;
	wlr_scene_buffer_set_dest_size(server->preview.scene_buffer,
		server->preview.width, server->preview.height);
	wlr_scene_node_set_position(&server->preview.scene_buffer->node,
		server->preview.x, server->preview.y);
	wlr_scene_node_raise_to_top(&server->preview.scene_buffer->node);
	wlr_log(WLR_INFO,
		"image preview shown path=%s owner=%s slot=%s image=%dx%d x=%d y=%d size=%dx%d bounds=%dx%d",
		path,
		server->preview.owner != NULL ? server->preview.owner : "",
		slot != NULL ? slot : "",
		image_width, image_height, server->preview.x,
		server->preview.y, server->preview.width, server->preview.height,
		box.width, box.height);
	schedule_outputs(server);
	return true;
}

static bool compute_wallpaper_box(struct engineos_shell_server *server,
		const char *slot, const char *mode,
		const struct engineos_preview_bounds *bounds,
		struct engineos_view_geometry *box) {
	if (mode != NULL && strcmp(mode, "pane") == 0) {
		return compute_preview_box(server, slot, bounds, box);
	}

	enum engineos_surface_role anchor_role = preview_anchor_role(server, slot);
	output_geometry_for_role(server, anchor_role,
		&box->x, &box->y, &box->width, &box->height);
	box->fullscreen = false;
	box->layout = "wallpaper-output";
	return box->width > 0 && box->height > 0;
}

static bool show_wallpaper(struct engineos_shell_server *server,
		const char *path, const char *slot, const char *mode,
		const struct engineos_preview_bounds *bounds, int opacity_percent,
		char *error, size_t error_size) {
	if (path == NULL || path[0] != '/') {
		snprintf(error, error_size, "wallpaper path must be absolute");
		return false;
	}
	struct stat st;
	if (stat(path, &st) < 0 || !S_ISREG(st.st_mode)) {
		snprintf(error, error_size, "wallpaper path is not a readable file");
		return false;
	}

	const char *wallpaper_mode =
		mode != NULL && strcmp(mode, "pane") == 0 ? "pane" : "output";
	struct engineos_view_geometry box = {0};
	if (!compute_wallpaper_box(server, slot, wallpaper_mode, bounds, &box)) {
		snprintf(error, error_size, "wallpaper bounds are outside the active output");
		return false;
	}

	int image_width = 0;
	int image_height = 0;
	struct wlr_buffer *buffer =
		decode_image_preview(path, &image_width, &image_height, error, error_size);
	if (buffer == NULL) {
		return false;
	}

	struct wlr_fbox source_box = {
		.x = 0.0,
		.y = 0.0,
		.width = image_width,
		.height = image_height,
	};
	double image_ratio = (double)image_width / (double)image_height;
	double dest_ratio = (double)box.width / (double)box.height;
	if (image_ratio > dest_ratio) {
		source_box.width = (double)image_height * dest_ratio;
		source_box.x = ((double)image_width - source_box.width) / 2.0;
	} else if (image_ratio < dest_ratio) {
		source_box.height = (double)image_width / dest_ratio;
		source_box.y = ((double)image_height - source_box.height) / 2.0;
	}

	hide_wallpaper(server, "replace");
	server->wallpaper.buffer = buffer;
	server->wallpaper.scene_buffer =
		wlr_scene_buffer_create(&server->scene->tree, buffer);
	if (server->wallpaper.scene_buffer == NULL) {
		wlr_buffer_drop(buffer);
		server->wallpaper.buffer = NULL;
		snprintf(error, error_size, "failed to create wallpaper scene buffer");
		return false;
	}

	server->wallpaper.path = strdup(path);
	server->wallpaper.mode = strdup(wallpaper_mode);
	server->wallpaper.x = box.x;
	server->wallpaper.y = box.y;
	server->wallpaper.width = box.width;
	server->wallpaper.height = box.height;
	server->wallpaper.image_width = image_width;
	server->wallpaper.image_height = image_height;
	server->wallpaper.opacity_percent = opacity_percent;
	wlr_scene_buffer_set_source_box(server->wallpaper.scene_buffer,
		&source_box);
	wlr_scene_buffer_set_dest_size(server->wallpaper.scene_buffer,
		server->wallpaper.width, server->wallpaper.height);
	wlr_scene_buffer_set_opacity(server->wallpaper.scene_buffer,
		(float)opacity_percent / 100.0f);
	wlr_scene_node_set_position(&server->wallpaper.scene_buffer->node,
		server->wallpaper.x, server->wallpaper.y);
	if (strcmp(wallpaper_mode, "pane") == 0) {
		wlr_scene_node_raise_to_top(&server->wallpaper.scene_buffer->node);
	} else {
		wlr_scene_node_lower_to_bottom(&server->wallpaper.scene_buffer->node);
	}
	wlr_log(WLR_INFO,
		"wallpaper shown path=%s mode=%s opacity=%d image=%dx%d x=%d y=%d size=%dx%d source=%.1fx%.1f+%.1f+%.1f",
		path, wallpaper_mode, opacity_percent, image_width, image_height,
		server->wallpaper.x, server->wallpaper.y,
		server->wallpaper.width, server->wallpaper.height,
		source_box.width, source_box.height, source_box.x, source_box.y);
	write_shell_state(server, "wallpaper-shown");
	schedule_outputs(server);
	return true;
}

static void preview_write_response(int client_fd, const char *status,
		const char *error) {
	char response[1024];
	if (strcmp(status, "ok") == 0) {
		snprintf(response, sizeof(response),
			"{\"version\":1,\"status\":\"ok\",\"capabilities\":[\"ping\",\"show\",\"hide\",\"wallpaper\",\"hide-wallpaper\",\"launch\",\"png\",\"jpeg\",\"contain\",\"cover\",\"opacity\"]}\n");
	} else {
		char escaped[768];
		size_t used = 0;
		const char *message = error != NULL ? error : "request failed";
		for (const unsigned char *p = (const unsigned char *)message;
				*p != '\0' && used + 2 < sizeof(escaped); p++) {
			if (*p == '"' || *p == '\\') {
				escaped[used++] = '\\';
			}
			if (*p >= 0x20) {
				escaped[used++] = (char)*p;
			}
		}
		escaped[used] = '\0';
		snprintf(response, sizeof(response),
			"{\"version\":1,\"status\":\"error\",\"error\":\"%s\"}\n",
			escaped);
	}
	ssize_t written = write(client_fd, response, strlen(response));
	if (written < 0) {
		wlr_log(WLR_ERROR, "preview ipc response write failed: %s",
			strerror(errno));
	}
}

static void handle_preview_request(struct engineos_shell_server *server,
		int client_fd, const char *request) {
	char op[32] = {0};
	if (!json_extract_string(request, "op", op, sizeof(op))) {
		preview_write_response(client_fd, "error", "missing op");
		return;
	}

	if (strcmp(op, "ping") == 0) {
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "hide") == 0) {
		char owner[128] = {0};
		json_extract_string(request, "owner", owner, sizeof(owner));
		if (owner[0] != '\0' && server->preview.owner != NULL &&
				strcmp(owner, server->preview.owner) != 0) {
			wlr_log(WLR_INFO,
				"image preview hide ignored owner=%s current_owner=%s reason=stale-owner",
				owner, server->preview.owner);
			preview_write_response(client_fd, "ok", NULL);
			return;
		}
		hide_image_preview(server, "ipc-hide");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "hide-wallpaper") == 0) {
		hide_wallpaper(server, "ipc-hide-wallpaper");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "launch") == 0) {
		char slot[64] = {0};
		if (!json_extract_string(request, "slot", slot, sizeof(slot))) {
			preview_write_response(client_fd, "error", "missing slot");
			return;
		}
		enum engineos_surface_role role = parse_surface_role(slot);
		if (!is_launchpad_role(role)) {
			preview_write_response(client_fd, "error", "unsupported slot");
			return;
		}
		launch_or_activate_slot(server, role, "ipc-launch");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "wallpaper") == 0) {
		char path[PATH_MAX] = {0};
		if (!json_extract_string(request, "path", path, sizeof(path))) {
			preview_write_response(client_fd, "error", "missing path");
			return;
		}
		char slot[64] = {0};
		json_extract_string(request, "slot", slot, sizeof(slot));
		char mode[32] = {0};
		json_extract_string(request, "mode", mode, sizeof(mode));
		struct engineos_preview_bounds bounds = {0};
		request_preview_bounds(request, &bounds);
		int opacity = request_opacity_percent(request, 100);
		char error[512] = {0};
		if (!show_wallpaper(server, path, slot, mode, &bounds, opacity,
					error, sizeof(error))) {
			wlr_log(WLR_ERROR, "wallpaper show failed path=%s error=%s",
				path, error[0] != '\0' ? error : "unknown");
			preview_write_response(client_fd, "error",
				error[0] != '\0' ? error : "wallpaper failed");
			return;
		}
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "show") != 0) {
		preview_write_response(client_fd, "error", "unsupported op");
		return;
	}

	char path[PATH_MAX] = {0};
	if (!json_extract_string(request, "path", path, sizeof(path))) {
		preview_write_response(client_fd, "error", "missing path");
		return;
	}
	char slot[64] = {0};
	json_extract_string(request, "slot", slot, sizeof(slot));
	char owner[128] = {0};
	json_extract_string(request, "owner", owner, sizeof(owner));
	struct engineos_preview_bounds bounds = {0};
	request_preview_bounds(request, &bounds);
	char error[512] = {0};
	if (!show_image_preview(server, path, slot, owner, &bounds, error, sizeof(error))) {
		wlr_log(WLR_ERROR, "image preview show failed path=%s error=%s",
			path, error[0] != '\0' ? error : "unknown");
		preview_write_response(client_fd, "error",
			error[0] != '\0' ? error : "show failed");
		return;
	}
	preview_write_response(client_fd, "ok", NULL);
}

static int preview_socket_event(int fd, uint32_t mask, void *data) {
	struct engineos_shell_server *server = data;
	if ((mask & WL_EVENT_READABLE) == 0) {
		return 0;
	}

	struct sockaddr_un addr;
	socklen_t addr_len = sizeof(addr);
	int client_fd = accept(fd, (struct sockaddr *)&addr, &addr_len);
	if (client_fd < 0) {
		if (errno != EAGAIN && errno != EWOULDBLOCK) {
			wlr_log(WLR_ERROR, "preview ipc accept failed: %s",
				strerror(errno));
		}
		return 0;
	}

	char request[8192];
	ssize_t nread = read(client_fd, request, sizeof(request) - 1);
	if (nread <= 0) {
		preview_write_response(client_fd, "error", "empty request");
		close(client_fd);
		return 0;
	}
	request[nread] = '\0';
	handle_preview_request(server, client_fd, request);
	close(client_fd);
	return 0;
}

static void close_preview_ipc(struct engineos_shell_server *server,
		bool unlink_socket, bool free_path) {
	if (server->preview_socket_source != NULL) {
		wl_event_source_remove(server->preview_socket_source);
		server->preview_socket_source = NULL;
	}
	if (server->preview_socket_fd >= 0) {
		close(server->preview_socket_fd);
		server->preview_socket_fd = -1;
	}
	if (unlink_socket && server->preview_socket_path != NULL) {
		unlink(server->preview_socket_path);
	}
	if (free_path && server->preview_socket_path != NULL) {
		free(server->preview_socket_path);
		server->preview_socket_path = NULL;
	}
}

static bool init_preview_ipc(struct engineos_shell_server *server) {
	if (server->state_dir == NULL) {
		return false;
	}
	server->preview_socket_path = join_state_path(server->state_dir,
		"preview.sock");
	if (server->preview_socket_path == NULL) {
		return false;
	}
	if (!mkdir_p(server->state_dir, 0775)) {
		wlr_log(WLR_ERROR, "failed to create preview ipc dir %s: %s",
			server->state_dir, strerror(errno));
		return false;
	}

	int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (sock < 0) {
		wlr_log(WLR_ERROR, "failed to create preview ipc socket: %s",
			strerror(errno));
		return false;
	}

	struct sockaddr_un addr = {0};
	addr.sun_family = AF_UNIX;
	if (strlen(server->preview_socket_path) >= sizeof(addr.sun_path)) {
		wlr_log(WLR_ERROR, "preview ipc socket path is too long: %s",
			server->preview_socket_path);
		close(sock);
		return false;
	}
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s",
		server->preview_socket_path);
	unlink(server->preview_socket_path);
	if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		wlr_log(WLR_ERROR, "failed to bind preview ipc socket %s: %s",
			server->preview_socket_path, strerror(errno));
		close(sock);
		return false;
	}
	if (listen(sock, 16) < 0) {
		wlr_log(WLR_ERROR, "failed to listen on preview ipc socket %s: %s",
			server->preview_socket_path, strerror(errno));
		close(sock);
		unlink(server->preview_socket_path);
		return false;
	}
	chmod(server->preview_socket_path, 0660);

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server->display);
	server->preview_socket_source =
		wl_event_loop_add_fd(event_loop, sock, WL_EVENT_READABLE,
			preview_socket_event, server);
	if (server->preview_socket_source == NULL) {
		wlr_log(WLR_ERROR, "failed to register preview ipc socket");
		close(sock);
		unlink(server->preview_socket_path);
		return false;
	}
	server->preview_socket_fd = sock;
	wlr_log(WLR_INFO, "preview ipc listening path=%s",
		server->preview_socket_path);
	return true;
}

static void write_shell_state(struct engineos_shell_server *server,
		const char *reason) {
	if (server->state_dir == NULL || server->state_file == NULL) {
		return;
	}

	if (!mkdir_p(server->state_dir, 0775)) {
		wlr_log(WLR_ERROR, "failed to create shell state dir %s: %s",
			server->state_dir, strerror(errno));
		return;
	}

	char *tmp_file = join_state_path(server->state_dir, "shell-state.json.tmp");
	if (tmp_file == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate shell state temp path");
		return;
	}

	FILE *file = fopen(tmp_file, "w");
	if (file == NULL) {
		wlr_log(WLR_ERROR, "failed to open shell state file %s: %s",
			tmp_file, strerror(errno));
		free(tmp_file);
		return;
	}

	fprintf(file, "{\n");
	fprintf(file, "  \"schema\": \"engineos-shell-state-v0\",\n");
	fprintf(file, "  \"pid\": %ld,\n", (long)getpid());
	fprintf(file, "  \"mode\": ");
	json_write_string(file, server->mode_name);
	fprintf(file, ",\n  \"wayland_display\": ");
	json_write_string(file, getenv("WAYLAND_DISPLAY"));
	fprintf(file, ",\n  \"bootstrap\": ");
	json_write_string(file, bootstrap_mode_name(server->bootstrap_mode));
	fprintf(file, ",\n  \"active_slot\": ");
	json_write_string(file, surface_role_name(server->active_slot));
	fprintf(file, ",\n  \"pending_slot\": ");
	json_write_string(file, surface_role_name(server->pending_slot));
	fprintf(file, ",\n  \"input\": {\"mode\": ");
	json_write_string(file, input_mode_name(server->input_mode));
	fprintf(file, ", \"capture\": %s},\n",
		server->game_capture ? "true" : "false");
	fprintf(file,
		"  \"cursor\": {\"locked\": %s, \"hidden\": %s, \"x\": %.1f, \"y\": %.1f},\n",
		should_lock_game_cursor(server) ? "true" : "false",
		server->cursor_hidden ? "true" : "false",
		server->cursor != NULL ? server->cursor->x : 0.0,
		server->cursor != NULL ? server->cursor->y : 0.0);
	fprintf(file, "  \"counts\": {\"outputs\": %u, \"keyboards\": %u, \"pointers\": %u, \"views\": %u},\n",
		server->output_count, server->keyboard_count,
		server->pointer_count, server->view_count);
	fprintf(file, "  \"last_reason\": ");
	json_write_string(file, reason != NULL ? reason : "unspecified");
	fprintf(file, ",\n  \"wallpaper\": {\"visible\": %s, \"path\": ",
		server->wallpaper.scene_buffer != NULL ? "true" : "false");
	json_write_string(file, server->wallpaper.path);
	fprintf(file, ", \"mode\": ");
	json_write_string(file, server->wallpaper.mode);
	fprintf(file, ", \"opacity\": %d, \"x\": %d, \"y\": %d, \"width\": %d, \"height\": %d, \"image_width\": %d, \"image_height\": %d}",
		server->wallpaper.opacity_percent, server->wallpaper.x,
		server->wallpaper.y, server->wallpaper.width,
		server->wallpaper.height, server->wallpaper.image_width,
		server->wallpaper.image_height);
	fprintf(file, ",\n  \"slots\": {\n");
	write_slot_state(file, server, ENGINEOS_SURFACE_TERMINAL);
	fprintf(file, ",\n");
	write_slot_state(file, server, ENGINEOS_SURFACE_TERMINAL_SECONDARY);
	fprintf(file, ",\n");
	write_slot_state(file, server, ENGINEOS_SURFACE_CUBE);
	fprintf(file, ",\n");
	write_slot_state(file, server, ENGINEOS_SURFACE_ENGINE);
	fprintf(file, "\n  },\n  \"windows\": [");

	bool first_window = true;
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (!view->mapped) {
			continue;
		}
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		bool visible = view_geometry_visible(server, view, &geometry);
		if (!first_window) {
			fprintf(file, ",");
		}
		first_window = false;
		fprintf(file, "\n    {\"role\": ");
		json_write_string(file, surface_role_name(view->role));
		fprintf(file, ", \"focused\": %s, \"visible\": %s, \"minimized\": %s, \"maximized\": %s, \"layout\": ",
			server->focused_view == view ? "true" : "false",
			visible ? "true" : "false",
			view->minimized ? "true" : "false",
			view->maximized ? "true" : "false");
		json_write_string(file, geometry.layout);
		fprintf(file, ", \"x\": %d, \"y\": %d, \"width\": %d, \"height\": %d, \"title\": ",
			geometry.x, geometry.y, geometry.width, geometry.height);
		json_write_string(file, view_title(view));
		fprintf(file, ", \"app_id\": ");
		json_write_string(file, view_app_id(view));
		fprintf(file, "}");
	}
	if (!first_window) {
		fprintf(file, "\n  ");
	}
	fprintf(file, "],\n  \"launches\": [");

	bool first = true;
	struct engineos_shell_launch *launch;
	wl_list_for_each(launch, &server->launches, link) {
		if (!first) {
			fprintf(file, ",");
		}
		first = false;
		fprintf(file, "\n    {\"pid\": %ld, \"role\": ", (long)launch->pid);
		json_write_string(file, surface_role_name(launch->role));
		fprintf(file, ", \"label\": ");
		json_write_string(file, launch->label);
		fprintf(file, ", \"mapped\": %s, \"command\": ",
			launch->mapped ? "true" : "false");
		json_write_string(file, launch->command);
		fprintf(file, "}");
	}
	if (!first) {
		fprintf(file, "\n  ");
	}
	fprintf(file, "]\n}\n");

	bool ok = true;
	if (fclose(file) != 0) {
		wlr_log(WLR_ERROR, "failed to close shell state file %s: %s",
			tmp_file, strerror(errno));
		ok = false;
	}
	if (ok && rename(tmp_file, server->state_file) < 0) {
		wlr_log(WLR_ERROR, "failed to publish shell state file %s: %s",
			server->state_file, strerror(errno));
		ok = false;
	}
	if (!ok) {
		unlink(tmp_file);
	}
	free(tmp_file);
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

static bool should_lock_game_cursor(struct engineos_shell_server *server) {
	return server != NULL &&
		server->game_capture &&
		server->input_mode == ENGINEOS_INPUT_GAME &&
		server->focused_view != NULL &&
		server->focused_view->mapped &&
		server->focused_view->role == ENGINEOS_SURFACE_ENGINE;
}

static struct wlr_surface *focused_game_surface(
		struct engineos_shell_server *server) {
	if (!should_lock_game_cursor(server) ||
			server->focused_view->xdg_surface == NULL) {
		return NULL;
	}
	return server->focused_view->xdg_surface->surface;
}

static void clear_active_pointer_constraint(
		struct engineos_shell_server *server, const char *reason) {
	if (server == NULL || server->active_pointer_constraint == NULL) {
		return;
	}

	struct wlr_pointer_constraint_v1 *constraint =
		server->active_pointer_constraint;
	const char *type = pointer_constraint_type_name(constraint->type);
	remove_listener_if_linked(&server->active_pointer_constraint_destroy);
	server->active_pointer_constraint = NULL;
	wlr_log(WLR_INFO,
		"pointer constraint deactivated type=%s reason=%s",
		type, reason != NULL ? reason : "unspecified");
	wlr_pointer_constraint_v1_send_deactivated(constraint);
}

static void active_pointer_constraint_destroy(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_server *server =
		wl_container_of(listener, server, active_pointer_constraint_destroy);

	remove_listener_if_linked(&server->active_pointer_constraint_destroy);
	server->active_pointer_constraint = NULL;
	wlr_log(WLR_INFO, "pointer constraint destroyed active=true");
}

static void sync_pointer_constraint(struct engineos_shell_server *server,
		const char *reason) {
	if (server == NULL || server->pointer_constraints == NULL) {
		return;
	}

	struct wlr_pointer_constraint_v1 *constraint = NULL;
	struct wlr_surface *surface = focused_game_surface(server);
	if (surface != NULL) {
		constraint = wlr_pointer_constraints_v1_constraint_for_surface(
			server->pointer_constraints, surface, server->seat);
	}

	if (server->active_pointer_constraint != NULL &&
			server->active_pointer_constraint != constraint) {
		clear_active_pointer_constraint(server, reason);
	}

	if (constraint == NULL || server->active_pointer_constraint == constraint) {
		return;
	}

	server->active_pointer_constraint = constraint;
	server->active_pointer_constraint_destroy.notify =
		active_pointer_constraint_destroy;
	wl_signal_add(&constraint->events.destroy,
		&server->active_pointer_constraint_destroy);
	wlr_pointer_constraint_v1_send_activated(constraint);
	wlr_log(WLR_INFO,
		"pointer constraint activated role=engine type=%s reason=%s",
		pointer_constraint_type_name(constraint->type),
		reason != NULL ? reason : "unspecified");
}

static bool view_cursor_bounds(struct engineos_shell_view *view,
		double *min_x, double *min_y, double *max_x, double *max_y) {
	if (view == NULL || !view->mapped || view->scene_tree == NULL) {
		return false;
	}

	int vx = 0;
	int vy = 0;
	if (!wlr_scene_node_coords(&view->scene_tree->node, &vx, &vy)) {
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		vx = geometry.x;
		vy = geometry.y;
	}

	int width = 0;
	int height = 0;
	if (view->xdg_surface != NULL && view->xdg_surface->surface != NULL) {
		width = view->xdg_surface->surface->current.width;
		height = view->xdg_surface->surface->current.height;
	}
	if (width <= 0 || height <= 0) {
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		width = geometry.width;
		height = geometry.height;
	}
	if (width <= 0 || height <= 0) {
		return false;
	}

	*min_x = vx;
	*min_y = vy;
	*max_x = vx + width - 1;
	*max_y = vy + height - 1;
	return true;
}

static bool confine_cursor_to_view(struct engineos_shell_server *server,
		struct engineos_shell_view *view, const char *reason) {
	if (server == NULL || server->cursor == NULL || view == NULL) {
		return false;
	}

	double min_x = 0.0;
	double min_y = 0.0;
	double max_x = 0.0;
	double max_y = 0.0;
	if (!view_cursor_bounds(view, &min_x, &min_y, &max_x, &max_y)) {
		return false;
	}

	double x = server->cursor->x;
	double y = server->cursor->y;
	if (x < min_x) {
		x = min_x;
	} else if (x > max_x) {
		x = max_x;
	}
	if (y < min_y) {
		y = min_y;
	} else if (y > max_y) {
		y = max_y;
	}

	if (x != server->cursor->x || y != server->cursor->y) {
		wlr_cursor_warp_closest(server->cursor, NULL, x, y);
		wlr_log(WLR_INFO,
			"cursor confined role=%s x=%.1f y=%.1f bounds=%.1f,%.1f %.1fx%.1f reason=%s",
			surface_role_name(view->role), server->cursor->x, server->cursor->y,
			min_x, min_y, max_x - min_x + 1, max_y - min_y + 1,
			reason != NULL ? reason : "unspecified");
		return true;
	}
	return false;
}

static bool focused_view_pointer_coords(struct engineos_shell_server *server,
		struct wlr_surface **surface, double *sx, double *sy) {
	struct engineos_shell_view *view = server->focused_view;
	if (view == NULL || !view->mapped) {
		return false;
	}

	if (should_lock_game_cursor(server)) {
		confine_cursor_to_view(server, view, "pointer-target");
	}

	int vx = 0;
	int vy = 0;
	if (!wlr_scene_node_coords(&view->scene_tree->node, &vx, &vy)) {
		return false;
	}

	*surface = view->xdg_surface->surface;
	*sx = server->cursor->x - vx;
	*sy = server->cursor->y - vy;
	if (view->xdg_surface->surface->current.width > 0) {
		double max_sx = view->xdg_surface->surface->current.width - 1;
		if (*sx < 0.0) {
			*sx = 0.0;
		} else if (*sx > max_sx) {
			*sx = max_sx;
		}
	}
	if (view->xdg_surface->surface->current.height > 0) {
		double max_sy = view->xdg_surface->surface->current.height - 1;
		if (*sy < 0.0) {
			*sy = 0.0;
		} else if (*sy > max_sy) {
			*sy = max_sy;
		}
	}
	return true;
}

static void set_input_mode_for_clicked_view(struct engineos_shell_view *view) {
	struct engineos_shell_server *server = view->server;

	if (is_launchpad_role(view->role)) {
		set_active_slot(server, view->role, "click-focus");
		return;
	}

	server->game_capture = false;
	switch (view->role) {
	case ENGINEOS_SURFACE_ENGINE:
		server->input_mode = ENGINEOS_INPUT_GAME;
		break;
	case ENGINEOS_SURFACE_TERMINAL:
	case ENGINEOS_SURFACE_TERMINAL_SECONDARY:
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		server->input_mode = ENGINEOS_INPUT_TERMINAL;
		break;
	}

	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=click-focus role=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		surface_role_name(view->role));
	sync_pointer_constraint(server, "click-focus");
	sync_cursor_image(server, "click-focus");
	write_shell_state(server, "click-focus");
}

static enum engineos_surface_role classify_view_role(struct engineos_shell_view *view) {
	const char *app_id = view_app_id(view);
	const char *title = view_title(view);

	if (ascii_contains_ci(app_id, "engineos-cube") ||
			ascii_contains_ci(title, "engineos-cube") ||
			ascii_contains_ci(app_id, "cube") ||
			ascii_contains_ci(title, "cube")) {
		return ENGINEOS_SURFACE_CUBE;
	}
	if (ascii_contains_ci(app_id, "engineos-terminal-secondary") ||
			ascii_contains_ci(app_id, "terminal-secondary") ||
			ascii_contains_ci(title, "EngineOS Side") ||
			ascii_contains_ci(title, "terminal-secondary")) {
		return ENGINEOS_SURFACE_TERMINAL_SECONDARY;
	}
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

static bool xdg_toplevel_supports_configure_bounds(
		struct wlr_xdg_toplevel *toplevel) {
	if (toplevel == NULL || toplevel->resource == NULL ||
			toplevel->base == NULL || toplevel->base->client == NULL ||
			toplevel->base->client->shell == NULL) {
		return false;
	}
	if (toplevel->base->client->shell->version <
			XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION) {
		return false;
	}
	return wl_resource_get_version(toplevel->resource) >=
		XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION;
}

static bool xdg_toplevel_supports_wm_capabilities(
		struct wlr_xdg_toplevel *toplevel) {
	if (toplevel == NULL || toplevel->resource == NULL ||
			toplevel->base == NULL || toplevel->base->client == NULL ||
			toplevel->base->client->shell == NULL) {
		return false;
	}
	if (toplevel->base->client->shell->version <
			XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION) {
		return false;
	}
	return wl_resource_get_version(toplevel->resource) >=
		XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION;
}

static bool xdg_toplevel_can_configure(struct wlr_xdg_toplevel *toplevel) {
	return toplevel != NULL && toplevel->base != NULL &&
		toplevel->base->initialized;
}

static void set_toplevel_wm_capabilities(struct wlr_xdg_toplevel *toplevel) {
	if (!xdg_toplevel_can_configure(toplevel) ||
			!xdg_toplevel_supports_wm_capabilities(toplevel)) {
		return;
	}
	wlr_xdg_toplevel_set_wm_capabilities(toplevel,
		WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE |
		WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN |
		WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE);
}

static bool xdg_toplevel_supports_suspended(
		struct wlr_xdg_toplevel *toplevel) {
	if (toplevel == NULL || toplevel->resource == NULL ||
			toplevel->base == NULL || toplevel->base->client == NULL ||
			toplevel->base->client->shell == NULL) {
		return false;
	}
	if (toplevel->base->client->shell->version <
			XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION) {
		return false;
	}
	return wl_resource_get_version(toplevel->resource) >=
		XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION;
}

static void set_toplevel_suspended(struct wlr_xdg_toplevel *toplevel,
		bool suspended) {
	if (!xdg_toplevel_can_configure(toplevel) ||
			!xdg_toplevel_supports_suspended(toplevel)) {
		return;
	}
	wlr_xdg_toplevel_set_suspended(toplevel, suspended);
}

static void set_toplevel_geometry(struct wlr_xdg_toplevel *toplevel,
		const struct engineos_view_geometry *geometry) {
	if (!xdg_toplevel_can_configure(toplevel) || geometry == NULL) {
		return;
	}
	wlr_xdg_toplevel_set_fullscreen(toplevel, geometry->fullscreen);
	if (xdg_toplevel_supports_configure_bounds(toplevel)) {
		wlr_xdg_toplevel_set_bounds(toplevel, geometry->width,
			geometry->height);
	}
	wlr_xdg_toplevel_set_size(toplevel, geometry->width, geometry->height);
}

static void apply_view_layout(struct engineos_shell_view *view) {
	struct engineos_view_geometry geometry = {0};
	compute_view_geometry(view, &geometry);

	switch (view->role) {
	case ENGINEOS_SURFACE_TERMINAL:
	case ENGINEOS_SURFACE_TERMINAL_SECONDARY:
	case ENGINEOS_SURFACE_CUBE:
	case ENGINEOS_SURFACE_ENGINE:
		if (view->xdg_surface != NULL &&
				xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
			if (view->role == ENGINEOS_SURFACE_CUBE ||
					view->role == ENGINEOS_SURFACE_ENGINE) {
				set_toplevel_geometry(view->xdg_surface->toplevel, &geometry);
			} else {
				wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
					geometry.width, geometry.height);
			}
		}
		break;
	case ENGINEOS_SURFACE_UNKNOWN:
	default:
		if (view->xdg_surface != NULL &&
				xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
			wlr_xdg_toplevel_set_fullscreen(view->xdg_surface->toplevel,
				geometry.fullscreen);
			wlr_xdg_toplevel_set_maximized(view->xdg_surface->toplevel,
				view->maximized);
			set_toplevel_suspended(view->xdg_surface->toplevel, view->minimized);
			wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
				geometry.width, geometry.height);
		}
		break;
	}
	wlr_scene_node_set_position(&view->scene_tree->node, geometry.x,
		geometry.y);
	if (is_launchpad_role(view->role)) {
		wlr_log(WLR_INFO,
			"layout view role=%s layout=%s x=%d y=%d size=%dx%d fullscreen=%s active_slot=%s title=%s app_id=%s",
			surface_role_name(view->role), geometry.layout,
			geometry.x, geometry.y, geometry.width, geometry.height,
			geometry.fullscreen ? "true" : "false",
			surface_role_name(view->server->active_slot),
			view_title(view), view_app_id(view));
	} else {
		wlr_log(WLR_INFO,
			"layout view role=%s layout=%s x=%d y=%d size=%dx%d maximized=%s minimized=%s title=%s app_id=%s",
			surface_role_name(view->role), geometry.layout,
			geometry.x, geometry.y, geometry.width, geometry.height,
			view->maximized ? "true" : "false",
			view->minimized ? "true" : "false",
			view_title(view), view_app_id(view));
	}
}

static void apply_launchpad_visibility(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_shell_view *view;
	struct engineos_shell_view *active_view = NULL;
	bool active_terminal = false;

	wl_list_for_each(view, &server->views, link) {
		if (!view->mapped || !is_launchpad_role(view->role)) {
			continue;
		}

		bool active = view->role == server->active_slot;
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		bool visible = view_geometry_visible(server, view, &geometry);
		apply_view_layout(view);
		wlr_scene_node_set_enabled(&view->scene_tree->node, visible);
		if (active) {
			active_view = view;
			active_terminal = is_terminal_role(view->role);
		} else {
			set_view_activated(view, false);
		}
		wlr_log(WLR_INFO,
			"launchpad slot visibility role=%s active=%s visible=%s reason=%s",
			surface_role_name(view->role), active ? "true" : "false",
			visible ? "true" : "false",
			reason != NULL ? reason : "unspecified");
	}

	if (active_view != NULL && active_terminal) {
		focus_view(active_view);
	}

	wl_list_for_each(view, &server->views, link) {
		if (!view->mapped || !is_launchpad_role(view->role) ||
				view == active_view) {
			continue;
		}
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		if (view_geometry_visible(server, view, &geometry) &&
				is_persistent_panel_geometry(view->role, &geometry)) {
			wlr_scene_node_raise_to_top(&view->scene_tree->node);
		}
	}

	if (active_view != NULL && !active_terminal) {
		focus_view(active_view);
	} else if (active_view == NULL && is_launchpad_role(server->active_slot)) {
		wlr_log(WLR_INFO,
			"launchpad slot unavailable role=%s reason=%s",
			surface_role_name(server->active_slot),
			reason != NULL ? reason : "unspecified");
		clear_keyboard_focus(server);
	}
	schedule_outputs(server);
}

static void set_active_slot(struct engineos_shell_server *server,
		enum engineos_surface_role role, const char *reason) {
	if (!is_launchpad_role(role)) {
		wlr_log(WLR_INFO, "launchpad active slot ignored role=%s reason=%s",
			surface_role_name(role),
			reason != NULL ? reason : "unspecified");
		return;
	}

	server->active_slot = role;
	server->input_mode = role == ENGINEOS_SURFACE_ENGINE ?
		ENGINEOS_INPUT_GAME : ENGINEOS_INPUT_TERMINAL;
	if (server->input_mode == ENGINEOS_INPUT_GAME) {
		server->game_capture =
			find_mapped_role(server, ENGINEOS_SURFACE_ENGINE) != NULL;
	} else {
		server->game_capture = false;
	}

	wlr_log(WLR_INFO,
		"launchpad active slot=%s mode=%s capture=%s reason=%s",
		surface_role_name(server->active_slot),
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		reason != NULL ? reason : "unspecified");
	apply_launchpad_visibility(server, reason);
	if (should_lock_game_cursor(server)) {
		confine_cursor_to_view(server, server->focused_view, reason);
	}
	sync_pointer_constraint(server, reason);
	sync_cursor_image(server, reason);
	write_shell_state(server, reason);
}

static void set_input_mode(struct engineos_shell_server *server,
		enum engineos_input_mode mode, const char *reason) {
	switch (mode) {
	case ENGINEOS_INPUT_SHELL:
		server->input_mode = mode;
		server->game_capture = false;
		wlr_log(WLR_INFO, "input mode=%s capture=%s reason=%s",
			input_mode_name(server->input_mode),
			server->game_capture ? "game" : "none",
			reason != NULL ? reason : "unspecified");
		clear_keyboard_focus(server);
		sync_pointer_constraint(server, reason);
		sync_cursor_image(server, reason);
		write_shell_state(server, reason);
		break;
	case ENGINEOS_INPUT_TERMINAL:
		set_active_slot(server, ENGINEOS_SURFACE_TERMINAL, reason);
		break;
	case ENGINEOS_INPUT_GAME:
		if (find_mapped_role(server, ENGINEOS_SURFACE_ENGINE) != NULL) {
			set_active_slot(server, ENGINEOS_SURFACE_ENGINE, reason);
		} else {
			server->game_capture = false;
			wlr_log(WLR_INFO,
				"input mode request ignored requested=game active_slot=%s capture=none reason=%s engine_mapped=false",
				surface_role_name(server->active_slot),
				reason != NULL ? reason : "unspecified");
			sync_pointer_constraint(server, reason);
			launch_or_activate_slot(server, ENGINEOS_SURFACE_ENGINE, reason);
			write_shell_state(server, "game-mode-engine-unavailable");
		}
		break;
	}
}

static void toggle_game_capture(struct engineos_shell_server *server) {
	if (server->input_mode != ENGINEOS_INPUT_GAME) {
		set_input_mode(server, ENGINEOS_INPUT_GAME, "capture-toggle");
	}
	if (server->input_mode != ENGINEOS_INPUT_GAME ||
			find_mapped_role(server, ENGINEOS_SURFACE_ENGINE) == NULL) {
		server->game_capture = false;
		wlr_log(WLR_INFO,
			"input capture=none mode=%s reason=toggle-ignored engine_mapped=false active_slot=%s",
			input_mode_name(server->input_mode),
			surface_role_name(server->active_slot));
		sync_pointer_constraint(server, "capture-toggle-ignored");
		sync_cursor_image(server, "capture-toggle-ignored");
		write_shell_state(server, "capture-toggle-ignored");
		return;
	}
	server->game_capture = !server->game_capture;
	if (should_lock_game_cursor(server)) {
		confine_cursor_to_view(server, server->focused_view, "capture-toggle");
	}
	sync_pointer_constraint(server, "capture-toggle");
	sync_cursor_image(server, "capture-toggle");
	wlr_log(WLR_INFO, "input capture=%s mode=%s reason=toggle",
		server->game_capture ? "game" : "none",
		input_mode_name(server->input_mode));
	write_shell_state(server, "capture-toggle");
}

static void emergency_release(struct engineos_shell_server *server) {
	server->game_capture = false;
	set_input_mode(server, ENGINEOS_INPUT_SHELL, "emergency-release");
	wlr_log(WLR_INFO, "input emergency-release complete");
}

static void set_view_activated(struct engineos_shell_view *view, bool activated) {
	if (view != NULL && view->xdg_surface != NULL &&
			xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
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
	if (view->minimized) {
		view->minimized = false;
		wlr_scene_node_set_enabled(&view->scene_tree->node, true);
		if (view->xdg_surface != NULL && view->xdg_surface->toplevel != NULL) {
			set_toplevel_suspended(view->xdg_surface->toplevel, false);
		}
		apply_view_layout(view);
	}
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
	if (should_lock_game_cursor(server)) {
		confine_cursor_to_view(server, view, "focus");
	}
	sync_pointer_constraint(server, "focus");
	sync_cursor_image(server, "focus");
	wlr_log(WLR_INFO, "focus view mode=%s capture=%s role=%s title=%s app_id=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		surface_role_name(view->role), view_title(view), view_app_id(view));
}

static void activate_view(struct engineos_shell_view *view, const char *reason) {
	if (view == NULL || !view->mapped) {
		return;
	}

	struct engineos_shell_server *server = view->server;
	if (is_launchpad_role(view->role)) {
		set_active_slot(server, view->role, reason);
		return;
	}

	server->game_capture = false;
	server->input_mode = ENGINEOS_INPUT_TERMINAL;
	if (view->minimized) {
		view->minimized = false;
		wlr_scene_node_set_enabled(&view->scene_tree->node, true);
	}
	focus_view(view);
	sync_pointer_constraint(server, reason);
	sync_cursor_image(server, reason);
	write_shell_state(server, reason);
}

static struct engineos_shell_view *first_mapped_view(
		struct engineos_shell_server *server) {
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (view->mapped) {
			return view;
		}
	}
	return NULL;
}

static void focus_next_window(struct engineos_shell_server *server,
		const char *reason) {
	if (wl_list_empty(&server->views)) {
		return;
	}

	struct engineos_shell_view *view;
	if (server->focused_view == NULL) {
		view = first_mapped_view(server);
		if (view != NULL) {
			activate_view(view, reason);
		}
		return;
	}

	bool after_focused = false;
	wl_list_for_each(view, &server->views, link) {
		if (after_focused && view->mapped) {
			activate_view(view, reason);
			return;
		}
		if (view == server->focused_view) {
			after_focused = true;
		}
	}

	view = first_mapped_view(server);
	if (view != NULL) {
		activate_view(view, reason);
		return;
	}

	wlr_log(WLR_INFO, "window cycle ignored reason=no-mapped-windows trigger=%s",
		reason != NULL ? reason : "unspecified");
}

static void launch_or_activate_slot(struct engineos_shell_server *server,
		enum engineos_surface_role role, const char *reason) {
	struct engineos_shell_view *view = find_mapped_role(server, role);
	if (view != NULL) {
		set_active_slot(server, role, reason);
		return;
	}

	const char *cmd = slot_command(server, role);
	if (cmd == NULL || cmd[0] == '\0') {
		wlr_log(WLR_INFO,
			"launchpad slot unavailable role=%s reason=no-command trigger=%s",
			surface_role_name(role),
			reason != NULL ? reason : "unspecified");
		return;
	}

	server->pending_slot = role;
	wlr_log(WLR_INFO,
		"launchpad slot unavailable role=%s action=launch-requested trigger=%s",
		surface_role_name(role),
		reason != NULL ? reason : "unspecified");
	spawn_command(server, surface_role_name(role), role, cmd);
}

static void nudge_focused_window(struct engineos_shell_server *server,
		int dx, int dy, const char *reason) {
	struct engineos_shell_view *view = server->focused_view;
	if (!is_managed_floating_view(view) || !view->mapped) {
		wlr_log(WLR_INFO, "window move ignored reason=no-floating-focus trigger=%s",
			reason != NULL ? reason : "unspecified");
		return;
	}
	ensure_floating_geometry(view);
	if (view->maximized) {
		set_floating_maximized(view, false, reason);
	}
	view->x += dx;
	view->y += dy;
	save_floating_geometry(view);
	apply_view_layout(view);
	schedule_outputs(server);
	wlr_log(WLR_INFO,
		"window move role=%s x=%d y=%d trigger=%s title=%s app_id=%s",
		surface_role_name(view->role), view->x, view->y,
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
	write_shell_state(server, reason != NULL ? reason : "window-move");
}

static void toggle_focused_maximized(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_shell_view *view = server->focused_view;
	if (!is_managed_floating_view(view) || !view->mapped) {
		wlr_log(WLR_INFO, "window maximize ignored reason=no-floating-focus trigger=%s",
			reason != NULL ? reason : "unspecified");
		return;
	}
	set_floating_maximized(view, !view->maximized, reason);
}

static void minimize_focused_window(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_shell_view *view = server->focused_view;
	if (view == NULL || !view->mapped) {
		wlr_log(WLR_INFO, "window minimize ignored reason=no-focus trigger=%s",
			reason != NULL ? reason : "unspecified");
		return;
	}
	set_view_minimized(view, true, reason);
	if (view->minimized) {
		focus_next_window(server, "minimized-focus-next");
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
	case XKB_KEY_F3:
		if (modifiers == 0 &&
				(server->preview.scene_buffer != NULL ||
				 server->wallpaper.scene_buffer != NULL)) {
			wlr_log(WLR_INFO, "keybinding f3: close image surfaces");
			if (server->preview.scene_buffer != NULL) {
				hide_image_preview(server, "f3-close");
			}
			if (server->wallpaper.scene_buffer != NULL) {
				hide_wallpaper(server, "f3-close");
			}
			return true;
		}
		break;
	default:
		break;
	}

	if (!(modifiers & WLR_MODIFIER_ALT)) {
		return false;
	}

	switch (sym) {
	case XKB_KEY_1:
		wlr_log(WLR_INFO, "keybinding alt+1: terminal slot");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_TERMINAL, "alt+1");
		return true;
	case XKB_KEY_2:
		wlr_log(WLR_INFO, "keybinding alt+2: cube slot");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_CUBE, "alt+2");
		return true;
	case XKB_KEY_3:
		wlr_log(WLR_INFO, "keybinding alt+3: engine slot");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_ENGINE, "alt+3");
		return true;
	case XKB_KEY_4:
		wlr_log(WLR_INFO, "keybinding alt+4: secondary terminal slot");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_TERMINAL_SECONDARY, "alt+4");
		return true;
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
	case XKB_KEY_F9:
		wlr_log(WLR_INFO, "keybinding alt+f9: minimize focused window");
		minimize_focused_window(server, "alt+f9");
		return true;
	case XKB_KEY_F10:
		wlr_log(WLR_INFO, "keybinding alt+f10: maximize focused window");
		toggle_focused_maximized(server, "alt+f10");
		return true;
	case XKB_KEY_c:
	case XKB_KEY_C:
		wlr_log(WLR_INFO, "keybinding alt+c: toggle game capture");
		toggle_game_capture(server);
		return true;
	case XKB_KEY_m:
	case XKB_KEY_M:
	case XKB_KEY_minus:
		wlr_log(WLR_INFO, "keybinding alt+m/minus: minimize focused window");
		minimize_focused_window(server, "alt+minimize");
		return true;
	case XKB_KEY_x:
	case XKB_KEY_X:
		wlr_log(WLR_INFO, "keybinding alt+x: maximize focused window");
		toggle_focused_maximized(server, "alt+x");
		return true;
	case XKB_KEY_Left:
		nudge_focused_window(server, -32, 0, "alt+left");
		return true;
	case XKB_KEY_Right:
		nudge_focused_window(server, 32, 0, "alt+right");
		return true;
	case XKB_KEY_Up:
		nudge_focused_window(server, 0, -32, "alt+up");
		return true;
	case XKB_KEY_Down:
		nudge_focused_window(server, 0, 32, "alt+down");
		return true;
	case XKB_KEY_Return:
		wlr_log(WLR_INFO, "keybinding alt+return: launch terminal");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_TERMINAL, "alt+return");
		return true;
	case XKB_KEY_g:
	case XKB_KEY_G:
		wlr_log(WLR_INFO, "keybinding alt+g: launch engine");
		launch_or_activate_slot(server, ENGINEOS_SURFACE_ENGINE, "alt+g");
		return true;
	case XKB_KEY_Tab:
		wlr_log(WLR_INFO, "keybinding alt+tab: cycle managed windows");
		focus_next_window(server, "alt+tab");
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

	if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
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

static void hide_cursor(struct engineos_shell_server *server,
		const char *reason) {
	if (server == NULL || server->cursor == NULL) {
		return;
	}
	wlr_cursor_unset_image(server->cursor);
	if (!server->cursor_hidden) {
		wlr_log(WLR_INFO, "cursor image=hidden reason=%s",
			reason != NULL ? reason : "unspecified");
	}
	server->cursor_hidden = true;
}

static void set_default_cursor(struct engineos_shell_server *server,
		const char *reason) {
	if (should_lock_game_cursor(server)) {
		hide_cursor(server, reason);
		return;
	}
	if (server->cursor_mgr == NULL) {
		return;
	}
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	if (server->cursor_hidden) {
		wlr_log(WLR_INFO, "cursor image=restored reason=%s",
			reason != NULL ? reason : "unspecified");
	}
	server->cursor_hidden = false;
	wlr_log(WLR_INFO, "cursor image=default reason=%s",
		reason != NULL ? reason : "unspecified");
}

static void sync_cursor_image(struct engineos_shell_server *server,
		const char *reason) {
	if (should_lock_game_cursor(server)) {
		hide_cursor(server, reason);
		return;
	}
	set_default_cursor(server, reason);
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
			sync_cursor_image(server, "capture-no-focused-view");
			return false;
		}
		*view = server->focused_view;
		sync_cursor_image(server, "game-capture");
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

static void send_game_relative_motion(struct engineos_shell_server *server,
		uint32_t time_msec, double dx, double dy,
		double dx_unaccel, double dy_unaccel, const char *reason) {
	if (!should_lock_game_cursor(server) ||
			server->relative_pointer_mgr == NULL) {
		return;
	}

	uint64_t time_usec = (uint64_t)time_msec * 1000;
	wlr_relative_pointer_manager_v1_send_relative_motion(
		server->relative_pointer_mgr, server->seat, time_usec,
		dx, dy, dx_unaccel, dy_unaccel);
	wlr_log(WLR_DEBUG,
		"relative pointer motion role=engine dx=%.2f dy=%.2f reason=%s",
		dx, dy, reason != NULL ? reason : "unspecified");
}

static void update_interactive_move(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_shell_view *view = server->moving_view;
	if (!is_managed_floating_view(view) || !view->mapped) {
		server->moving_view = NULL;
		return;
	}

	view->x = (int)(server->cursor->x - server->move_grab_x);
	view->y = (int)(server->cursor->y - server->move_grab_y);
	save_floating_geometry(view);
	apply_view_layout(view);
	schedule_outputs(server);
	wlr_log(WLR_DEBUG,
		"window interactive-move role=%s x=%d y=%d reason=%s title=%s app_id=%s",
		surface_role_name(view->role), view->x, view->y,
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
}

static void end_interactive_move(struct engineos_shell_server *server,
		const char *reason) {
	if (server->moving_view == NULL) {
		return;
	}
	struct engineos_shell_view *view = server->moving_view;
	server->moving_view = NULL;
	wlr_log(WLR_INFO,
		"window move complete role=%s x=%d y=%d reason=%s title=%s app_id=%s",
		surface_role_name(view->role), view->x, view->y,
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
	write_shell_state(server, reason != NULL ? reason : "window-move-complete");
}

static void cursor_handle_motion(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;

	wlr_cursor_move(server->cursor, &event->pointer->base,
		event->delta_x, event->delta_y);
	if (server->moving_view != NULL) {
		update_interactive_move(server, "pointer-motion");
		return;
	}
	cursor_log_event(server, "motion", event->pointer);
	if (cursor_update_pointer_focus(server, event->time_msec, "motion")) {
		sync_pointer_constraint(server, "motion");
		send_game_relative_motion(server, event->time_msec,
			event->delta_x, event->delta_y,
			event->unaccel_dx, event->unaccel_dy, "motion");
	}
}

static void cursor_handle_motion_absolute(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;

	wlr_cursor_warp_absolute(server->cursor, &event->pointer->base,
		event->x, event->y);
	if (server->moving_view != NULL) {
		update_interactive_move(server, "pointer-motion-absolute");
		return;
	}
	cursor_log_event(server, "motion-absolute", event->pointer);
	cursor_update_pointer_focus(server, event->time_msec, "motion-absolute");
}

static void cursor_handle_button(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;

	cursor_log_event(server, "button", event->pointer);
	if (event->state == WL_POINTER_BUTTON_STATE_RELEASED &&
			server->moving_view != NULL) {
		end_interactive_move(server, "pointer-button-release");
	}
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

	if (should_lock_game_cursor(server)) {
		hide_cursor(server, "client-cursor-request-game-capture");
		wlr_log(WLR_INFO,
			"cursor image request ignored reason=game-capture");
		return;
	}

	if (focused_client == event->seat_client) {
		wlr_cursor_set_surface(server->cursor, event->surface,
			event->hotspot_x, event->hotspot_y);
		server->cursor_hidden = event->surface == NULL;
		wlr_log(WLR_INFO, "cursor image=client hotspot=%d,%d",
			event->hotspot_x, event->hotspot_y);
	} else {
		wlr_log(WLR_INFO, "cursor image request ignored reason=unfocused-client");
	}
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, request_set_selection);
	struct wlr_seat_request_set_selection_event *event = data;

	wlr_seat_set_selection(server->seat, event->source, event->serial);
	wlr_log(WLR_INFO, "clipboard selection accepted source=%s serial=%u",
		event->source != NULL ? "client" : "clear", event->serial);
}

static void seat_request_set_primary_selection(struct wl_listener *listener,
		void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, request_set_primary_selection);
	struct wlr_seat_request_set_primary_selection_event *event = data;

	wlr_seat_set_primary_selection(server->seat, event->source, event->serial);
	wlr_log(WLR_INFO, "primary selection accepted source=%s serial=%u",
		event->source != NULL ? "client" : "clear", event->serial);
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
		output->scene_output = NULL;
	}
	free(output);
}

static void destroy_shell_output(struct engineos_shell_output *output) {
	wl_list_remove(&output->link);
	remove_listener_if_linked(&output->frame);
	remove_listener_if_linked(&output->destroy);
	if (output->scene_output != NULL) {
		wlr_scene_output_destroy(output->scene_output);
		output->scene_output = NULL;
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
	write_shell_state(server, "output-added");
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
	write_shell_state(server, "input-added");
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
	if (is_launchpad_role(view->role)) {
		mark_launch_role_mapped(view->server, view->role);
		bool pending = view->server->pending_slot == view->role;
		struct engineos_layout_request request;
		bool has_layout_request =
			(view->role == ENGINEOS_SURFACE_CUBE ||
				view->role == ENGINEOS_SURFACE_ENGINE) &&
			read_layout_request(view->server, view->role, &request);
		bool pane_layout_launch = has_layout_request && request.pane;
		bool exclusive_layout_launch =
			has_layout_request && (request.output || request.fullscreen);
		if (pending) {
			view->server->pending_slot = ENGINEOS_SURFACE_UNKNOWN;
		}
		if (pending || exclusive_layout_launch ||
				view->role == view->server->active_slot) {
			set_active_slot(view->server, view->role,
				pending ? "pending-slot-mapped" :
				(exclusive_layout_launch ? "layout-request-mapped" :
					"slot-mapped"));
		} else {
			wlr_log(WLR_INFO,
				"launchpad slot mapped inactive role=%s active_slot=%s layout=%s",
				surface_role_name(view->role),
				surface_role_name(view->server->active_slot),
				pane_layout_launch ? "tmux-pane" : "slot");
			apply_launchpad_visibility(view->server,
				pane_layout_launch ? "pane-layout-mapped-inactive" :
					"slot-mapped-inactive");
		}
	} else {
		wlr_log(WLR_INFO, "launchpad unknown view excluded title=%s app_id=%s",
			view_title(view), view_app_id(view));
		wlr_scene_node_set_enabled(&view->scene_tree->node, true);
		if (view->server->input_mode != ENGINEOS_INPUT_SHELL) {
			activate_view(view, "floating-view-mapped");
		}
	}
	wlr_log(WLR_INFO, "view mapped role=%s title=%s app_id=%s mapped_total=%u",
		surface_role_name(view->role), view_title(view), view_app_id(view),
		view->server->view_count);
	write_shell_state(view->server, "view-mapped");
}

static void xdg_surface_unmap(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, unmap);
	view->mapped = false;
	wlr_scene_node_set_enabled(&view->scene_tree->node, false);
	if (view->server->moving_view == view) {
		view->server->moving_view = NULL;
	}
	if (view->server->focused_view == view) {
		view->server->focused_view = NULL;
		set_view_activated(view, false);
		wlr_seat_keyboard_notify_clear_focus(view->server->seat);
	}
	if (view->role == ENGINEOS_SURFACE_ENGINE && view->server->game_capture) {
		view->server->game_capture = false;
		sync_pointer_constraint(view->server, "engine-unmapped");
		sync_cursor_image(view->server, "engine-unmapped");
	}
	if (is_launchpad_role(view->role) &&
			view->server->active_slot == view->role) {
		if (find_mapped_role(view->server, ENGINEOS_SURFACE_CUBE) != NULL) {
			set_active_slot(view->server, ENGINEOS_SURFACE_CUBE, "slot-unmapped");
		} else if (find_mapped_role(view->server, ENGINEOS_SURFACE_TERMINAL) != NULL) {
			set_active_slot(view->server, ENGINEOS_SURFACE_TERMINAL, "slot-unmapped");
		} else if (find_mapped_role(view->server, ENGINEOS_SURFACE_TERMINAL_SECONDARY) != NULL) {
			set_active_slot(view->server, ENGINEOS_SURFACE_TERMINAL_SECONDARY, "slot-unmapped");
		} else if (find_mapped_role(view->server, ENGINEOS_SURFACE_ENGINE) != NULL) {
			set_active_slot(view->server, ENGINEOS_SURFACE_ENGINE, "slot-unmapped");
		}
	} else if (is_launchpad_role(view->role)) {
		apply_launchpad_visibility(view->server, "slot-unmapped");
	}
	schedule_outputs(view->server);
	wlr_log(WLR_INFO, "view unmapped role=%s title=%s app_id=%s",
		surface_role_name(view->role), view_title(view), view_app_id(view));
	write_shell_state(view->server, "view-unmapped");
}

static void xdg_surface_commit(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, commit);
	if (view->xdg_surface->initial_commit &&
			view->xdg_surface->toplevel != NULL) {
		view->role = classify_view_role(view);
		set_toplevel_wm_capabilities(view->xdg_surface->toplevel);
		if (is_launchpad_role(view->role)) {
			struct engineos_view_geometry geometry = {0};
			compute_view_geometry(view, &geometry);
			if (view->role == ENGINEOS_SURFACE_CUBE ||
					view->role == ENGINEOS_SURFACE_ENGINE) {
				set_toplevel_geometry(view->xdg_surface->toplevel, &geometry);
			} else if (xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
				wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
					geometry.width, geometry.height);
			}
		} else {
			struct engineos_view_geometry geometry = {0};
			compute_view_geometry(view, &geometry);
			if (xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
				wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
					geometry.width, geometry.height);
			}
		}
		wlr_log(WLR_INFO, "view initial configure role=%s title=%s app_id=%s",
			surface_role_name(view->role), view_title(view), view_app_id(view));
	}
}

static void xdg_toplevel_request_fullscreen(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_fullscreen);

	if (view->xdg_surface == NULL || view->xdg_surface->toplevel == NULL) {
		return;
	}

	view->fullscreen = view->xdg_surface->toplevel->requested.fullscreen;
	if (is_managed_floating_view(view) && view->fullscreen) {
		save_floating_geometry(view);
		view->maximized = false;
		view->minimized = false;
	}
	wlr_log(WLR_INFO,
		"view fullscreen request role=%s fullscreen=%s title=%s app_id=%s",
		surface_role_name(view->role),
		view->fullscreen ? "true" : "false",
		view_title(view), view_app_id(view));
	apply_view_layout(view);
	if (is_launchpad_role(view->role)) {
		apply_launchpad_visibility(view->server, "fullscreen-request");
	}
	write_shell_state(view->server, "fullscreen-request");
}

static void xdg_toplevel_request_maximize(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_maximize);

	if (view->xdg_surface == NULL || view->xdg_surface->toplevel == NULL) {
		return;
	}

	bool requested = view->xdg_surface->toplevel->requested.maximized;
	if (is_managed_floating_view(view)) {
		view->fullscreen = false;
		set_floating_maximized(view, requested, "maximize-request");
	} else {
		view->maximized = requested;
		if (xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
			wlr_xdg_toplevel_set_maximized(view->xdg_surface->toplevel,
				view->maximized);
		}
		apply_view_layout(view);
		write_shell_state(view->server, "maximize-request");
	}
}

static void xdg_toplevel_request_minimize(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_minimize);

	if (view->xdg_surface == NULL || view->xdg_surface->toplevel == NULL) {
		return;
	}

	set_view_minimized(view,
		view->xdg_surface->toplevel->requested.minimized,
		"minimize-request");
	if (view->minimized) {
		focus_next_window(view->server, "minimized-focus-next");
	}
}

static void xdg_toplevel_request_move(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_move);

	if (!is_managed_floating_view(view) || !view->mapped || view->minimized) {
		wlr_log(WLR_INFO,
			"window move request ignored role=%s reason=not-floating title=%s app_id=%s",
			surface_role_name(view->role), view_title(view), view_app_id(view));
		return;
	}

	ensure_floating_geometry(view);
	if (view->fullscreen) {
		view->fullscreen = false;
		view->x = view->saved_x;
		view->y = view->saved_y;
		view->width = view->saved_width;
		view->height = view->saved_height;
	}
	if (view->maximized) {
		set_floating_maximized(view, false, "move-request-unmaximize");
	}
	int vx = 0;
	int vy = 0;
	if (!wlr_scene_node_coords(&view->scene_tree->node, &vx, &vy)) {
		vx = view->x;
		vy = view->y;
	}
	view->server->moving_view = view;
	view->server->move_grab_x = view->server->cursor->x - vx;
	view->server->move_grab_y = view->server->cursor->y - vy;
	activate_view(view, "move-request");
	wlr_log(WLR_INFO,
		"window move request role=%s grab=%.1f,%.1f title=%s app_id=%s",
		surface_role_name(view->role),
		view->server->move_grab_x, view->server->move_grab_y,
		view_title(view), view_app_id(view));
}

static void xdg_toplevel_request_resize(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_resize);

	if (view->xdg_surface == NULL || view->xdg_surface->toplevel == NULL) {
		return;
	}
	if (xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
		wlr_xdg_toplevel_set_resizing(view->xdg_surface->toplevel, false);
	}
	apply_view_layout(view);
	wlr_log(WLR_INFO,
		"window resize request acknowledged role=%s reason=manual-resize-unimplemented title=%s app_id=%s",
		surface_role_name(view->role), view_title(view), view_app_id(view));
}

static void xdg_toplevel_request_show_window_menu(struct wl_listener *listener,
		void *data) {
	(void)data;
	struct engineos_shell_view *view =
		wl_container_of(listener, view, request_show_window_menu);
	wlr_log(WLR_INFO,
		"window menu request ignored role=%s reason=no-shell-menu title=%s app_id=%s",
		surface_role_name(view->role), view_title(view), view_app_id(view));
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
	if (server->moving_view == view) {
		server->moving_view = NULL;
	}
	if (view->role == ENGINEOS_SURFACE_ENGINE && server->game_capture) {
		server->game_capture = false;
		sync_pointer_constraint(server, "engine-destroyed");
		sync_cursor_image(server, "engine-destroyed");
	}
	if (server->pending_slot == view->role) {
		server->pending_slot = ENGINEOS_SURFACE_UNKNOWN;
	}
	if (view->xdg_surface != NULL) {
		view->xdg_surface->data = NULL;
	}
	if (view->scene_tree != NULL) {
		wlr_scene_node_destroy(&view->scene_tree->node);
	}
	wl_list_remove(&view->link);
	wl_list_remove(&view->map.link);
	wl_list_remove(&view->unmap.link);
	wl_list_remove(&view->commit.link);
	wl_list_remove(&view->destroy.link);
	wl_list_remove(&view->request_maximize.link);
	wl_list_remove(&view->request_fullscreen.link);
	wl_list_remove(&view->request_minimize.link);
	wl_list_remove(&view->request_move.link);
	wl_list_remove(&view->request_resize.link);
	wl_list_remove(&view->request_show_window_menu.link);
	if (server->view_count > 0) {
		server->view_count--;
	}
	if (is_launchpad_role(view->role) && server->active_slot == view->role) {
		if (find_mapped_role(server, ENGINEOS_SURFACE_CUBE) != NULL) {
			set_active_slot(server, ENGINEOS_SURFACE_CUBE, "slot-destroyed");
		} else if (find_mapped_role(server, ENGINEOS_SURFACE_TERMINAL) != NULL) {
			set_active_slot(server, ENGINEOS_SURFACE_TERMINAL, "slot-destroyed");
		} else if (find_mapped_role(server, ENGINEOS_SURFACE_TERMINAL_SECONDARY) != NULL) {
			set_active_slot(server, ENGINEOS_SURFACE_TERMINAL_SECONDARY, "slot-destroyed");
		} else if (find_mapped_role(server, ENGINEOS_SURFACE_ENGINE) != NULL) {
			set_active_slot(server, ENGINEOS_SURFACE_ENGINE, "slot-destroyed");
		}
	}
	write_shell_state(server, "view-destroyed");
	free(view);
}

static void pointer_constraint_new(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_pointer_constraint);
	struct wlr_pointer_constraint_v1 *constraint = data;

	wlr_log(WLR_INFO,
		"pointer constraint requested type=%s capture=%s focus=%s",
		pointer_constraint_type_name(constraint->type),
		server->game_capture ? "game" : "none",
		server->focused_view != NULL ?
			surface_role_name(server->focused_view->role) : "none");
	sync_pointer_constraint(server, "constraint-requested");
}

static void relative_pointer_new(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_relative_pointer);
	struct wlr_relative_pointer_v1 *relative_pointer = data;

	wlr_log(WLR_INFO,
		"relative pointer requested seat=%s focus=%s",
		relative_pointer->seat != NULL && relative_pointer->seat->name != NULL ?
			relative_pointer->seat->name : "(unknown)",
		server->focused_view != NULL ?
			surface_role_name(server->focused_view->role) : "none");
}

static void xdg_popup_commit(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_popup *popup =
		wl_container_of(listener, popup, commit);

	if (popup->xdg_popup->base->initial_commit) {
		wlr_xdg_surface_schedule_configure(popup->xdg_popup->base);
	}
}

static void xdg_popup_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_popup *popup =
		wl_container_of(listener, popup, destroy);

	if (popup->xdg_popup != NULL && popup->xdg_popup->base != NULL) {
		popup->xdg_popup->base->data = NULL;
	}
	wl_list_remove(&popup->commit.link);
	wl_list_remove(&popup->destroy.link);
	free(popup);
}

static void server_new_xdg_popup(struct wl_listener *listener, void *data) {
	(void)listener;
	struct wlr_xdg_popup *xdg_popup = data;
	struct wlr_xdg_surface *parent =
		wlr_xdg_surface_try_from_wlr_surface(xdg_popup->parent);

	if (parent == NULL || parent->data == NULL) {
		wlr_log(WLR_ERROR, "xdg popup missing parent scene tree");
		return;
	}

	struct engineos_shell_popup *popup = calloc(1, sizeof(*popup));
	if (popup == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate xdg popup state");
		return;
	}

	struct wlr_scene_tree *parent_tree = parent->data;
	struct wlr_scene_tree *popup_tree =
		wlr_scene_xdg_surface_create(parent_tree, xdg_popup->base);
	if (popup_tree == NULL) {
		wlr_log(WLR_ERROR, "failed to allocate scene tree for xdg popup");
		free(popup);
		return;
	}

	popup->xdg_popup = xdg_popup;
	xdg_popup->base->data = popup_tree;
	popup->commit.notify = xdg_popup_commit;
	wl_signal_add(&xdg_popup->base->surface->events.commit, &popup->commit);
	popup->destroy.notify = xdg_popup_destroy;
	wl_signal_add(&xdg_popup->events.destroy, &popup->destroy);

	wlr_log(WLR_INFO, "xdg popup created");
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
	xdg_surface->data = view->scene_tree;
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
	view->request_maximize.notify = xdg_toplevel_request_maximize;
	wl_signal_add(&toplevel->events.request_maximize,
		&view->request_maximize);
	view->request_fullscreen.notify = xdg_toplevel_request_fullscreen;
	wl_signal_add(&toplevel->events.request_fullscreen,
		&view->request_fullscreen);
	view->request_minimize.notify = xdg_toplevel_request_minimize;
	wl_signal_add(&toplevel->events.request_minimize,
		&view->request_minimize);
	view->request_move.notify = xdg_toplevel_request_move;
	wl_signal_add(&toplevel->events.request_move, &view->request_move);
	view->request_resize.notify = xdg_toplevel_request_resize;
	wl_signal_add(&toplevel->events.request_resize, &view->request_resize);
	view->request_show_window_menu.notify =
		xdg_toplevel_request_show_window_menu;
	wl_signal_add(&toplevel->events.request_show_window_menu,
		&view->request_show_window_menu);
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
	wlr_log(WLR_INFO,
		"renderer diagnostics backend=%s wlr_renderer=%s wlr_allow_software=%s libgl_always_software=%s",
		getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto",
		getenv("WLR_RENDERER") ? getenv("WLR_RENDERER") : "auto",
		getenv("WLR_RENDERER_ALLOW_SOFTWARE") ? getenv("WLR_RENDERER_ALLOW_SOFTWARE") : "unset",
		getenv("LIBGL_ALWAYS_SOFTWARE") ? getenv("LIBGL_ALWAYS_SOFTWARE") : "unset");

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
	server->data_device_mgr = wlr_data_device_manager_create(server->display);
	if (server->data_device_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create data device manager");
		return false;
	}
	server->primary_selection_mgr =
		wlr_primary_selection_v1_device_manager_create(server->display);
	if (server->primary_selection_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create primary selection manager");
		return false;
	}
	server->data_control_mgr = wlr_data_control_manager_v1_create(server->display);
	if (server->data_control_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create data control manager");
		return false;
	}
	server->relative_pointer_mgr =
		wlr_relative_pointer_manager_v1_create(server->display);
	if (server->relative_pointer_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create relative pointer manager");
		return false;
	}
	server->new_relative_pointer.notify = relative_pointer_new;
	wl_signal_add(&server->relative_pointer_mgr->events.new_relative_pointer,
		&server->new_relative_pointer);
	server->pointer_constraints =
		wlr_pointer_constraints_v1_create(server->display);
	if (server->pointer_constraints == NULL) {
		wlr_log(WLR_ERROR, "failed to create pointer constraints manager");
		return false;
	}
	server->new_pointer_constraint.notify = pointer_constraint_new;
	wl_signal_add(&server->pointer_constraints->events.new_constraint,
		&server->new_pointer_constraint);
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
	server->xdg_shell = wlr_xdg_shell_create(server->display,
		XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION);
	if (server->xdg_shell == NULL) {
		wlr_log(WLR_ERROR, "failed to create xdg-shell global");
		return false;
	}
	server->new_xdg_surface.notify = server_new_xdg_surface;
	wl_signal_add(&server->xdg_shell->events.new_toplevel, &server->new_xdg_surface);
	server->new_xdg_popup.notify = server_new_xdg_popup;
	wl_signal_add(&server->xdg_shell->events.new_popup, &server->new_xdg_popup);

	server->seat = wlr_seat_create(server->display, "seat0");
	if (server->seat == NULL) {
		wlr_log(WLR_ERROR, "failed to create Wayland seat");
		return false;
	}
	server->request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server->seat->events.request_set_cursor,
		&server->request_cursor);
	server->request_set_selection.notify = seat_request_set_selection;
	wl_signal_add(&server->seat->events.request_set_selection,
		&server->request_set_selection);
	server->request_set_primary_selection.notify =
		seat_request_set_primary_selection;
	wl_signal_add(&server->seat->events.request_set_primary_selection,
		&server->request_set_primary_selection);

	server->new_output.notify = server_new_output;
	wl_signal_add(&server->backend->events.new_output, &server->new_output);
	server->new_input.notify = server_new_input;
	wl_signal_add(&server->backend->events.new_input, &server->new_input);

	if (!init_preview_ipc(server)) {
		wlr_log(WLR_ERROR, "failed to initialize image preview ipc");
		return false;
	}

	return true;
}

static void destroy_server(struct engineos_shell_server *server) {
	hide_image_preview(server, "shell-destroy");
	hide_wallpaper(server, "shell-destroy");
	close_preview_ipc(server, false, true);
	if (!wl_list_empty(&server->launches)) {
		struct engineos_shell_launch *launch;
		struct engineos_shell_launch *tmp;
		wl_list_for_each_safe(launch, tmp, &server->launches, link) {
			wlr_log(WLR_INFO,
				"launch action abandoned label=%s role=%s pid=%ld mapped=%s command=%s",
				launch->label, surface_role_name(launch->role),
				(long)launch->pid, launch->mapped ? "true" : "false",
				launch->command);
			free_launch(launch);
		}
	}
	clear_active_pointer_constraint(server, "shell-destroy");
	if (server->display != NULL) {
		wl_display_destroy_clients(server->display);
	}
	remove_listener_if_linked(&server->new_output);
	remove_listener_if_linked(&server->new_input);
	remove_listener_if_linked(&server->new_xdg_surface);
	remove_listener_if_linked(&server->new_xdg_popup);
	remove_listener_if_linked(&server->cursor_motion);
	remove_listener_if_linked(&server->cursor_motion_absolute);
	remove_listener_if_linked(&server->cursor_button);
	remove_listener_if_linked(&server->cursor_axis);
	remove_listener_if_linked(&server->cursor_frame);
	remove_listener_if_linked(&server->request_cursor);
	remove_listener_if_linked(&server->request_set_selection);
	remove_listener_if_linked(&server->request_set_primary_selection);
	remove_listener_if_linked(&server->new_relative_pointer);
	remove_listener_if_linked(&server->new_pointer_constraint);
	remove_listener_if_linked(&server->active_pointer_constraint_destroy);
	if (!wl_list_empty(&server->outputs)) {
		struct engineos_shell_output *output;
		struct engineos_shell_output *tmp;
		wl_list_for_each_safe(output, tmp, &server->outputs, link) {
			destroy_shell_output(output);
		}
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
	free(server->state_file);
	server->state_file = NULL;
	free(server->state_dir);
	server->state_dir = NULL;
}

int main(int argc, char **argv) {
	enum engineos_shell_mode mode = ENGINEOS_SHELL_AUTO;
	struct engineos_shell_server server = {0};
	server.preview_socket_fd = -1;
	wl_list_init(&server.launches);

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
		{"cube", required_argument, NULL, 1003},
		{"terminal-secondary", required_argument, NULL, 1004},
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
		case 1004:
			server.terminal_secondary_cmd = optarg;
			break;
		case 1001:
			server.engine_cmd = optarg;
			break;
		case 1002:
			if (!parse_bootstrap_mode(optarg, &server.bootstrap_mode)) {
				fprintf(stderr,
					"engineos-shell: --bootstrap must be none, terminal, engine, launchpad, or all\n");
				return 2;
			}
			break;
		case 1003:
			server.cube_cmd = optarg;
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
	server.active_slot = ENGINEOS_SURFACE_TERMINAL;
	server.pending_slot = ENGINEOS_SURFACE_UNKNOWN;
	apply_mode_environment(mode);
	wlr_log_init(WLR_DEBUG, NULL);
	if (!init_shell_state_path(&server)) {
		fprintf(stderr, "engineos-shell: failed to allocate shell state paths\n");
		destroy_server(&server);
		return 1;
	}

	if (!setup_server(&server)) {
		destroy_server(&server);
		return 1;
	}

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server.display);
	wl_event_loop_add_signal(event_loop, SIGINT, terminate_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGTERM, terminate_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGHUP, relayout_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGCHLD, reap_child_processes, &server);

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
	setenv("WAYLAND_DISPLAY", socket, 1);

	if (!wlr_backend_start(server.backend)) {
		wlr_log(WLR_ERROR, "failed to start wlroots backend");
		destroy_server(&server);
		return 1;
	}

	if (!wait_for_initial_outputs(&server, 3000)) {
		destroy_server(&server);
		return 1;
	}

	wlr_log(WLR_INFO, "engineos-shell mode=%s backend=%s wayland_display=%s",
		server.mode_name, getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto", socket);
	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=startup",
		input_mode_name(server.input_mode),
		server.game_capture ? "game" : "none");
	wlr_log(WLR_INFO, "launch commands terminal=%s terminal_secondary=%s cube=%s engine=%s startup=%s",
		server.terminal_cmd != NULL ? server.terminal_cmd : "(none)",
		server.terminal_secondary_cmd != NULL ? server.terminal_secondary_cmd : "(none)",
		server.cube_cmd != NULL ? server.cube_cmd : "(none)",
		server.engine_cmd != NULL ? server.engine_cmd : "(none)",
		server.startup_cmd != NULL ? server.startup_cmd : "(none)");
	wlr_log(WLR_INFO, "bootstrap mode=%s",
		bootstrap_mode_name(server.bootstrap_mode));
	wlr_log(WLR_INFO,
		"client launch environment wayland_display=%s xdg_session_type=wayland display=unset sdl=wayland gdk=wayland qt=wayland",
		socket);
	write_shell_state(&server, "startup");
	spawn_command(&server, "startup", ENGINEOS_SURFACE_UNKNOWN,
		server.startup_cmd);
	if (server.bootstrap_mode == ENGINEOS_BOOTSTRAP_TERMINAL) {
		set_active_slot(&server, ENGINEOS_SURFACE_TERMINAL, "bootstrap-terminal");
		spawn_command(&server, "bootstrap-terminal",
			ENGINEOS_SURFACE_TERMINAL, server.terminal_cmd);
		spawn_command(&server, "bootstrap-terminal-secondary",
			ENGINEOS_SURFACE_TERMINAL_SECONDARY, server.terminal_secondary_cmd);
	}
	if (server.bootstrap_mode == ENGINEOS_BOOTSTRAP_ENGINE) {
		set_active_slot(&server, ENGINEOS_SURFACE_ENGINE, "bootstrap-engine");
		spawn_command(&server, "bootstrap-engine",
			ENGINEOS_SURFACE_ENGINE, server.engine_cmd);
	}
	if (server.bootstrap_mode == ENGINEOS_BOOTSTRAP_LAUNCHPAD) {
		set_active_slot(&server, ENGINEOS_SURFACE_CUBE, "bootstrap-launchpad");
		spawn_command(&server, "bootstrap-terminal",
			ENGINEOS_SURFACE_TERMINAL, server.terminal_cmd);
		spawn_command(&server, "bootstrap-terminal-secondary",
			ENGINEOS_SURFACE_TERMINAL_SECONDARY, server.terminal_secondary_cmd);
		spawn_command(&server, "bootstrap-cube",
			ENGINEOS_SURFACE_CUBE, server.cube_cmd);
		spawn_command(&server, "bootstrap-engine",
			ENGINEOS_SURFACE_ENGINE, server.engine_cmd);
	}

	wl_display_run(server.display);
	wlr_log(WLR_INFO, "engineos-shell shutdown outputs=%u keyboards=%u pointers=%u views=%u",
		server.output_count, server.keyboard_count, server.pointer_count, server.view_count);
	write_shell_state(&server, "shutdown");
	destroy_server(&server);
	return 0;
}
