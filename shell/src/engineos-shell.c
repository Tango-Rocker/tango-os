#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/input-event-codes.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/interfaces/wlr_pointer.h>
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
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

#include "engineos-image.h"
#include "engineos-mux-client.h"
#include "engineos-terminal-renderer.h"
#include "engineos-terminal-theme.h"
#include "engineos-tmux-key.h"

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
	ENGINEOS_SURFACE_MUX_PRESENTATION,
};

enum engineos_input_mode {
	ENGINEOS_INPUT_SHELL,
	ENGINEOS_INPUT_TERMINAL,
	ENGINEOS_INPUT_GRAPHICAL,
	ENGINEOS_INPUT_GAME,
};

enum engineos_pointer_target {
	ENGINEOS_POINTER_NONE,
	ENGINEOS_POINTER_TMUX_UI,
	ENGINEOS_POINTER_TMUX_PANE,
	ENGINEOS_POINTER_WAYLAND_SURFACE,
};

struct engineos_view_geometry {
	int x;
	int y;
	int width;
	int height;
	bool fullscreen;
	const char *layout;
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
	struct wl_list link;
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
	bool native_pane;
	bool mux_owned;
	uint32_t pane_id;
	uint32_t pane_generation;
	uint32_t mux_image_id;
	uint32_t lease_client_id;
	uint32_t lease_view_id;
};

struct engineos_preview_failure {
	struct wl_list link;
	uint32_t pane_id;
	uint32_t pane_generation;
	uint32_t image_id;
};

enum engineos_preview_create_result {
	ENGINEOS_PREVIEW_CREATED,
	ENGINEOS_PREVIEW_DEFERRED,
	ENGINEOS_PREVIEW_ISOLATED_FAILURE,
	ENGINEOS_PREVIEW_FATAL,
};

struct engineos_mux_pane_output_scene {
	struct wl_list link;
	struct engineos_shell_output *output;
	struct wlr_scene_tree *tree;
	struct wlr_scene_buffer *terminal_scene;
	struct wlr_buffer *buffer;
	struct engineos_terminal_renderer *renderer;
	struct engineos_terminal_render_stats stats;
};

struct engineos_mux_pane_scene {
	struct wl_list link;
	struct wl_list output_scenes;
	uint32_t pane_id;
	uint32_t generation;
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
	struct wlr_screencopy_manager_v1 *screencopy_mgr;
	struct wlr_output_layout *output_layout;
	struct wlr_xdg_output_manager_v1 *xdg_output_mgr;
	struct wlr_cursor *cursor;
	struct wlr_xcursor_manager *cursor_mgr;
	struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
	struct wlr_pointer_constraints_v1 *pointer_constraints;
	struct wlr_pointer_constraint_v1 *active_pointer_constraint;
	struct wlr_pointer test_pointer;
	bool test_pointer_initialized;
	struct wlr_scene *scene;
	struct wlr_scene_tree *mux_pane_tree;
	struct wl_list mux_pane_scenes;
	struct wlr_scene_buffer *mux_ui_scene;
	struct wlr_scene_buffer *mux_terminal_scene;
	struct wlr_buffer *mux_terminal_buffer;
	struct engineos_terminal_renderer *mux_terminal_renderer;
	struct engineos_terminal_theme terminal_theme;
	char terminal_theme_source[32];
	char terminal_theme_error[256];
	int mux_terminal_width;
	int mux_terminal_height;
	uint32_t mux_terminal_glyph_cells;
	uint32_t mux_terminal_atlas_entries;
	uint32_t mux_terminal_damaged_cells;
	uint32_t mux_terminal_nonblank_pixels;
	uint64_t mux_terminal_frame;
	uint32_t mux_pointer_button;
	uint32_t mux_pointer_view_id;
	uint32_t mux_pointer_x;
	uint32_t mux_pointer_y;
	uint32_t mux_popup_count;
	enum engineos_pointer_target pointer_grab_target;
	bool pointer_grab_active;
	uint32_t keyboard_modifiers;
	uint32_t mux_consumed_keycode;
	bool mux_prefix_pending;
	bool mux_pointer_cell_valid;
	struct wl_event_source *mux_event_source;
	struct wl_event_source *mux_snapshot_retry_timer;
	struct wl_event_source *terminal_blink_timer;
	struct wl_list outputs;
	struct wl_list views;
	struct wl_list keyboards;
	struct wl_list pointers;
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
	struct wl_listener request_start_drag;
	struct wl_listener start_drag;
	struct wl_listener active_drag_motion;
	struct wl_listener active_drag_drop;
	struct wl_listener active_drag_destroy;
	struct wl_listener drag_icon_node_destroy;
	struct wl_listener new_relative_pointer;
	struct wl_listener new_pointer_constraint;
	struct wl_listener active_pointer_constraint_destroy;
	struct wlr_drag *active_drag;
	struct wlr_scene_tree *drag_icon_tree;
	struct engineos_shell_view *focused_view;
	struct engineos_shell_view *moving_view;
	double move_grab_x;
	double move_grab_y;
	const char *mode_name;
	char *state_dir;
	char *state_file;
	char *preview_socket_path;
	struct wl_event_source *preview_socket_source;
	int preview_socket_fd;
	struct wl_list previews;
	struct wl_list preview_failures;
	struct engineos_preview_surface wallpaper;
	struct engineos_mux_client mux_client;
	enum engineos_input_mode input_mode;
	bool game_capture;
	bool emergency_released;
	bool cursor_hidden;
	bool cursor_client_owned;
	int smoke_ms;
	unsigned int output_count;
	unsigned int keyboard_count;
	unsigned int pointer_count;
	unsigned int view_count;
	unsigned int next_view_id;
	uint32_t next_mux_view_id;
	uint64_t mux_snapshot_retry_count;
	bool mux_image_resync_pending;
	char preview_reconciliation_status[32];
	char preview_reconciliation_error[256];
	uint32_t preview_failed_pane_id;
	uint32_t preview_failed_generation;
	uint32_t preview_failed_image_id;
};

struct engineos_shell_keyboard {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_input_device *device;
	struct wlr_keyboard *keyboard;
	struct wl_event_source *terminal_repeat_timer;
	uint32_t terminal_repeat_keycode;
	xkb_keysym_t terminal_repeat_sym;
	uint32_t terminal_repeat_modifiers;
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
	struct engineos_shell_server *server;
	struct engineos_shell_view *owner;
	struct wlr_xdg_popup *xdg_popup;
	struct wlr_scene_tree *scene_tree;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener commit;
	struct wl_listener destroy;
	pid_t client_pid;
	uint32_t surface_id;
	bool mapped;
	bool mux_bound;
};

struct engineos_shell_output {
	struct wl_list link;
	struct engineos_shell_server *server;
	struct wlr_output *output;
	struct wlr_scene_output *scene_output;
	struct wl_listener frame;
	struct wl_listener destroy;
	struct wlr_scene_tree *mux_scene_tree;
	struct wlr_scene_buffer *mux_ui_scene;
	struct engineos_terminal_renderer *mux_ui_renderer;
	struct engineos_terminal_render_stats mux_ui_stats;
	struct engineos_mux_view_snapshot mux_snapshot;
	uint64_t frame_commits;
	uint64_t frame_failures;
	uint64_t scheduled_mux_revision;
	uint64_t scheduled_grid_revision;
	uint64_t scheduled_renderer_frame;
	uint64_t committed_mux_revision;
	uint64_t committed_grid_revision;
	uint64_t committed_renderer_frame;
	uint32_t mux_view_id;
	bool mux_registered;
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
	unsigned int view_id;
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
	bool mux_bound;
	bool mux_transient;
	struct engineos_shell_view *mux_parent;
	bool mux_presentation_visible;
	pid_t mux_client_pid;
	uint32_t mux_pane_id;
	uint32_t mux_pane_generation;
};


static const char *view_title(struct engineos_shell_view *view);
static const char *view_app_id(struct engineos_shell_view *view);
static const char *surface_role_name(enum engineos_surface_role role);
static char *join_state_path(const char *dir, const char *name);
static bool mkdir_p(const char *path, mode_t mode);
static bool compute_view_geometry(struct engineos_shell_view *view,
	struct engineos_view_geometry *geometry);
static bool is_managed_floating_view(struct engineos_shell_view *view);
static struct engineos_mux_pane_scene *find_mux_pane_scene(
	struct engineos_shell_server *server, uint32_t pane_id,
	uint32_t generation);
static struct engineos_mux_pane_output_scene *find_mux_pane_output_scene(
	struct engineos_mux_pane_scene *pane_scene, uint32_t view_id);
static struct engineos_mux_pane_model *find_shell_pane_model(
	struct engineos_shell_server *server, uint32_t pane_id,
	uint32_t generation);
static bool sync_native_preview_leases(struct engineos_shell_server *server,
	const char *reason);
static bool refresh_native_output_snapshots(
	struct engineos_shell_server *server, bool *grid_changed,
	char *error, size_t error_size);
static int native_mux_snapshot_retry(void *data);
static void apply_view_layout(struct engineos_shell_view *view);
static void schedule_outputs(struct engineos_shell_server *server);
static void set_toplevel_suspended(struct wlr_xdg_toplevel *toplevel,
	bool suspended);
static void clear_keyboard_focus(struct engineos_shell_server *server);
static void clear_pointer_focus(struct engineos_shell_server *server,
	const char *reason);
static void update_drag_icon_position(struct engineos_shell_server *server,
	const char *reason);
static bool game_capture_active(struct engineos_shell_server *server);
static bool active_pointer_constraint_is_locked(
	struct engineos_shell_server *server);
static void sync_cursor_image(struct engineos_shell_server *server,
	const char *reason);
static bool confine_cursor_to_view(struct engineos_shell_server *server,
	struct engineos_shell_view *view, const char *reason);
static void sync_pointer_constraint(struct engineos_shell_server *server,
	const char *reason);
static void set_view_activated(struct engineos_shell_view *view, bool activated);
static void focus_view(struct engineos_shell_view *view);
static void activate_view(struct engineos_shell_view *view, const char *reason);
static void relayout_shell_views(struct engineos_shell_server *server,
	const char *reason);
static void hide_image_preview(struct engineos_shell_server *server,
	const char *reason);
static void write_shell_state(struct engineos_shell_server *server,
	const char *reason);
static struct engineos_shell_view *native_presentation_root(
	struct engineos_shell_view *view);
static bool init_preview_ipc(struct engineos_shell_server *server);
static void close_preview_ipc(struct engineos_shell_server *server,
	bool unlink_socket, bool free_path);
static void server_new_pointer(struct engineos_shell_server *server,
	struct wlr_input_device *device);

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
		"Usage: %s [--headless|--nested|--tty] [--smoke] [--smoke-ms N]\n"
		"\n"
		"Start the EngineOS wlroots compositor.\n"
		"\n"
		"Options:\n"
		"  --headless      prefer the wlroots headless backend\n"
		"  --nested        prefer Wayland or X11 nesting\n"
		"  --tty           prefer direct DRM/libinput backends\n"
		"  --smoke         start and exit after one second\n"
		"  --smoke-ms N    start and exit after N milliseconds\n"
		"  --version       print version\n"
		"  --help          print this help\n",
		argv0);
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
	relayout_shell_views(server, "layout-sync-signal");
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
	case ENGINEOS_SURFACE_MUX_PRESENTATION:
		return "mux-presentation";
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
	case ENGINEOS_INPUT_GRAPHICAL:
		return "graphical";
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

static void primary_output_geometry(struct engineos_shell_server *server,
		int *x, int *y, int *width, int *height) {
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

		if (candidate_x < selected_x) {
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
	return view != NULL;
}

static void ensure_floating_geometry(struct engineos_shell_view *view) {
	if (view == NULL || view->has_floating_geometry) {
		return;
	}

	int output_x = 0;
	int output_y = 0;
	int output_width = 1280;
	int output_height = 720;
	primary_output_geometry(view->server,
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
	primary_output_geometry(view->server,
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
	view->minimized = minimized;
	wlr_scene_node_set_enabled(&view->scene_tree->node, !minimized);
	if (view->xdg_surface != NULL && view->xdg_surface->toplevel != NULL) {
		set_toplevel_suspended(view->xdg_surface->toplevel, minimized);
	}
	if (minimized && view->server->focused_view == view) {
		view->server->focused_view = NULL;
		set_view_activated(view, false);
		wlr_seat_keyboard_notify_clear_focus(view->server->seat);
		sync_pointer_constraint(view->server, "focused-view-minimized");
		sync_cursor_image(view->server, "focused-view-minimized");
	}
	wlr_log(WLR_INFO,
		"window minimize role=%s minimized=%s reason=%s title=%s app_id=%s",
		surface_role_name(view->role), minimized ? "true" : "false",
		reason != NULL ? reason : "unspecified",
		view_title(view), view_app_id(view));
	schedule_outputs(view->server);
	write_shell_state(view->server, reason != NULL ? reason : "window-minimize");
}

static bool compute_view_geometry(struct engineos_shell_view *view,
		struct engineos_view_geometry *geometry) {
	geometry->x = 40;
	geometry->y = 40;
	geometry->width = 0;
	geometry->height = 0;
	geometry->fullscreen = view->fullscreen;
	geometry->layout = "floating";
	if (view->mux_bound) {
		struct engineos_mux_pane_model *pane = find_shell_pane_model(
			view->server, view->mux_pane_id, view->mux_pane_generation);
		struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(
			view->server, view->mux_pane_id, view->mux_pane_generation);
		struct engineos_mux_pane_output_scene *output_scene = pane_scene != NULL &&
			pane != NULL && pane->lease_client_id ==
				view->server->mux_client.frontend_client_id ?
			find_mux_pane_output_scene(pane_scene, pane->lease_view_id) : NULL;
		if (output_scene == NULL || output_scene->stats.width <= 0 ||
				output_scene->stats.height <= 0)
			return false;
		int pane_width = output_scene->stats.width;
		int pane_height = output_scene->stats.height;
		geometry->width = pane_width;
		geometry->height = pane_height;
		if (view->mux_transient) {
			int requested_width = view->xdg_surface->surface->current.width;
			int requested_height = view->xdg_surface->surface->current.height;
			geometry->width = requested_width > 0 ? requested_width :
				(pane_width * 2) / 3;
			geometry->height = requested_height > 0 ? requested_height :
				(pane_height * 2) / 3;
			if (geometry->width > (pane_width * 3) / 4)
				geometry->width = (pane_width * 3) / 4;
			if (geometry->height > (pane_height * 3) / 4)
				geometry->height = (pane_height * 3) / 4;
			geometry->x = (pane_width - geometry->width) / 2;
			geometry->y = (pane_height - geometry->height) / 2;
		} else {
			geometry->x = 0;
			geometry->y = 0;
		}
		geometry->fullscreen = false;
		geometry->layout = "native-mux-presentation";
		return geometry->width > 0 && geometry->height > 0;
	}

	return false;
}

static bool view_geometry_visible(struct engineos_shell_server *server,
		struct engineos_shell_view *view,
		const struct engineos_view_geometry *geometry) {
	(void)geometry;
	if (view == NULL || !view->mapped) {
		return false;
	}
	if (view->minimized) {
		return false;
	}
	if (view->mux_bound) {
		struct engineos_mux_pane_model *pane = find_shell_pane_model(server,
			view->mux_pane_id, view->mux_pane_generation);
		return view->mux_presentation_visible && pane != NULL &&
			pane->presentation_mapped && pane->lease_client_id ==
				server->mux_client.frontend_client_id &&
			pane->lease_view_id != 0 &&
			strcmp(pane->view_mode, "presentation") == 0;
	}
	return false;
}

static bool view_geometry_render_enabled(struct engineos_shell_server *server,
		struct engineos_shell_view *view,
		const struct engineos_view_geometry *geometry) {
	if (view == NULL || !view->mapped || view->minimized) {
		return false;
	}
	return view_geometry_visible(server, view, geometry);
}

static struct engineos_shell_view *find_mapped_view_id(
		struct engineos_shell_server *server,
		unsigned int view_id) {
	if (view_id == 0) {
		return NULL;
	}
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (view->mapped && view->view_id == view_id) {
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

static void write_preview_json(FILE *file,
		const struct engineos_preview_surface *preview) {
	fprintf(file, "{\"visible\": %s, \"path\": ",
		preview != NULL && preview->scene_buffer != NULL &&
		preview->scene_buffer->node.enabled ? "true" : "false");
	json_write_string(file, preview != NULL ? preview->path : NULL);
	fprintf(file, ", \"owner\": ");
	json_write_string(file, preview != NULL ? preview->owner : NULL);
	fprintf(file,
		", \"native_pane\": %s, \"mux_owned\": %s, \"mux_image_id\": %u, \"pane_id\": \"%%%u\", \"generation\": %u, \"lease_client_id\": %u, \"lease_view_id\": %u, \"x\": %d, \"y\": %d, \"width\": %d, \"height\": %d, \"image_width\": %d, \"image_height\": %d}",
		preview != NULL && preview->native_pane ? "true" : "false",
		preview != NULL && preview->mux_owned ? "true" : "false",
		preview != NULL ? preview->mux_image_id : 0,
		preview != NULL ? preview->pane_id : 0,
		preview != NULL ? preview->pane_generation : 0,
		preview != NULL ? preview->lease_client_id : 0,
		preview != NULL ? preview->lease_view_id : 0,
		preview != NULL ? preview->x : 0,
		preview != NULL ? preview->y : 0,
		preview != NULL ? preview->width : 0,
		preview != NULL ? preview->height : 0,
		preview != NULL ? preview->image_width : 0,
		preview != NULL ? preview->image_height : 0);
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

static bool json_extract_string(struct json_object *json, const char *key,
		char *out, size_t out_size) {
	struct json_object *value = NULL;
	if (json == NULL || key == NULL ||
			!json_object_object_get_ex(json, key, &value) ||
			!json_object_is_type(value, json_type_string)) {
		return false;
	}
	const char *text = json_object_get_string(value);
	if (text == NULL || strlen(text) >= out_size) {
		return false;
	}
	snprintf(out, out_size, "%s", text);
	return true;
}

static bool json_extract_int(struct json_object *json, const char *key,
		int *out) {
	struct json_object *value = NULL;
	if (json == NULL || key == NULL ||
			!json_object_object_get_ex(json, key, &value) ||
			!json_object_is_type(value, json_type_int)) {
		return false;
	}
	int64_t parsed = json_object_get_int64(value);
	if (parsed < 0 || parsed > INT_MAX) {
		return false;
	}
	*out = (int)parsed;
	return true;
}

static bool json_extract_double(struct json_object *json, const char *key,
		double *out) {
	struct json_object *value = NULL;
	if (json == NULL || key == NULL ||
			!json_object_object_get_ex(json, key, &value) ||
			(!json_object_is_type(value, json_type_double) &&
			 !json_object_is_type(value, json_type_int))) {
		return false;
	}
	double parsed = json_object_get_double(value);
	if (!isfinite(parsed)) {
		return false;
	}
	*out = parsed;
	return true;
}

static bool request_preview_bounds(struct json_object *json,
		struct engineos_preview_bounds *bounds) {
	memset(bounds, 0, sizeof(*bounds));
	struct json_object *value = NULL;
	if (json == NULL || !json_object_object_get_ex(json, "bounds", &value) ||
			!json_object_is_type(value, json_type_object) ||
			!json_extract_int(value, "x", &bounds->x) ||
			!json_extract_int(value, "y", &bounds->y) ||
			!json_extract_int(value, "width", &bounds->width) ||
			!json_extract_int(value, "height", &bounds->height)) {
		return false;
	}
	json_extract_int(value, "window_width", &bounds->window_width);
	json_extract_int(value, "window_height", &bounds->window_height);
	if (bounds->width <= 0 || bounds->height <= 0) {
		return false;
	}
	bounds->set = true;
	return true;
}

static int request_opacity_percent(struct json_object *json, int fallback) {
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

static bool compute_preview_box(struct engineos_shell_server *server,
		const char *slot,
		const struct engineos_preview_bounds *bounds,
		struct engineos_view_geometry *box) {
	(void)slot;
	struct engineos_view_geometry output = {0};
	primary_output_geometry(server,
		&output.x, &output.y, &output.width, &output.height);

	*box = output;
	box->layout = "preview";
	box->fullscreen = false;

	if (bounds != NULL && bounds->set &&
			bounds->window_width > 0 && bounds->window_height > 0) {
		box->x = output.x + (int)((long)output.width * bounds->x /
			bounds->window_width);
		box->y = output.y + (int)((long)output.height * bounds->y /
			bounds->window_height);
		box->width = (int)((long)output.width * bounds->width /
			bounds->window_width);
		box->height = (int)((long)output.height * bounds->height /
			bounds->window_height);
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
	surface->native_pane = false;
	surface->mux_owned = false;
	surface->pane_id = 0;
	surface->pane_generation = 0;
	surface->mux_image_id = 0;
	surface->lease_client_id = 0;
	surface->lease_view_id = 0;
}

static struct engineos_mux_pane_scene *find_mux_pane_scene(
		struct engineos_shell_server *server, uint32_t pane_id,
		uint32_t generation) {
	struct engineos_mux_pane_scene *scene;
	wl_list_for_each(scene, &server->mux_pane_scenes, link) {
		if (scene->pane_id == pane_id && scene->generation == generation)
			return scene;
	}
	return NULL;
}

static struct engineos_mux_pane_model *find_output_pane_model(
		struct engineos_shell_output *output, uint32_t pane_id,
		uint32_t generation) {
	for (size_t index = 0; index < output->mux_snapshot.pane_count; index++) {
		struct engineos_mux_pane_model *pane =
			&output->mux_snapshot.panes[index];
		if (pane->pane_id == pane_id && pane->generation == generation)
			return pane;
	}
	return NULL;
}

static struct engineos_shell_output *focused_mux_output(
		struct engineos_shell_server *server) {
	if (server == NULL || server->mux_client.primary_view_id == 0)
		return NULL;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (output->mux_registered && output->mux_snapshot.ready &&
				output->mux_view_id == server->mux_client.primary_view_id)
			return output;
	}
	return NULL;
}

static struct engineos_mux_pane_model *focused_mux_pane(
		struct engineos_shell_server *server) {
	struct engineos_shell_output *output = focused_mux_output(server);
	return output != NULL ? find_output_pane_model(output,
		output->mux_snapshot.pane_id,
		output->mux_snapshot.pane_generation) : NULL;
}

static struct engineos_shell_output *output_for_pane_model(
		struct engineos_shell_server *server,
		const struct engineos_mux_pane_model *pane) {
	if (pane == NULL)
		return NULL;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		for (size_t index = 0; output->mux_registered &&
				index < output->mux_snapshot.pane_count; index++) {
			if (&output->mux_snapshot.panes[index] == pane)
				return output;
		}
	}
	return NULL;
}

static struct engineos_mux_pane_model *find_shell_pane_model(
		struct engineos_shell_server *server, uint32_t pane_id,
		uint32_t generation) {
	struct engineos_shell_output *output;
	struct engineos_mux_pane_model *fallback = NULL;
	wl_list_for_each(output, &server->outputs, link) {
		if (!output->mux_registered || !output->mux_snapshot.ready)
			continue;
		struct engineos_mux_pane_model *pane = find_output_pane_model(output,
			pane_id, generation);
		if (pane == NULL)
			continue;
		if (pane->lease_client_id == server->mux_client.frontend_client_id &&
				pane->lease_view_id == output->mux_view_id)
			return pane;
		if (output->mux_view_id == server->mux_client.primary_view_id)
			return pane;
		if (fallback == NULL)
			fallback = pane;
	}
	if (fallback != NULL)
		return fallback;
	for (size_t index = 0; index < server->mux_client.pane_count; index++) {
		struct engineos_mux_pane_model *pane = &server->mux_client.panes[index];
		if (pane->pane_id == pane_id && pane->generation == generation)
			return pane;
	}
	return NULL;
}

static bool pane_render_client(struct engineos_shell_server *server,
		const struct engineos_mux_pane_model *pane,
		struct engineos_mux_client *render_client) {
	*render_client = server->mux_client;
	if (pane->pane_id != server->mux_client.pane_id ||
			pane->generation != server->mux_client.pane_generation) {
		struct engineos_mux_pane_model *grid =
			engineos_mux_client_view_pane_grid(&server->mux_client, pane);
		if (grid == NULL || !grid->grid.ready || grid->grid.cells == NULL)
			return false;
		render_client->grid_revision = grid->grid.revision;
		render_client->grid_columns = grid->grid.columns;
		render_client->grid_rows = grid->grid.rows;
		render_client->grid_cursor_x = grid->grid.cursor_x;
		render_client->grid_cursor_y = grid->grid.cursor_y;
		render_client->grid_nonblank_cells = grid->grid.nonblank_cells;
		render_client->grid_flags = grid->grid.flags;
		render_client->grid_cells = grid->grid.cells;
		render_client->grid_damage_cells = grid->grid.damage_cells;
		render_client->grid_damage_count = grid->grid.damage_count;
		render_client->grid_full_damage = grid->grid.full_damage;
	}
	if (render_client->grid_cells == NULL ||
			render_client->grid_columns == 0 || render_client->grid_rows == 0)
		return false;
	render_client->ui_columns = 0;
	render_client->ui_rows = 0;
	render_client->ui_status_y = -1;
	render_client->ui_status_rows = NULL;
	render_client->ui_status_row_count = 0;
	render_client->ui_menu_active = false;
	render_client->ui_menu_rows = NULL;
	render_client->ui_menu_row_count = 0;
	render_client->ui_changed = false;
	return true;
}

static void view_ui_render_client(struct engineos_shell_server *server,
		const struct engineos_mux_ui_model *ui,
		struct engineos_mux_client *render_client) {
	*render_client = server->mux_client;
	render_client->ui_columns = ui->columns;
	render_client->ui_rows = ui->rows;
	render_client->ui_status_y = ui->status_y;
	render_client->ui_status_rows = ui->status_rows;
	render_client->ui_status_row_count = ui->status_row_count;
	render_client->ui_menu_x = ui->menu_x;
	render_client->ui_menu_y = ui->menu_y;
	render_client->ui_menu_width = ui->menu_width;
	render_client->ui_menu_height = ui->menu_height;
	render_client->ui_menu_rows = ui->menu_rows;
	render_client->ui_menu_row_count = ui->menu_row_count;
	strcpy(render_client->ui_mode, ui->mode);
	render_client->ui_prompt_active = ui->prompt_active;
	render_client->ui_message_active = ui->message_active;
	render_client->ui_menu_active = ui->menu_active;
	render_client->ui_changed = ui->changed;
	render_client->grid_columns = 0;
	render_client->grid_rows = 0;
	render_client->grid_cursor_x = 0;
	render_client->grid_cursor_y = 0;
	render_client->grid_nonblank_cells = 0;
	render_client->grid_flags = 0;
	render_client->grid_cells = NULL;
	render_client->grid_damage_cells = NULL;
	render_client->grid_damage_count = 0;
	render_client->grid_full_damage = true;
}

static void set_terminal_scene_buffer(
		struct wlr_scene_buffer *scene_buffer,
		struct engineos_terminal_renderer *renderer) {
	struct wlr_scene_buffer_set_buffer_options options = {
		.damage = engineos_terminal_renderer_damage(renderer),
		.wait_timeline = engineos_terminal_renderer_wait_timeline(renderer),
		.wait_point = engineos_terminal_renderer_wait_point(renderer),
	};
	wlr_scene_buffer_set_buffer_with_options(scene_buffer,
		engineos_terminal_renderer_buffer(renderer), &options);
}

static bool scene_overlay_rejects_pointer_input(
		struct wlr_scene_buffer *buffer, double *sx, double *sy) {
	(void)buffer;
	(void)sx;
	(void)sy;
	return false;
}

static bool create_mux_pane_scene(struct engineos_shell_server *server,
		struct engineos_mux_pane_model *pane, char *error, size_t error_size) {
	(void)server;
	struct engineos_mux_pane_scene *scene = calloc(1, sizeof(*scene));
	if (scene == NULL) {
		snprintf(error, error_size, "out of memory creating pane scene");
		return false;
	}
	scene->pane_id = pane->pane_id;
	scene->generation = pane->generation;
	wl_list_init(&scene->output_scenes);
	wl_list_insert(server->mux_pane_scenes.prev, &scene->link);
	return true;
}

static struct engineos_mux_pane_output_scene *find_mux_pane_output_scene(
		struct engineos_mux_pane_scene *pane_scene, uint32_t view_id) {
	struct engineos_mux_pane_output_scene *output_scene;
	wl_list_for_each(output_scene, &pane_scene->output_scenes, link) {
		if (output_scene->output->mux_view_id == view_id)
			return output_scene;
	}
	return NULL;
}

static void destroy_mux_pane_output_scene(
		struct engineos_shell_server *server,
		struct engineos_mux_pane_scene *pane_scene,
		struct engineos_mux_pane_output_scene *output_scene) {
	struct engineos_preview_surface *preview;
	wl_list_for_each(preview, &server->previews, link) {
		if (preview->scene_buffer == NULL || output_scene->tree == NULL ||
				preview->scene_buffer->node.parent != output_scene->tree)
			continue;
		wlr_scene_node_reparent(&preview->scene_buffer->node,
			&server->scene->tree);
		wlr_scene_node_set_enabled(&preview->scene_buffer->node, false);
	}
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (!view->mux_bound || view->mux_pane_id != pane_scene->pane_id ||
				view->mux_pane_generation != pane_scene->generation ||
				view->scene_tree == NULL || output_scene->tree == NULL ||
				view->scene_tree->node.parent != output_scene->tree)
			continue;
		wlr_scene_node_reparent(&view->scene_tree->node, &server->scene->tree);
		wlr_scene_node_set_enabled(&view->scene_tree->node, false);
		view->mux_presentation_visible = false;
	}
	if (output_scene->tree != NULL)
		wlr_scene_node_destroy(&output_scene->tree->node);
	engineos_terminal_renderer_destroy(output_scene->renderer);
	wl_list_remove(&output_scene->link);
	free(output_scene);
}

static bool pane_presentation_owned_by_output(
		const struct engineos_shell_server *server,
		const struct engineos_mux_pane_model *pane,
		const struct engineos_shell_output *output) {
	return output != NULL && output->mux_registered &&
		pane->presentation_mapped &&
		pane->lease_client_id == server->mux_client.frontend_client_id &&
		pane->lease_view_id == output->mux_view_id &&
		strcmp(pane->view_mode, "presentation") == 0;
}

static bool create_mux_pane_output_scene(
		struct engineos_mux_pane_scene *pane_scene,
		struct engineos_shell_output *output,
		const struct engineos_mux_pane_model *pane,
		char *error, size_t error_size) {
	if (output->mux_scene_tree == NULL ||
			find_mux_pane_output_scene(pane_scene, output->mux_view_id) != NULL)
		return true;
	struct engineos_mux_pane_output_scene *output_scene =
		calloc(1, sizeof(*output_scene));
	if (output_scene == NULL) {
		snprintf(error, error_size, "out of memory creating output pane scene");
		return false;
	}
	output_scene->output = output;
	struct engineos_mux_client render_client;
	if (!pane_render_client(output->server, pane, &render_client)) {
		free(output_scene);
		snprintf(error, error_size,
			"output pane %%%u has no retained terminal grid", pane->pane_id);
		return false;
	}
	output_scene->renderer = engineos_terminal_renderer_create(
		output->server->renderer, output->server->allocator, &render_client,
		&output->server->terminal_theme, error, error_size);
	if (output_scene->renderer == NULL) {
		free(output_scene);
		return false;
	}
	output_scene->buffer = engineos_terminal_renderer_buffer(
		output_scene->renderer);
	engineos_terminal_renderer_stats(output_scene->renderer,
		&output_scene->stats);
	output_scene->tree = wlr_scene_tree_create(output->mux_scene_tree);
	if (output_scene->tree != NULL) {
		output_scene->terminal_scene = wlr_scene_buffer_create(
			output_scene->tree, NULL);
		if (output_scene->terminal_scene != NULL)
			set_terminal_scene_buffer(output_scene->terminal_scene,
				output_scene->renderer);
	}
	if (output_scene->tree == NULL || output_scene->terminal_scene == NULL) {
		if (output_scene->tree != NULL)
			wlr_scene_node_destroy(&output_scene->tree->node);
		engineos_terminal_renderer_destroy(output_scene->renderer);
		free(output_scene);
		snprintf(error, error_size, "failed to create output pane scene nodes");
		return false;
	}
	int cell_width = output_scene->stats.width /
		(int)render_client.grid_columns;
	int cell_height = output_scene->stats.height /
		(int)render_client.grid_rows;
	wlr_scene_node_set_position(&output_scene->tree->node,
		(int)pane->left * cell_width, (int)pane->top * cell_height);
	wlr_scene_node_set_enabled(&output_scene->tree->node, pane->visible);
	wlr_scene_node_set_enabled(&output_scene->terminal_scene->node,
		!pane_presentation_owned_by_output(output->server, pane, output));
	if (pane->pane_id == output->mux_snapshot.pane_id &&
			pane->generation == output->mux_snapshot.pane_generation &&
			output_scene->terminal_scene->node.enabled) {
		output->scheduled_mux_revision = output->server->mux_client.revision;
		output->scheduled_grid_revision = render_client.grid_revision;
		output->scheduled_renderer_frame = output_scene->stats.frame;
	}
	wl_list_insert(pane_scene->output_scenes.prev, &output_scene->link);
	return true;
}

static bool create_mux_output_scene(struct engineos_shell_output *output,
		char *error, size_t error_size) {
	struct engineos_shell_server *server = output->server;
	if (output->mux_scene_tree != NULL)
		return true;
	output->mux_scene_tree = wlr_scene_tree_create(server->mux_pane_tree);
	if (output->mux_scene_tree == NULL) {
		snprintf(error, error_size, "failed to create mux output scene root");
		return false;
	}
	if (!output->mux_snapshot.ui.ready) {
		snprintf(error, error_size, "mux output has no authoritative UI model");
		return false;
	}
	struct engineos_mux_client ui_client;
	view_ui_render_client(server, &output->mux_snapshot.ui, &ui_client);
	output->mux_ui_renderer = engineos_terminal_renderer_create(server->renderer,
		server->allocator, &ui_client, &server->terminal_theme, error,
		error_size);
	if (output->mux_ui_renderer == NULL)
		return false;
	engineos_terminal_renderer_stats(output->mux_ui_renderer,
		&output->mux_ui_stats);
	struct wlr_output_layout_output *layout_output =
		wlr_output_layout_get(server->output_layout, output->output);
	if (layout_output != NULL)
		wlr_scene_node_set_position(&output->mux_scene_tree->node,
			layout_output->x, layout_output->y);
	for (size_t index = 0; index < output->mux_snapshot.pane_count; index++) {
		struct engineos_mux_pane_model *pane =
			&output->mux_snapshot.panes[index];
		if (!pane->window_active)
			continue;
		struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(server,
			pane->pane_id, pane->generation);
		if (pane_scene == NULL) {
			if (!create_mux_pane_scene(server, pane, error, error_size))
				return false;
			pane_scene = find_mux_pane_scene(server, pane->pane_id,
				pane->generation);
		}
		if (!create_mux_pane_output_scene(pane_scene, output, pane, error,
				error_size))
			return false;
	}
	output->mux_ui_scene = wlr_scene_buffer_create(output->mux_scene_tree, NULL);
	if (output->mux_ui_scene == NULL) {
		snprintf(error, error_size, "failed to create mux output UI scene");
		return false;
	}
	/* The full-output UI buffer contains transparent pixels outside tmux status,
	 * prompt, and menu cells. It must stay above panes for rendering but never
	 * become the pointer hit-test target: terminal-mode UI input is routed by
	 * authoritative tmux cell coordinates, while presentation-mode input must
	 * reach the Wayland surface below it. */
	output->mux_ui_scene->point_accepts_input =
		scene_overlay_rejects_pointer_input;
	set_terminal_scene_buffer(output->mux_ui_scene, output->mux_ui_renderer);
	wlr_scene_node_raise_to_top(&output->mux_ui_scene->node);
	output->mux_snapshot.ui.changed = false;
	if (output->mux_view_id == server->mux_client.primary_view_id) {
		server->mux_ui_scene = output->mux_ui_scene;
		server->mux_terminal_width = output->mux_ui_stats.width;
		server->mux_terminal_height = output->mux_ui_stats.height;
	}
	return true;
}

static void destroy_mux_output_scene(struct engineos_shell_output *output) {
	struct engineos_mux_pane_scene *pane_scene;
	wl_list_for_each(pane_scene, &output->server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene, *next;
		wl_list_for_each_safe(output_scene, next, &pane_scene->output_scenes, link) {
			if (output_scene->output != output)
				continue;
			destroy_mux_pane_output_scene(output->server, pane_scene,
				output_scene);
		}
	}
	if (output->mux_scene_tree != NULL) {
		wlr_scene_node_destroy(&output->mux_scene_tree->node);
		output->mux_scene_tree = NULL;
		output->mux_ui_scene = NULL;
	}
	engineos_terminal_renderer_destroy(output->mux_ui_renderer);
	output->mux_ui_renderer = NULL;
	memset(&output->mux_ui_stats, 0, sizeof(output->mux_ui_stats));
}

static bool setup_native_terminal_scene(struct engineos_shell_server *server) {
	server->mux_pane_tree = wlr_scene_tree_create(&server->scene->tree);
	if (server->mux_pane_tree == NULL) {
		wlr_log(WLR_ERROR, "failed to create native mux scene root");
		return false;
	}
	wlr_log(WLR_INFO,
		"native mux scene root ready panes=%zu selected=%%%u generation=%u",
		server->mux_client.pane_count, server->mux_client.pane_id,
		server->mux_client.pane_generation);
	return true;
}

static bool refresh_native_terminal_scene(struct engineos_shell_server *server,
		const char *reason) {
	char error[256] = {0};
	bool ui_request_changed = false;
	struct engineos_shell_output *pending_output;
	wl_list_for_each(pending_output, &server->outputs, link) {
		if (!pending_output->mux_registered ||
				!pending_output->mux_snapshot.ui.invalidated)
			continue;
		bool changed = false;
		if (!engineos_mux_client_request_view_ui(&server->mux_client,
				pending_output->mux_view_id, &pending_output->mux_snapshot,
				&changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR,
				"native mux invalidated output UI refresh failed view=%u: %s",
				pending_output->mux_view_id, error);
			return false;
		}
		ui_request_changed = ui_request_changed || changed;
	}
	if (server->mux_client.state_invalidated_pending &&
			!refresh_native_output_snapshots(server, &ui_request_changed,
				error, sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native mux output state changed during UI refresh: %s", error);
		return false;
	}
	struct engineos_mux_pane_scene *scene, *next;
	wl_list_for_each_safe(scene, next, &server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene, *next_output_scene;
		wl_list_for_each_safe(output_scene, next_output_scene,
				&scene->output_scenes, link) {
			struct engineos_mux_pane_model *pane = find_output_pane_model(
				output_scene->output, scene->pane_id, scene->generation);
			if (pane == NULL || !pane->window_active)
				destroy_mux_pane_output_scene(server, scene, output_scene);
		}
		if (wl_list_empty(&scene->output_scenes)) {
			struct engineos_shell_view *view;
			wl_list_for_each(view, &server->views, link) {
				if (!view->mux_bound || view->mux_pane_id != scene->pane_id ||
						view->mux_pane_generation != scene->generation)
					continue;
				wlr_scene_node_reparent(&view->scene_tree->node,
					&server->scene->tree);
				wlr_scene_node_set_enabled(&view->scene_tree->node, false);
				view->mux_presentation_visible = false;
			}
			wl_list_remove(&scene->link);
			free(scene);
		}
	}
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (!output->mux_registered)
			continue;
		for (size_t index = 0; index < output->mux_snapshot.pane_count; index++) {
			struct engineos_mux_pane_model *pane =
				&output->mux_snapshot.panes[index];
			if (!pane->window_active)
				continue;
			struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(
				server, pane->pane_id, pane->generation);
			if (pane_scene == NULL) {
				if (!create_mux_pane_scene(server, pane, error, sizeof(error))) {
					wlr_log(WLR_ERROR,
						"native pane scene creation failed: %s", error);
					return false;
				}
				pane_scene = find_mux_pane_scene(server, pane->pane_id,
					pane->generation);
			}
			if (!create_mux_pane_output_scene(pane_scene, output, pane, error,
					sizeof(error))) {
				wlr_log(WLR_ERROR,
					"native output pane scene creation failed: %s", error);
				return false;
			}
		}
	}
	server->mux_terminal_scene = NULL;
	server->mux_ui_scene = NULL;
	server->mux_terminal_renderer = NULL;
	server->mux_terminal_buffer = NULL;
	wl_list_for_each(scene, &server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene;
		wl_list_for_each(output_scene, &scene->output_scenes, link) {
			struct engineos_mux_pane_model *pane = find_output_pane_model(
				output_scene->output, scene->pane_id, scene->generation);
			struct engineos_mux_client render_client;
			if (pane == NULL ||
					!pane_render_client(server, pane, &render_client)) {
				wlr_log(WLR_ERROR,
					"native output pane lost retained grid pane=%%%u view=%u",
					scene->pane_id, output_scene->output->mux_view_id);
				return false;
			}
			if (!engineos_terminal_renderer_update(output_scene->renderer,
					&render_client, error, sizeof(error))) {
				wlr_log(WLR_ERROR, "native output pane damage render failed: %s",
					error);
				return false;
			}
			output_scene->buffer = engineos_terminal_renderer_buffer(
				output_scene->renderer);
			engineos_terminal_renderer_stats(output_scene->renderer,
				&output_scene->stats);
			int cell_width = output_scene->stats.width /
				(int)render_client.grid_columns;
			int cell_height = output_scene->stats.height /
				(int)render_client.grid_rows;
			set_terminal_scene_buffer(output_scene->terminal_scene,
				output_scene->renderer);
			wlr_scene_node_set_position(&output_scene->tree->node,
				(int)pane->left * cell_width, (int)pane->top * cell_height);
			wlr_scene_node_set_enabled(&output_scene->tree->node, pane->visible);
			wlr_scene_node_set_enabled(&output_scene->terminal_scene->node,
				!pane_presentation_owned_by_output(server, pane,
					output_scene->output));
			if (pane->pane_id ==
					output_scene->output->mux_snapshot.pane_id &&
					pane->generation ==
					output_scene->output->mux_snapshot.pane_generation) {
				output_scene->output->scheduled_mux_revision =
					server->mux_client.revision;
				output_scene->output->scheduled_grid_revision =
					render_client.grid_revision;
				output_scene->output->scheduled_renderer_frame =
					output_scene->stats.frame;
			}
			if (pane->pane_id == output_scene->output->mux_snapshot.pane_id &&
					pane->generation == output_scene->output->mux_snapshot.pane_generation) {
				bool exact_view = output_scene->output->mux_view_id ==
					server->mux_client.primary_view_id;
				if (exact_view || server->mux_terminal_renderer == NULL) {
					server->mux_terminal_renderer = output_scene->renderer;
					server->mux_terminal_buffer = output_scene->buffer;
					server->mux_terminal_scene = output_scene->terminal_scene;
					server->mux_terminal_glyph_cells =
						output_scene->stats.glyph_cells;
					server->mux_terminal_atlas_entries =
						output_scene->stats.atlas_entries;
					server->mux_terminal_damaged_cells =
						output_scene->stats.damaged_cells;
					server->mux_terminal_nonblank_pixels =
						output_scene->stats.nonblank_pixels;
					server->mux_terminal_frame = output_scene->stats.frame;
				}
			}
		}
	}
	if (server->mux_terminal_renderer == NULL) {
		struct engineos_shell_output *fallback_output;
		wl_list_for_each(fallback_output, &server->outputs, link) {
			if (!fallback_output->mux_registered ||
					(server->mux_client.primary_view_id != 0 &&
					 fallback_output->mux_view_id !=
						server->mux_client.primary_view_id))
				continue;
			struct engineos_mux_pane_scene *fallback_pane = find_mux_pane_scene(
				server, fallback_output->mux_snapshot.pane_id,
				fallback_output->mux_snapshot.pane_generation);
			struct engineos_mux_pane_output_scene *fallback_scene =
				fallback_pane != NULL ? find_mux_pane_output_scene(fallback_pane,
					fallback_output->mux_view_id) : NULL;
			if (fallback_scene == NULL)
				continue;
			server->mux_terminal_renderer = fallback_scene->renderer;
			server->mux_terminal_buffer = fallback_scene->buffer;
			server->mux_terminal_scene = fallback_scene->terminal_scene;
			server->mux_terminal_glyph_cells = fallback_scene->stats.glyph_cells;
			server->mux_terminal_atlas_entries = fallback_scene->stats.atlas_entries;
			server->mux_terminal_damaged_cells = fallback_scene->stats.damaged_cells;
			server->mux_terminal_nonblank_pixels =
				fallback_scene->stats.nonblank_pixels;
			server->mux_terminal_frame = fallback_scene->stats.frame;
			break;
		}
		if (server->mux_terminal_renderer == NULL) {
			wlr_log(WLR_ERROR,
				"mux outputs have no authoritative selected pane renderer");
			return false;
		}
	}
	wl_list_for_each(output, &server->outputs, link) {
		if (output->mux_ui_scene == NULL || output->mux_ui_renderer == NULL ||
				!output->mux_snapshot.ui.ready ||
				output->mux_snapshot.ui.invalidated)
			continue;
		if (output->mux_view_id == server->mux_client.primary_view_id) {
			server->mux_ui_scene = output->mux_ui_scene;
			server->mux_terminal_width = output->mux_ui_stats.width;
			server->mux_terminal_height = output->mux_ui_stats.height;
		}
		/* Pane scene nodes may be added after the UI node during layout
		 * changes. Menus and prompts are compositor overlays and must remain
		 * above every pane on their owning output. */
		wlr_scene_node_raise_to_top(&output->mux_ui_scene->node);
		if (!output->mux_snapshot.ui.changed)
			continue;
		struct engineos_mux_client output_ui_client;
		view_ui_render_client(server, &output->mux_snapshot.ui,
			&output_ui_client);
		if (!engineos_terminal_renderer_update(output->mux_ui_renderer,
				&output_ui_client, error, sizeof(error))) {
			wlr_log(WLR_ERROR,
				"native mux output UI damage render failed view=%u: %s",
				output->mux_view_id, error);
			return false;
		}
		engineos_terminal_renderer_stats(output->mux_ui_renderer,
			&output->mux_ui_stats);
		set_terminal_scene_buffer(output->mux_ui_scene,
			output->mux_ui_renderer);
		output->mux_snapshot.ui.changed = false;
		if (output->mux_view_id == server->mux_client.primary_view_id) {
			server->mux_ui_scene = output->mux_ui_scene;
			server->mux_terminal_width = output->mux_ui_stats.width;
			server->mux_terminal_height = output->mux_ui_stats.height;
		}
	}
	engineos_mux_client_clear_render_damage(&server->mux_client);
	for (size_t index = 0; index < server->mux_client.pane_count; index++)
		engineos_mux_pane_model_clear_render_damage(
			&server->mux_client.panes[index]);
	wl_list_for_each(output, &server->outputs, link) {
		for (size_t index = 0; index < output->mux_snapshot.pane_count; index++) {
			if (output->mux_snapshot.panes[index].grid.ready)
				engineos_mux_pane_model_clear_render_damage(
					&output->mux_snapshot.panes[index]);
		}
	}
	wlr_log(WLR_DEBUG,
		"native mux scene refresh panes=%zu selected=%%%u grid_revision=%llu pixels=%dx%d glyph_cells=%u renderer=%s frame=%llu reason=%s",
		server->mux_client.pane_count,
		server->mux_client.pane_id,
		(unsigned long long)server->mux_client.grid_revision,
		server->mux_terminal_width, server->mux_terminal_height,
		server->mux_terminal_glyph_cells,
		engineos_terminal_renderer_mode(server->mux_terminal_renderer),
		(unsigned long long)server->mux_terminal_frame, reason);
	schedule_outputs(server);
	write_shell_state(server, reason);
	return true;
}

static void sync_native_presentation_visibility(
		struct engineos_shell_server *server, const char *reason) {
	struct engineos_shell_view *view;
	struct engineos_shell_view *active = NULL;
	struct engineos_mux_pane_model *focused_pane = focused_mux_pane(server);
	wl_list_for_each(view, &server->views, link) {
		if (!view->mapped || !view->mux_bound)
			continue;
		struct engineos_mux_pane_model *pane = find_shell_pane_model(server,
			view->mux_pane_id, view->mux_pane_generation);
		if (pane == NULL) {
			view->mux_presentation_visible = false;
			wlr_scene_node_set_enabled(&view->scene_tree->node, false);
			continue;
		}
		struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(server,
			pane->pane_id, pane->generation);
		struct engineos_mux_pane_output_scene *lease_scene = NULL;
		if (pane_scene != NULL && pane->lease_client_id ==
				server->mux_client.frontend_client_id)
			lease_scene = find_mux_pane_output_scene(pane_scene,
				pane->lease_view_id);
		if (lease_scene != NULL && view->scene_tree->node.parent !=
				lease_scene->tree) {
			wlr_scene_node_reparent(&view->scene_tree->node, lease_scene->tree);
			apply_view_layout(view);
		} else if (lease_scene == NULL && view->scene_tree->node.parent !=
				&server->scene->tree) {
			wlr_scene_node_reparent(&view->scene_tree->node,
				&server->scene->tree);
		}
		struct engineos_shell_view *root = native_presentation_root(view);
		view->mux_presentation_visible = root != NULL &&
			root->view_id == pane->active_surface_id;
		bool presentation_visible = lease_scene != NULL &&
			pane_presentation_owned_by_output(server, pane,
				lease_scene->output);
		bool enabled = pane->visible && presentation_visible &&
			view->mux_presentation_visible;
		wlr_scene_node_set_enabled(&view->scene_tree->node, enabled);
		if (enabled && focused_pane != NULL &&
				pane->pane_id == focused_pane->pane_id &&
				pane->generation == focused_pane->generation)
			active = view;
	}
	struct engineos_mux_pane_scene *pane_scene;
	wl_list_for_each(pane_scene, &server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene;
		wl_list_for_each(output_scene, &pane_scene->output_scenes, link) {
			struct engineos_mux_pane_model *pane = find_output_pane_model(
				output_scene->output, pane_scene->pane_id,
				pane_scene->generation);
			bool presentation_visible = pane != NULL && pane->visible &&
				pane_presentation_owned_by_output(server, pane,
					output_scene->output);
			wlr_scene_node_set_enabled(&output_scene->terminal_scene->node,
				!presentation_visible);
		}
	}
	/* Attach previews only after pane/output and presentation scene trees are
	 * stable, but before focus and input are reconciled for this revision. */
	if (!sync_native_preview_leases(server, reason)) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return;
	}
	if (active == NULL && server->emergency_released && focused_pane != NULL &&
			strcmp(focused_pane->view_mode, "presentation") != 0) {
		server->emergency_released = false;
		server->input_mode = ENGINEOS_INPUT_TERMINAL;
		server->game_capture = false;
		server->mux_prefix_pending = false;
		server->mux_consumed_keycode = 0;
		sync_pointer_constraint(server, "presentation-hidden-after-emergency");
		sync_cursor_image(server, "presentation-hidden-after-emergency");
		wlr_log(WLR_INFO,
			"input emergency-release latch cleared reason=presentation-hidden");
	}
	if (active != NULL && !server->emergency_released) {
		struct engineos_mux_pane_model *pane = focused_pane;
		enum engineos_input_mode expected_mode = pane != NULL &&
			strcmp(pane->presentation, "game") == 0 ?
			ENGINEOS_INPUT_GAME : ENGINEOS_INPUT_GRAPHICAL;
		if (server->focused_view != active ||
				server->input_mode != expected_mode)
			activate_view(active, reason);
	} else if (active == NULL && server->focused_view != NULL &&
			server->focused_view->mux_bound) {
		set_view_activated(server->focused_view, false);
		server->focused_view = NULL;
		wlr_seat_keyboard_notify_clear_focus(server->seat);
		server->input_mode = ENGINEOS_INPUT_TERMINAL;
		server->game_capture = false;
		server->mux_prefix_pending = false;
		server->mux_consumed_keycode = 0;
		sync_pointer_constraint(server, reason);
		sync_cursor_image(server, reason);
	}
	schedule_outputs(server);
}

static bool refresh_native_output_snapshots(
		struct engineos_shell_server *server, bool *grid_changed,
		char *error, size_t error_size) {
	for (unsigned int attempt = 0; attempt < 8; attempt++) {
		server->mux_client.state_invalidated_pending = false;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (!output->mux_registered)
			continue;
		bool changed = false;
		if (!engineos_mux_client_request_view_snapshot(&server->mux_client,
				output->mux_view_id, &output->mux_snapshot, &changed,
				error, error_size))
			return false;
		bool ui_changed = false;
		if ((!output->mux_snapshot.ui.ready ||
				output->mux_snapshot.ui.invalidated) &&
				!engineos_mux_client_request_view_ui(&server->mux_client,
					output->mux_view_id, &output->mux_snapshot, &ui_changed,
					error, error_size))
			return false;
		if (output->mux_snapshot.output == NULL ||
				strcmp(output->mux_snapshot.output, output->output->name) != 0) {
			snprintf(error, error_size,
				"mux output snapshot identity changed for view %u",
				output->mux_view_id);
			return false;
		}
		*grid_changed = *grid_changed || changed || ui_changed;
	}
		if (!engineos_mux_client_refresh_presentation(&server->mux_client,
				error, error_size))
			return false;
		bool revisions_match = true;
		uint64_t snapshot_revision = server->mux_client.revision;
		wl_list_for_each(output, &server->outputs, link) {
			if (output->mux_registered &&
					output->mux_snapshot.revision != snapshot_revision) {
				revisions_match = false;
				break;
			}
		}
		bool focused_model_matches = false;
		wl_list_for_each(output, &server->outputs, link) {
			if (!output->mux_registered || output->mux_view_id !=
					server->mux_client.primary_view_id)
				continue;
			focused_model_matches = output->mux_snapshot.ready &&
				output->mux_snapshot.pane_id == server->mux_client.pane_id &&
				output->mux_snapshot.pane_generation ==
					server->mux_client.pane_generation &&
				output->mux_snapshot.session_id != NULL &&
				server->mux_client.session_id != NULL &&
				strcmp(output->mux_snapshot.session_id,
					server->mux_client.session_id) == 0;
			break;
		}
		if (revisions_match && focused_model_matches) {
			/* A snapshot response at this revision covers any coalesced state
			 * invalidation queued ahead of that response. Requiring the socket
			 * to become completely idle cannot converge under an active pane. */
			server->mux_client.state_invalidated_pending = false;
			return true;
		}
	}
	server->mux_snapshot_retry_count++;
	if (server->mux_snapshot_retry_timer != NULL)
		wl_event_source_timer_update(server->mux_snapshot_retry_timer, 16);
	wlr_log(WLR_DEBUG,
		"native mux output snapshots deferred count=%llu revision=%llu",
		(unsigned long long)server->mux_snapshot_retry_count,
		(unsigned long long)server->mux_client.revision);
	return true;
}

static int native_mux_snapshot_retry(void *data) {
	struct engineos_shell_server *server = data;
	if (!server->mux_client.ready)
		return 0;
	/* Preserve image resync requests independently of the mux client's last
	 * request result. A later successful request in the same scene pass must
	 * not erase an earlier stale-image response. */
	server->mux_image_resync_pending = false;
	bool changed = false;
	char error[256] = {0};
	if (!refresh_native_output_snapshots(server, &changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native mux deferred output snapshot refresh failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return 0;
	}
	sync_native_presentation_visibility(server, "native-snapshot-retry");
	if (server->mux_image_resync_pending &&
			server->mux_snapshot_retry_timer != NULL)
		wl_event_source_timer_update(server->mux_snapshot_retry_timer, 16);
	if (!refresh_native_terminal_scene(server,
			"native-snapshot-retry")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	return 0;
}

static int terminal_blink_tick(void *data) {
	struct engineos_shell_server *server = data;
	bool has_blink = false;
	struct engineos_mux_pane_scene *pane_scene;
	wl_list_for_each(pane_scene, &server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene;
		wl_list_for_each(output_scene, &pane_scene->output_scenes, link)
			has_blink = has_blink ||
				engineos_terminal_renderer_has_blink(
					output_scene->renderer);
	}
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link)
		has_blink = has_blink ||
			engineos_terminal_renderer_has_blink(output->mux_ui_renderer);
	if (has_blink && !refresh_native_terminal_scene(server,
			"terminal-blink-phase")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return 0;
	}
	if (server->terminal_blink_timer != NULL)
		wl_event_source_timer_update(server->terminal_blink_timer, 500);
	return 0;
}

static int native_mux_event(int fd, uint32_t mask, void *data) {
	(void)fd;
	struct engineos_shell_server *server = data;
	if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
		wlr_log(WLR_ERROR, "native mux connection failed event_mask=0x%x", mask);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return 0;
	}
	bool changed = false, state_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_handle_event(&server->mux_client, &changed,
			&state_changed, error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native mux update failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return 0;
	}
	state_changed = state_changed ||
		server->mux_client.state_invalidated_pending;
	server->mux_client.state_invalidated_pending = false;
	if (!engineos_mux_client_refresh_presentation(&server->mux_client,
			error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native mux presentation refresh failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return 0;
	}
	state_changed = state_changed ||
		server->mux_client.state_invalidated_pending;
	server->mux_client.state_invalidated_pending = false;
	struct engineos_shell_output *focused_output;
	bool selected_output_model_found = false;
	wl_list_for_each(focused_output, &server->outputs, link) {
		if (focused_output->mux_registered &&
				find_output_pane_model(focused_output,
					server->mux_client.pane_id,
					server->mux_client.pane_generation) != NULL)
			selected_output_model_found = true;
		if (!focused_output->mux_registered ||
				focused_output->mux_view_id !=
					server->mux_client.primary_view_id)
			continue;
		if (!focused_output->mux_snapshot.ready ||
				focused_output->mux_snapshot.pane_id !=
					server->mux_client.pane_id ||
				focused_output->mux_snapshot.pane_generation !=
					server->mux_client.pane_generation ||
				focused_output->mux_snapshot.session_id == NULL ||
				server->mux_client.session_id == NULL ||
				strcmp(focused_output->mux_snapshot.session_id,
					server->mux_client.session_id) != 0)
			state_changed = true;
		break;
	}
	if (!selected_output_model_found)
		state_changed = true;
	if (state_changed) {
		if (!refresh_native_output_snapshots(server, &changed, error,
				sizeof(error))) {
			wlr_log(WLR_ERROR,
				"native mux output snapshot refresh failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return 0;
		}
	}
	sync_native_presentation_visibility(server, "native-presentation-state");
	if ((changed || state_changed) && !refresh_native_terminal_scene(server,
			"native-grid-damage")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	return 0;
}

static void hide_image_preview(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_preview_surface *preview, *tmp;
	size_t hidden = 0;
	wl_list_for_each_safe(preview, tmp, &server->previews, link) {
		wl_list_remove(&preview->link);
		reset_image_surface(preview);
		free(preview);
		hidden++;
	}
	wlr_log(WLR_INFO, "image previews hidden count=%zu reason=%s", hidden,
		reason != NULL ? reason : "unspecified");
	write_shell_state(server, reason != NULL ? reason : "preview-hidden");
	schedule_outputs(server);
}

static size_t hide_matching_image_previews(
		struct engineos_shell_server *server, const char *owner,
		bool pane_scoped, uint32_t pane_id, uint32_t pane_generation,
		const char *reason) {
	struct engineos_preview_surface *preview, *tmp;
	size_t hidden = 0;
	wl_list_for_each_safe(preview, tmp, &server->previews, link) {
		if (owner != NULL && owner[0] != '\0' &&
				(preview->owner == NULL || strcmp(owner, preview->owner) != 0))
			continue;
		if (pane_scoped && (!preview->native_pane ||
				preview->pane_id != pane_id ||
				(pane_generation != 0 &&
				 preview->pane_generation != pane_generation)))
			continue;
		wl_list_remove(&preview->link);
		reset_image_surface(preview);
		free(preview);
		hidden++;
	}
	wlr_log(WLR_INFO,
		"image previews hidden count=%zu owner=%s pane_scoped=%s pane=%%%u generation=%u reason=%s",
		hidden, owner != NULL ? owner : "", pane_scoped ? "true" : "false",
		pane_id, pane_generation,
		reason != NULL ? reason : "unspecified");
	if (hidden > 0) {
		write_shell_state(server,
			reason != NULL ? reason : "preview-hidden");
		schedule_outputs(server);
	}
	return hidden;
}

static void hide_wallpaper(struct engineos_shell_server *server,
		const char *reason) {
	reset_image_surface(&server->wallpaper);
	wlr_log(WLR_INFO, "wallpaper hidden reason=%s",
		reason != NULL ? reason : "unspecified");
	write_shell_state(server, reason != NULL ? reason : "wallpaper-hidden");
	schedule_outputs(server);
}

static struct engineos_preview_surface *find_mux_image_preview(
		struct engineos_shell_server *server, uint32_t pane_id,
		uint32_t generation, uint32_t image_id) {
	struct engineos_preview_surface *preview;
	wl_list_for_each(preview, &server->previews, link) {
		if (preview->mux_owned && preview->pane_id == pane_id &&
				preview->pane_generation == generation &&
				preview->mux_image_id == image_id)
			return preview;
	}
	return NULL;
}

static bool preview_failure_known(struct engineos_shell_server *server,
		uint32_t pane_id, uint32_t pane_generation, uint32_t image_id) {
	struct engineos_preview_failure *failure;
	wl_list_for_each(failure, &server->preview_failures, link) {
		if (failure->pane_id == pane_id &&
				failure->pane_generation == pane_generation &&
				failure->image_id == image_id)
			return true;
	}
	return false;
}

static bool mux_image_is_current(struct engineos_shell_server *server,
		const struct engineos_preview_failure *failure) {
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		for (size_t index = 0; output->mux_registered &&
				index < output->mux_snapshot.pane_count; index++) {
			const struct engineos_mux_pane_model *pane =
				&output->mux_snapshot.panes[index];
			if (pane->pane_id == failure->pane_id &&
					pane->generation == failure->pane_generation &&
					pane->image_id == failure->image_id)
				return true;
		}
	}
	return false;
}

static void prune_preview_failures(struct engineos_shell_server *server) {
	struct engineos_preview_failure *failure, *tmp;
	wl_list_for_each_safe(failure, tmp, &server->preview_failures, link) {
		if (mux_image_is_current(server, failure))
			continue;
		wl_list_remove(&failure->link);
		free(failure);
	}
	if (!wl_list_empty(&server->preview_failures))
		return;
	server->preview_failed_pane_id = 0;
	server->preview_failed_generation = 0;
	server->preview_failed_image_id = 0;
	if (strcmp(server->preview_reconciliation_status, "error") == 0) {
		snprintf(server->preview_reconciliation_status,
			sizeof(server->preview_reconciliation_status), "ready");
		server->preview_reconciliation_error[0] = '\0';
	}
}

static bool record_preview_failure(struct engineos_shell_server *server,
		uint32_t pane_id, uint32_t pane_generation, uint32_t image_id) {
	if (preview_failure_known(server, pane_id, pane_generation, image_id))
		return true;
	struct engineos_preview_failure *failure = calloc(1, sizeof(*failure));
	if (failure == NULL)
		return false;
	failure->pane_id = pane_id;
	failure->pane_generation = pane_generation;
	failure->image_id = image_id;
	wl_list_insert(server->preview_failures.prev, &failure->link);
	return true;
}

static enum engineos_preview_create_result create_mux_image_preview(
		struct engineos_shell_server *server,
		struct engineos_mux_pane_model *pane,
		struct engineos_mux_pane_output_scene *output_scene,
		char *error, size_t error_size) {
	uint8_t *encoded = NULL;
	size_t encoded_size = 0;
	if (!engineos_mux_client_request_image(&server->mux_client, pane->pane_id,
			pane->generation, pane->image_id, pane->image_bytes,
			&encoded, &encoded_size, error, error_size)) {
		if (server->mux_client.last_image_resync_required) {
			server->mux_image_resync_pending = true;
			wlr_log(WLR_INFO,
				"mux image fetch superseded pane=%%%u generation=%u image_id=%u; snapshot resync deferred",
				pane->pane_id, pane->generation, pane->image_id);
			return ENGINEOS_PREVIEW_DEFERRED;
		}
		return ENGINEOS_PREVIEW_FATAL;
	}
	int image_width = 0, image_height = 0;
	struct wlr_buffer *buffer = engineos_image_decode_memory(encoded,
		encoded_size, pane->image_mime, &image_width, &image_height,
		error, error_size);
	free(encoded);
	if (buffer == NULL)
		return ENGINEOS_PREVIEW_ISOLATED_FAILURE;
	long dest_width = output_scene->stats.width;
	long dest_height = dest_width * image_height / image_width;
	if (dest_height > output_scene->stats.height) {
		dest_height = output_scene->stats.height;
		dest_width = dest_height * image_width / image_height;
	}
	if (dest_width <= 0 || dest_height <= 0 || dest_width > INT_MAX ||
			dest_height > INT_MAX) {
		wlr_buffer_drop(buffer);
		snprintf(error, error_size, "mux image destination is invalid");
		return ENGINEOS_PREVIEW_ISOLATED_FAILURE;
	}
	hide_matching_image_previews(server, NULL, true, pane->pane_id,
		pane->generation, "replace-mux-pane-image");
	struct engineos_preview_surface *preview = calloc(1, sizeof(*preview));
	if (preview == NULL) {
		wlr_buffer_drop(buffer);
		snprintf(error, error_size, "failed to allocate mux image state");
		return ENGINEOS_PREVIEW_FATAL;
	}
	preview->buffer = buffer;
	preview->scene_buffer = wlr_scene_buffer_create(output_scene->tree, buffer);
	if (preview->scene_buffer == NULL) {
		wlr_buffer_drop(buffer);
		preview->buffer = NULL;
		free(preview);
		snprintf(error, error_size, "failed to create mux image scene buffer");
		return ENGINEOS_PREVIEW_FATAL;
	}
	char path[96];
	snprintf(path, sizeof(path), "mux://pane/%u/image/%u", pane->pane_id,
		pane->image_id);
	preview->path = strdup(path);
	preview->owner = strdup(pane->image_owner);
	if (preview->path == NULL || preview->owner == NULL) {
		reset_image_surface(preview);
		free(preview);
		snprintf(error, error_size, "failed to retain mux image identity");
		return ENGINEOS_PREVIEW_FATAL;
	}
	preview->native_pane = true;
	preview->mux_owned = true;
	preview->pane_id = pane->pane_id;
	preview->pane_generation = pane->generation;
	preview->mux_image_id = pane->image_id;
	preview->lease_client_id = pane->image_lease_client_id;
	preview->lease_view_id = pane->image_lease_view_id;
	preview->image_width = image_width;
	preview->image_height = image_height;
	preview->width = (int)dest_width;
	preview->height = (int)dest_height;
	preview->x = (output_scene->stats.width - preview->width) / 2;
	preview->y = (output_scene->stats.height - preview->height) / 2;
	wlr_scene_buffer_set_dest_size(preview->scene_buffer,
		preview->width, preview->height);
	wlr_scene_node_set_position(&preview->scene_buffer->node,
		preview->x, preview->y);
	wlr_scene_node_set_enabled(&preview->scene_buffer->node,
		!pane->presentation_mapped || strcmp(pane->view_mode, "console") == 0);
	wlr_scene_node_raise_to_top(&preview->scene_buffer->node);
	wl_list_insert(server->previews.prev, &preview->link);
	wlr_log(WLR_INFO,
		"mux image received pane=%%%u generation=%u image_id=%u bytes=%zu mime=%s owner=%s lease=%u:%u image=%dx%d size=%dx%d",
		pane->pane_id, pane->generation, pane->image_id, encoded_size,
		pane->image_mime, pane->image_owner, pane->image_lease_client_id,
		pane->image_lease_view_id, image_width, image_height,
		preview->width, preview->height);
	return ENGINEOS_PREVIEW_CREATED;
}

static bool sync_native_preview_leases(struct engineos_shell_server *server,
		const char *reason) {
	struct engineos_preview_surface *preview, *tmp;
	bool changed = false;
	prune_preview_failures(server);
	wl_list_for_each_safe(preview, tmp, &server->previews, link) {
		if (!preview->native_pane)
			continue;
		struct engineos_mux_pane_model *pane = find_shell_pane_model(server,
			preview->pane_id, preview->pane_generation);
		struct engineos_shell_output *model_output =
			output_for_pane_model(server, pane);
		struct engineos_mux_pane_scene *pane_scene = pane != NULL ?
			find_mux_pane_scene(server, pane->pane_id, pane->generation) : NULL;
		uint32_t lease_client_id = preview->mux_owned && pane != NULL ?
			pane->image_lease_client_id :
			(pane != NULL && pane->presentation_mapped ? pane->lease_client_id :
			 server->mux_client.frontend_client_id);
		uint32_t lease_view_id = preview->mux_owned && pane != NULL ?
			pane->image_lease_view_id :
			(pane != NULL && pane->presentation_mapped ? pane->lease_view_id :
			 (model_output != NULL ? model_output->mux_view_id : 0));
		bool image_current = !preview->mux_owned || (pane != NULL &&
			pane->image_id == preview->mux_image_id &&
			pane->image_id != 0);
		struct engineos_mux_pane_output_scene *output_scene =
			image_current && pane_scene != NULL && lease_client_id ==
				server->mux_client.frontend_client_id && lease_view_id != 0 ?
			find_mux_pane_output_scene(pane_scene, lease_view_id) : NULL;
		if (!image_current || pane == NULL ||
				lease_client_id != server->mux_client.frontend_client_id ||
				lease_view_id == 0) {
			wlr_log(WLR_INFO,
				"image preview lease lost pane=%%%u generation=%u reason=%s",
				preview->pane_id, preview->pane_generation,
				reason != NULL ? reason : "native-preview-lease-lost");
			wl_list_remove(&preview->link);
			reset_image_surface(preview);
			free(preview);
			changed = true;
			continue;
		}
		if (output_scene == NULL) {
			if (preview->scene_buffer->node.parent != &server->scene->tree)
				wlr_scene_node_reparent(&preview->scene_buffer->node,
					&server->scene->tree);
			wlr_scene_node_set_enabled(&preview->scene_buffer->node, false);
			snprintf(server->preview_reconciliation_status,
				sizeof(server->preview_reconciliation_status), "deferred");
			snprintf(server->preview_reconciliation_error,
				sizeof(server->preview_reconciliation_error),
				"output scene unavailable for pane %%%u image %u",
				preview->pane_id, preview->mux_image_id);
			if (server->mux_snapshot_retry_timer != NULL)
				wl_event_source_timer_update(
					server->mux_snapshot_retry_timer, 16);
			changed = true;
			continue;
		}
		if (preview->scene_buffer->node.parent != output_scene->tree)
			wlr_scene_node_reparent(&preview->scene_buffer->node,
				output_scene->tree);
		preview->lease_client_id = lease_client_id;
		preview->lease_view_id = lease_view_id;
		if (preview->mux_owned) {
			long width = output_scene->stats.width;
			long height = width * preview->image_height / preview->image_width;
			if (height > output_scene->stats.height) {
				height = output_scene->stats.height;
				width = height * preview->image_width / preview->image_height;
			}
			preview->width = (int)width;
			preview->height = (int)height;
			preview->x = (output_scene->stats.width - preview->width) / 2;
			preview->y = (output_scene->stats.height - preview->height) / 2;
			wlr_scene_buffer_set_dest_size(preview->scene_buffer,
				preview->width, preview->height);
			wlr_scene_node_set_position(&preview->scene_buffer->node,
				preview->x, preview->y);
			wlr_scene_node_set_enabled(&preview->scene_buffer->node,
				!pane->presentation_mapped ||
				strcmp(pane->view_mode, "console") == 0);
		}
		wlr_scene_node_raise_to_top(&preview->scene_buffer->node);
	}
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		for (size_t index = 0; output->mux_registered &&
				index < output->mux_snapshot.pane_count; index++) {
			struct engineos_mux_pane_model *pane =
				&output->mux_snapshot.panes[index];
			if (pane->image_id == 0 || pane->image_lease_client_id !=
					server->mux_client.frontend_client_id ||
					pane->image_lease_view_id != output->mux_view_id ||
					find_mux_image_preview(server, pane->pane_id,
						pane->generation, pane->image_id) != NULL)
				continue;
			if (preview_failure_known(server, pane->pane_id, pane->generation,
					pane->image_id))
				continue;
			struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(
				server, pane->pane_id, pane->generation);
			struct engineos_mux_pane_output_scene *output_scene =
				pane_scene != NULL ? find_mux_pane_output_scene(pane_scene,
					output->mux_view_id) : NULL;
			if (output_scene == NULL) {
				snprintf(server->preview_reconciliation_status,
					sizeof(server->preview_reconciliation_status), "deferred");
				snprintf(server->preview_reconciliation_error,
					sizeof(server->preview_reconciliation_error),
					"output scene unavailable for pane %%%u image %u",
					pane->pane_id, pane->image_id);
				if (server->mux_snapshot_retry_timer != NULL)
					wl_event_source_timer_update(
						server->mux_snapshot_retry_timer, 16);
				changed = true;
				continue;
			}
			char error[256] = {0};
			enum engineos_preview_create_result result =
				create_mux_image_preview(server, pane, output_scene,
					error, sizeof(error));
			if (result == ENGINEOS_PREVIEW_FATAL) {
				wlr_log(WLR_ERROR,
					"mux image synchronization failed pane=%%%u image=%u: %s",
					pane->pane_id, pane->image_id,
					error[0] != '\0' ? error : "mux transport failure");
				return false;
			}
			if (result == ENGINEOS_PREVIEW_ISOLATED_FAILURE) {
				if (!record_preview_failure(server, pane->pane_id,
						pane->generation, pane->image_id)) {
					wlr_log(WLR_ERROR,
						"failed to retain isolated mux image failure");
					return false;
				}
				server->preview_failed_pane_id = pane->pane_id;
				server->preview_failed_generation = pane->generation;
				server->preview_failed_image_id = pane->image_id;
				snprintf(server->preview_reconciliation_status,
					sizeof(server->preview_reconciliation_status), "error");
				snprintf(server->preview_reconciliation_error,
					sizeof(server->preview_reconciliation_error), "%s",
					error[0] != '\0' ? error : "image decode failed");
				wlr_log(WLR_ERROR,
					"mux image isolated pane=%%%u image=%u: %s",
					pane->pane_id, pane->image_id,
					server->preview_reconciliation_error);
				changed = true;
				continue;
			}
			if (result == ENGINEOS_PREVIEW_DEFERRED ||
					server->mux_image_resync_pending) {
				snprintf(server->preview_reconciliation_status,
					sizeof(server->preview_reconciliation_status), "deferred");
				snprintf(server->preview_reconciliation_error,
					sizeof(server->preview_reconciliation_error),
					"image revision superseded");
				if (server->mux_snapshot_retry_timer != NULL)
					wl_event_source_timer_update(
						server->mux_snapshot_retry_timer, 1);
				continue;
			}
			if (wl_list_empty(&server->preview_failures)) {
				snprintf(server->preview_reconciliation_status,
					sizeof(server->preview_reconciliation_status), "ready");
				server->preview_reconciliation_error[0] = '\0';
			}
			changed = true;
		}
	}
	if (changed) {
		write_shell_state(server,
			reason != NULL ? reason : "native-preview-lease-lost");
		schedule_outputs(server);
	}
	return true;
}

static bool compute_wallpaper_box(struct engineos_shell_server *server,
		const char *slot, const char *mode,
		const struct engineos_preview_bounds *bounds,
		struct engineos_view_geometry *box) {
	if (mode != NULL && strcmp(mode, "pane") == 0) {
		return compute_preview_box(server, slot, bounds, box);
	}

	(void)slot;
	primary_output_geometry(server,
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
		engineos_image_decode(path, &image_width, &image_height, error, error_size);
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
			"{\"version\":1,\"status\":\"ok\",\"capabilities\":[\"ping\",\"terminal-theme\",\"wallpaper\",\"hide-wallpaper\",\"focus-window\",\"relayout-windows\",\"png\",\"jpeg\",\"cover\",\"opacity\"]}\n");
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

static void set_terminal_theme_on_renderers(
		struct engineos_shell_server *server,
		const struct engineos_terminal_theme *theme) {
	struct engineos_mux_pane_scene *pane_scene;
	wl_list_for_each(pane_scene, &server->mux_pane_scenes, link) {
		struct engineos_mux_pane_output_scene *output_scene;
		wl_list_for_each(output_scene, &pane_scene->output_scenes, link)
			engineos_terminal_renderer_set_theme(output_scene->renderer, theme);
	}
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		engineos_terminal_renderer_set_theme(output->mux_ui_renderer, theme);
		output->mux_snapshot.ui.changed = true;
	}
}

static bool apply_terminal_theme(struct engineos_shell_server *server,
		struct json_object *object, char *error, size_t error_size) {
	struct engineos_terminal_theme theme;
	if (!engineos_terminal_theme_parse(&theme, object, error, error_size))
		return false;

	struct engineos_terminal_theme previous = server->terminal_theme;
	theme.generation = previous.generation == UINT64_MAX ?
		1 : previous.generation + 1;
	server->terminal_theme = theme;
	set_terminal_theme_on_renderers(server, &server->terminal_theme);
	if (!refresh_native_terminal_scene(server, "terminal-theme-changed")) {
		server->terminal_theme = previous;
		set_terminal_theme_on_renderers(server, &server->terminal_theme);
		if (!refresh_native_terminal_scene(server, "terminal-theme-rollback")) {
			snprintf(error, error_size,
				"terminal theme render and rollback both failed");
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return false;
		}
		snprintf(error, error_size, "terminal theme render failed");
		return false;
	}
	wlr_log(WLR_INFO,
		"terminal theme changed name=%s generation=%llu foreground=#%06x background=#%06x",
		server->terminal_theme.name,
		(unsigned long long)server->terminal_theme.generation,
		server->terminal_theme.foreground, server->terminal_theme.background);
	snprintf(server->terminal_theme_source,
		sizeof(server->terminal_theme_source), "persisted-user");
	server->terminal_theme_error[0] = '\0';
	return true;
}

static bool load_terminal_theme_file(struct engineos_shell_server *server,
		const char *path, const char *source) {
	if (path == NULL || access(path, R_OK) != 0)
		return false;
	struct json_object *object = json_object_from_file(path);
	char error[256] = {0};
	struct engineos_terminal_theme theme;
	if (object == NULL ||
			!engineos_terminal_theme_parse(&theme, object, error,
				sizeof(error))) {
		snprintf(server->terminal_theme_error,
			sizeof(server->terminal_theme_error),
			"%.32s override %.96s is invalid: %.96s", source, path,
			error[0] != '\0' ? error : "invalid JSON");
		wlr_log(WLR_ERROR, "%s", server->terminal_theme_error);
		if (object != NULL) json_object_put(object);
		return false;
	}
	json_object_put(object);
	theme.generation = 1;
	server->terminal_theme = theme;
	snprintf(server->terminal_theme_source,
		sizeof(server->terminal_theme_source), "%s", source);
	return true;
}

static void load_terminal_theme_defaults(struct engineos_shell_server *server) {
	engineos_terminal_theme_default(&server->terminal_theme);
	snprintf(server->terminal_theme_source,
		sizeof(server->terminal_theme_source), "compiled-gruvbox");
	const char *config_home = getenv("XDG_CONFIG_HOME");
	const char *home = getenv("HOME");
	char *user_path = NULL;
	if (config_home != NULL && config_home[0] != '\0')
		user_path = join_state_path(config_home,
			"engineos/terminal-theme.json");
	else if (home != NULL && home[0] != '\0') {
		char *home_config = join_state_path(home, ".config");
		if (home_config != NULL) {
			user_path = join_state_path(home_config,
				"engineos/terminal-theme.json");
			free(home_config);
		}
	}
	if (load_terminal_theme_file(server, user_path, "persisted-user")) {
		free(user_path);
		return;
	}
	free(user_path);
	const char *system_path = getenv(
		"ENGINEOS_TERMINAL_THEME_SYSTEM_DEFAULT");
	if (system_path == NULL || system_path[0] == '\0')
		system_path = "/etc/engineos/terminal-theme.json";
	(void)load_terminal_theme_file(server, system_path, "system-default");
}

static uint32_t test_pointer_time_msec(void) {
	struct timespec now = {0};
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)((uint64_t)now.tv_sec * 1000 +
		(uint64_t)now.tv_nsec / 1000000);
}

static void test_pointer_frame(struct engineos_shell_server *server,
		const char *reason) {
	wl_signal_emit_mutable(&server->test_pointer.events.frame,
		&server->test_pointer);
	write_shell_state(server, reason);
}

static bool handle_test_pointer_request(
		struct engineos_shell_server *server, struct json_object *request,
		const char *op, char *error, size_t error_size) {
	if (!server->test_pointer_initialized) {
		snprintf(error, error_size,
			"test pointer is unavailable outside an enabled headless proof");
		return false;
	}

	if (strcmp(op, "test-pointer-place") == 0) {
		double x = 0.0, y = 0.0;
		if (!json_extract_double(request, "x", &x) ||
				!json_extract_double(request, "y", &y)) {
			snprintf(error, error_size, "missing test pointer coordinates");
			return false;
		}
		wlr_cursor_warp_closest(server->cursor, NULL, x, y);
		test_pointer_frame(server, "test-pointer-place");
		return true;
	}

	if (strcmp(op, "test-pointer-motion") == 0) {
		double dx = 0.0, dy = 0.0;
		if (!json_extract_double(request, "dx", &dx) ||
				!json_extract_double(request, "dy", &dy) ||
				fabs(dx) > 10000.0 || fabs(dy) > 10000.0) {
			snprintf(error, error_size, "invalid test pointer motion");
			return false;
		}
		struct wlr_pointer_motion_event event = {
			.pointer = &server->test_pointer,
			.time_msec = test_pointer_time_msec(),
			.delta_x = dx,
			.delta_y = dy,
			.unaccel_dx = dx,
			.unaccel_dy = dy,
		};
		wl_signal_emit_mutable(&server->test_pointer.events.motion, &event);
		test_pointer_frame(server, "test-pointer-motion");
		return true;
	}

	if (strcmp(op, "test-pointer-absolute") == 0) {
		double x = 0.0, y = 0.0;
		if (!json_extract_double(request, "x", &x) ||
				!json_extract_double(request, "y", &y) ||
				x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) {
			snprintf(error, error_size,
				"invalid normalized test pointer coordinates");
			return false;
		}
		struct wlr_pointer_motion_absolute_event event = {
			.pointer = &server->test_pointer,
			.time_msec = test_pointer_time_msec(),
			.x = x,
			.y = y,
		};
		wl_signal_emit_mutable(&server->test_pointer.events.motion_absolute,
			&event);
		test_pointer_frame(server, "test-pointer-absolute");
		return true;
	}

	if (strcmp(op, "test-pointer-button") == 0) {
		int button = 0;
		char state[16] = {0};
		if (!json_extract_int(request, "button", &button) || button <= 0 ||
				!json_extract_string(request, "state", state, sizeof(state)) ||
				(strcmp(state, "pressed") != 0 &&
				 strcmp(state, "released") != 0)) {
			snprintf(error, error_size, "invalid test pointer button");
			return false;
		}
		struct wlr_pointer_button_event event = {
			.pointer = &server->test_pointer,
			.time_msec = test_pointer_time_msec(),
			.button = (uint32_t)button,
			.state = strcmp(state, "pressed") == 0 ?
				WL_POINTER_BUTTON_STATE_PRESSED :
				WL_POINTER_BUTTON_STATE_RELEASED,
		};
		wlr_pointer_notify_button(&server->test_pointer, &event);
		test_pointer_frame(server, "test-pointer-button");
		return true;
	}

	if (strcmp(op, "test-pointer-axis") == 0) {
		double delta = 0.0;
		if (!json_extract_double(request, "delta", &delta) ||
				fabs(delta) > 10000.0) {
			snprintf(error, error_size, "invalid test pointer axis");
			return false;
		}
		struct wlr_pointer_axis_event event = {
			.pointer = &server->test_pointer,
			.time_msec = test_pointer_time_msec(),
			.source = WL_POINTER_AXIS_SOURCE_WHEEL,
			.orientation = WL_POINTER_AXIS_VERTICAL_SCROLL,
			.relative_direction =
				WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL,
			.delta = delta,
			.delta_discrete = delta < 0 ?
				-WLR_POINTER_AXIS_DISCRETE_STEP :
				WLR_POINTER_AXIS_DISCRETE_STEP,
		};
		wl_signal_emit_mutable(&server->test_pointer.events.axis, &event);
		test_pointer_frame(server, "test-pointer-axis");
		return true;
	}

	snprintf(error, error_size, "unsupported test pointer operation");
	return false;
}

static void handle_preview_request_json(struct engineos_shell_server *server,
		int client_fd, struct json_object *request) {
	char op[32] = {0};
	if (!json_extract_string(request, "op", op, sizeof(op))) {
		preview_write_response(client_fd, "error", "missing op");
		return;
	}

	if (strcmp(op, "ping") == 0) {
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strncmp(op, "test-pointer-", 13) == 0) {
		char error[256] = {0};
		if (!handle_test_pointer_request(server, request, op, error,
				sizeof(error))) {
			preview_write_response(client_fd, "error", error);
			return;
		}
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "terminal-theme") == 0) {
		struct json_object *theme = NULL;
		if (!json_object_object_get_ex(request, "theme", &theme)) {
			preview_write_response(client_fd, "error", "missing theme");
			return;
		}
		char error[512] = {0};
		if (!apply_terminal_theme(server, theme, error, sizeof(error))) {
			preview_write_response(client_fd, "error",
				error[0] != '\0' ? error : "terminal theme failed");
			return;
		}
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "hide-wallpaper") == 0) {
		hide_wallpaper(server, "ipc-hide-wallpaper");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "focus-window") == 0) {
		int window_id = 0;
		if (!json_extract_int(request, "window_id", &window_id) ||
				window_id <= 0) {
			preview_write_response(client_fd, "error", "missing window_id");
			return;
		}
		struct engineos_shell_view *view =
			find_mapped_view_id(server, (unsigned int)window_id);
		if (view == NULL) {
			preview_write_response(client_fd, "error", "unknown window_id");
			return;
		}
		activate_view(view, "ipc-focus-window");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "relayout-windows") == 0) {
		relayout_shell_views(server, "ipc-relayout-windows");
		write_shell_state(server, "ipc-relayout-windows");
		preview_write_response(client_fd, "ok", NULL);
		return;
	}
	if (strcmp(op, "wallpaper") == 0) {
		char path[PATH_MAX] = {0};
		if (!json_extract_string(request, "path", path, sizeof(path))) {
			preview_write_response(client_fd, "error", "missing path");
			return;
		}
		char mode[32] = {0};
		json_extract_string(request, "mode", mode, sizeof(mode));
		struct engineos_preview_bounds bounds = {0};
		request_preview_bounds(request, &bounds);
		int opacity = request_opacity_percent(request, 100);
		char error[512] = {0};
		if (!show_wallpaper(server, path, NULL, mode, &bounds, opacity,
				error, sizeof(error))) {
			preview_write_response(client_fd, "error",
				error[0] != '\0' ? error : "wallpaper failed");
			return;
		}
		preview_write_response(client_fd, "ok", NULL);
		return;
	}

	preview_write_response(client_fd, "error", "unsupported op");
}
static void handle_preview_request(struct engineos_shell_server *server,
		int client_fd, const char *request_text) {
	enum json_tokener_error parse_error = json_tokener_success;
	struct json_object *request =
		json_tokener_parse_verbose(request_text, &parse_error);
	if (request == NULL || parse_error != json_tokener_success ||
			!json_object_is_type(request, json_type_object)) {
		preview_write_response(client_fd, "error", "invalid json request");
		if (request != NULL) {
			json_object_put(request);
		}
		return;
	}
	handle_preview_request_json(server, client_fd, request);
	json_object_put(request);
}

static int preview_socket_event(int fd, uint32_t mask, void *data) {
	struct engineos_shell_server *server = data;
	if ((mask & WL_EVENT_READABLE) == 0) {
		return 0;
	}

	struct sockaddr_un addr;
	socklen_t addr_len = sizeof(addr);
	int client_fd = accept4(fd, (struct sockaddr *)&addr, &addr_len,
		SOCK_CLOEXEC);
	if (client_fd < 0) {
		if (errno != EAGAIN && errno != EWOULDBLOCK) {
			wlr_log(WLR_ERROR, "preview ipc accept failed: %s",
				strerror(errno));
		}
		return 0;
	}
	struct ucred credentials = {0};
	socklen_t credentials_len = sizeof(credentials);
	if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &credentials,
			&credentials_len) < 0 || credentials.uid != getuid()) {
		preview_write_response(client_fd, "error", "unauthorized ipc peer");
		close(client_fd);
		return 0;
	}
	struct timeval timeout = {.tv_sec = 0, .tv_usec = 250000};
	setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

	char request[8192];
	size_t used = 0;
	bool complete = false;
	while (used < sizeof(request) - 1) {
		ssize_t count = read(client_fd, request + used,
			sizeof(request) - 1 - used);
		if (count < 0 && errno == EINTR) {
			continue;
		}
		if (count <= 0) {
			break;
		}
		char *newline = memchr(request + used, '\n', (size_t)count);
		used += (size_t)count;
		if (newline != NULL) {
			used = (size_t)(newline - request);
			complete = true;
			break;
		}
	}
	if (used == 0) {
		preview_write_response(client_fd, "error", "empty request");
		close(client_fd);
		return 0;
	}
	if (!complete) {
		preview_write_response(client_fd, "error",
			used >= sizeof(request) - 1 ? "request too large" :
				"request must end with newline");
		close(client_fd);
		return 0;
	}
	request[used] = '\0';
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
	if (!mkdir_p(server->state_dir, 0700)) {
		wlr_log(WLR_ERROR, "failed to create preview ipc dir %s: %s",
			server->state_dir, strerror(errno));
		return false;
	}
	if (chmod(server->state_dir, 0700) < 0) {
		wlr_log(WLR_ERROR, "failed to restrict preview ipc dir %s: %s",
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
	if (chmod(server->preview_socket_path, 0600) < 0) {
		wlr_log(WLR_ERROR, "failed to restrict preview ipc socket %s: %s",
			server->preview_socket_path, strerror(errno));
		close(sock);
		unlink(server->preview_socket_path);
		return false;
	}

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

	if (!mkdir_p(server->state_dir, 0700)) {
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
	if (fchmod(fileno(file), 0600) < 0) {
		wlr_log(WLR_ERROR, "failed to restrict shell state file %s: %s",
			tmp_file, strerror(errno));
		fclose(file);
		unlink(tmp_file);
		free(tmp_file);
		return;
	}

	fprintf(file, "{\n");
	fprintf(file, "  \"schema\": \"engineos-shell-state-v0\",\n");
	fprintf(file, "  \"pid\": %ld,\n", (long)getpid());
	fprintf(file, "  \"mode\": ");
	json_write_string(file, server->mode_name);
	fprintf(file, ",\n  \"backend\": ");
	json_write_string(file, getenv("WLR_BACKENDS"));
	fprintf(file, ",\n  \"wayland_display\": ");
	json_write_string(file, getenv("WAYLAND_DISPLAY"));
	fprintf(file, ",\n  \"screencopy\": %s",
		server->screencopy_mgr != NULL ? "true" : "false");
	fprintf(file, ",\n  \"terminal_theme\": {\"name\": ");
	json_write_string(file, server->terminal_theme.name);
	fprintf(file, ", \"source\": ");
	json_write_string(file, server->terminal_theme_source);
	fprintf(file, ", \"error\": ");
	json_write_string(file, server->terminal_theme_error[0] != '\0' ?
		server->terminal_theme_error : NULL);
	fprintf(file,
		", \"generation\": %llu, \"foreground\": \"#%06x\", \"background\": \"#%06x\", \"colors\": [",
		(unsigned long long)server->terminal_theme.generation,
		server->terminal_theme.foreground, server->terminal_theme.background);
	for (size_t index = 0;
			index < ENGINEOS_TERMINAL_THEME_COLOR_COUNT; index++) {
		fprintf(file, "%s\"#%06x\"", index == 0 ? "" : ",",
			server->terminal_theme.colors[index]);
	}
	fprintf(file, "]}");
	fprintf(file, ",\n  \"mux\": {\"mode\": ");
	json_write_string(file, "native");
	fprintf(file, ", \"connected\": %s, \"revision\": %llu, \"socket\": ",
		server->mux_client.ready ? "true" : "false",
		(unsigned long long)server->mux_client.revision);
	json_write_string(file, server->mux_client.socket_path);
	struct engineos_shell_output *ui_output = focused_mux_output(server);
	struct engineos_mux_pane_model *focused_state_pane =
		focused_mux_pane(server);
	fprintf(file, ", \"session_id\": ");
	json_write_string(file, ui_output != NULL ?
		ui_output->mux_snapshot.session_id : NULL);
	fprintf(file, ", \"prefix\": ");
	json_write_string(file, server->mux_client.prefix);
	fprintf(file, ", \"prefix2\": ");
	json_write_string(file, server->mux_client.prefix2);
	fprintf(file, ", \"snapshot_retry_count\": %llu",
		(unsigned long long)server->mux_snapshot_retry_count);
	const struct engineos_mux_ui_model *focused_ui = ui_output != NULL ?
		&ui_output->mux_snapshot.ui : NULL;
	fprintf(file,
		", \"frontend_client_id\": %u, \"client_view_id\": %u, \"ui_invalidation_count\": %llu, \"last_ui_invalidated_view_id\": %u, \"pane_id\": \"%%%u\", \"generation\": %u, \"grid\": {\"revision\": %llu, \"columns\": %u, \"rows\": %u, \"cursor_x\": %u, \"cursor_y\": %u, \"nonblank_cells\": %u, \"rendered\": %s, \"pixel_width\": %d, \"pixel_height\": %d, \"glyph_cells\": %u, \"renderer\": ",
		server->mux_client.frontend_client_id,
		server->mux_client.primary_view_id,
		(unsigned long long)server->mux_client.ui_invalidation_count,
		server->mux_client.last_ui_invalidated_view_id,
		focused_state_pane != NULL ? focused_state_pane->pane_id : 0,
		focused_state_pane != NULL ? focused_state_pane->generation : 0,
		(unsigned long long)server->mux_client.grid_revision,
		server->mux_client.grid_columns, server->mux_client.grid_rows,
		server->mux_client.grid_cursor_x, server->mux_client.grid_cursor_y,
		server->mux_client.grid_nonblank_cells,
		server->mux_terminal_scene != NULL ? "true" : "false",
		server->mux_terminal_width, server->mux_terminal_height,
		server->mux_terminal_glyph_cells);
	json_write_string(file, server->mux_terminal_renderer != NULL ?
		engineos_terminal_renderer_mode(server->mux_terminal_renderer) : NULL);
	fprintf(file,
		", \"atlas_entries\": %u, \"damaged_cells\": %u, \"nonblank_pixels\": %u, \"frame\": %llu}, \"ui\": {\"columns\": %u, \"rows\": %u, \"status_y\": %d, \"status_rows\": %zu, \"mode\": ",
		server->mux_terminal_atlas_entries,
		server->mux_terminal_damaged_cells,
		server->mux_terminal_nonblank_pixels,
		(unsigned long long)server->mux_terminal_frame,
		focused_ui != NULL ? focused_ui->columns : server->mux_client.ui_columns,
		focused_ui != NULL ? focused_ui->rows : server->mux_client.ui_rows,
		focused_ui != NULL ? focused_ui->status_y : server->mux_client.ui_status_y,
		focused_ui != NULL ? focused_ui->status_row_count :
			server->mux_client.ui_status_row_count);
	json_write_string(file, focused_ui != NULL ? focused_ui->mode :
		server->mux_client.ui_mode);
	fprintf(file,
		", \"rendered\": %s, \"prompt_active\": %s, \"message_active\": %s, \"menu_active\": %s, \"menu_x\": %u, \"menu_y\": %u, \"menu_width\": %u, \"menu_height\": %u}",
		server->mux_ui_scene != NULL &&
			(focused_ui != NULL ? focused_ui->status_row_count :
			 server->mux_client.ui_status_row_count) != 0 ? "true" : "false",
		focused_ui != NULL ? (focused_ui->prompt_active ? "true" : "false") :
			(server->mux_client.ui_prompt_active ? "true" : "false"),
		focused_ui != NULL ? (focused_ui->message_active ? "true" : "false") :
			(server->mux_client.ui_message_active ? "true" : "false"),
		focused_ui != NULL ? (focused_ui->menu_active ? "true" : "false") :
			(server->mux_client.ui_menu_active ? "true" : "false"),
		focused_ui != NULL ? focused_ui->menu_x : server->mux_client.ui_menu_x,
		focused_ui != NULL ? focused_ui->menu_y : server->mux_client.ui_menu_y,
		focused_ui != NULL ? focused_ui->menu_width :
			server->mux_client.ui_menu_width,
		focused_ui != NULL ? focused_ui->menu_height :
			server->mux_client.ui_menu_height);
	fprintf(file, ", \"presentation\": {");
	fprintf(file, "\"type\": ");
	json_write_string(file, focused_state_pane != NULL ?
		focused_state_pane->presentation : NULL);
	fprintf(file, ", \"view_mode\": ");
	json_write_string(file, focused_state_pane != NULL ?
		focused_state_pane->view_mode : NULL);
	fprintf(file, ", \"mapped\": %s, \"surface_tabs\": %u, \"active_surface_id\": %u, \"lease_client_id\": %u, \"lease_view_id\": %u, \"lease_owned_by_focused_view\": %s, \"popups\": %u, \"terminal_visible\": %s}",
		focused_state_pane != NULL && focused_state_pane->presentation_mapped ?
			"true" : "false",
		focused_state_pane != NULL ? focused_state_pane->surface_tabs : 0,
		focused_state_pane != NULL ? focused_state_pane->active_surface_id : 0,
		focused_state_pane != NULL ? focused_state_pane->lease_client_id : 0,
		focused_state_pane != NULL ? focused_state_pane->lease_view_id : 0,
		focused_state_pane != NULL && focused_state_pane->lease_view_id != 0 &&
			focused_state_pane->lease_view_id ==
			server->mux_client.primary_view_id ? "true" : "false",
		server->mux_popup_count,
		focused_state_pane != NULL &&
			strcmp(focused_state_pane->view_mode, "presentation") == 0 &&
			focused_state_pane->presentation_mapped ? "false" : "true");
	fprintf(file, ", \"panes\": [");
	for (size_t index = 0; ui_output != NULL &&
			index < ui_output->mux_snapshot.pane_count; index++) {
		const struct engineos_mux_pane_model *pane =
			&ui_output->mux_snapshot.panes[index];
		struct engineos_mux_client grid_client;
		bool grid_ready = pane_render_client(server, pane, &grid_client);
		struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(server,
			pane->pane_id, pane->generation);
		struct engineos_mux_pane_output_scene *primary_output_scene =
			pane_scene != NULL ? find_mux_pane_output_scene(pane_scene,
				server->mux_client.primary_view_id) : NULL;
		size_t output_scene_count = 0;
		if (pane_scene != NULL) {
			struct engineos_mux_pane_output_scene *counted_scene;
			wl_list_for_each(counted_scene, &pane_scene->output_scenes, link)
				output_scene_count++;
		}
		int cell_width = primary_output_scene != NULL && grid_ready ?
			primary_output_scene->stats.width /
			(int)grid_client.grid_columns : 0;
		int cell_height = primary_output_scene != NULL && grid_ready ?
			primary_output_scene->stats.height /
			(int)grid_client.grid_rows : 0;
		if (index != 0) {
			fprintf(file, ",");
		}
		fprintf(file,
			"{\"pane_id\": \"%%%u\", \"generation\": %u, \"left\": %u, \"top\": %u, \"columns\": %u, \"rows\": %u, \"active\": %s, \"visible\": %s, \"window_active\": %s, \"presentation\": ",
			pane->pane_id, pane->generation, pane->left, pane->top,
			pane->columns, pane->rows, pane->active ? "true" : "false",
			pane->visible ? "true" : "false",
			pane->window_active ? "true" : "false");
		json_write_string(file, pane->presentation);
		fprintf(file, ", \"view_mode\": ");
		json_write_string(file, pane->view_mode);
		fprintf(file,
			", \"mapped\": %s, \"surface_tabs\": %u, \"active_surface_id\": %u, \"lease_client_id\": %u, \"lease_view_id\": %u, \"lease_owned_by_focused_view\": %s, \"image\": {\"id\": %u, \"bytes\": %u, \"lease_client_id\": %u, \"lease_view_id\": %u, \"mime\": ",
			pane->presentation_mapped ? "true" : "false",
			pane->surface_tabs, pane->active_surface_id,
			pane->lease_client_id, pane->lease_view_id,
			pane->lease_view_id != 0 && pane->lease_view_id ==
				server->mux_client.primary_view_id ? "true" : "false",
			pane->image_id, pane->image_bytes, pane->image_lease_client_id,
			pane->image_lease_view_id);
		json_write_string(file, pane->image_id != 0 ? pane->image_mime : NULL);
		fprintf(file, ", \"owner\": ");
		json_write_string(file, pane->image_owner);
		fprintf(file,
			"}, \"grid\": {\"ready\": %s, \"subscribed\": %s, \"revision\": %llu, \"columns\": %u, \"rows\": %u, \"nonblank_cells\": %u}, \"scene\": {\"rendered\": %s, \"output_scene_count\": %zu, \"terminal_visible\": %s, \"pixel_x\": %d, \"pixel_y\": %d, \"pixel_width\": %d, \"pixel_height\": %d, \"glyph_cells\": %u, \"damaged_cells\": %u, \"nonblank_pixels\": %u, \"frame\": %llu, \"renderer\": ",
			grid_ready ? "true" : "false",
			grid_ready ? "true" : "false",
			(unsigned long long)(grid_ready ? grid_client.grid_revision : 0),
			grid_ready ? grid_client.grid_columns : 0,
			grid_ready ? grid_client.grid_rows : 0,
			grid_ready ? grid_client.grid_nonblank_cells : 0,
			pane_scene != NULL ? "true" : "false",
			output_scene_count,
			primary_output_scene != NULL && pane->visible &&
				primary_output_scene->terminal_scene->node.enabled ?
				"true" : "false",
			(int)pane->left * cell_width, (int)pane->top * cell_height,
			primary_output_scene != NULL ? primary_output_scene->stats.width : 0,
			primary_output_scene != NULL ? primary_output_scene->stats.height : 0,
			primary_output_scene != NULL ? primary_output_scene->stats.glyph_cells : 0,
			primary_output_scene != NULL ? primary_output_scene->stats.damaged_cells : 0,
			primary_output_scene != NULL ? primary_output_scene->stats.nonblank_pixels : 0,
			(unsigned long long)(primary_output_scene != NULL ?
				primary_output_scene->stats.frame : 0));
		json_write_string(file, primary_output_scene != NULL ?
			engineos_terminal_renderer_mode(primary_output_scene->renderer) : NULL);
		fprintf(file, "}}");
	}
	fprintf(file, "]}");
	fprintf(file, ",\n  \"output_views\": [");
	bool first_output_view = true;
	struct engineos_shell_output *shell_output;
	wl_list_for_each(shell_output, &server->outputs, link) {
		if (!shell_output->mux_registered)
			continue;
		if (!first_output_view)
			fprintf(file, ",");
		first_output_view = false;
		int output_width = 0, output_height = 0;
		wlr_output_effective_resolution(shell_output->output,
			&output_width, &output_height);
		fprintf(file,
			"{\"view_id\": %u, \"output\": ",
			shell_output->mux_view_id);
		json_write_string(file, shell_output->output->name);
		fprintf(file,
			", \"session_id\": ");
		json_write_string(file, shell_output->mux_snapshot.session_id);
		size_t output_grid_ready_count = 0;
		size_t output_grid_subscribed_count = 0;
		uint64_t output_grid_revision = 0;
		for (size_t pane_index = 0;
				pane_index < shell_output->mux_snapshot.pane_count;
				pane_index++) {
			struct engineos_mux_pane_model *pane =
				&shell_output->mux_snapshot.panes[pane_index];
			struct engineos_mux_client grid_client;
			if (!pane_render_client(server, pane, &grid_client))
				continue;
			output_grid_ready_count++;
			output_grid_subscribed_count++;
			if (pane->pane_id == shell_output->mux_snapshot.pane_id &&
					pane->generation ==
						shell_output->mux_snapshot.pane_generation)
				output_grid_revision = grid_client.grid_revision;
		}
		fprintf(file,
			", \"model_ready\": %s, \"model_revision\": %llu, \"pane_count\": %zu, \"pane_id\": \"%%%u\", \"pane_generation\": %u, \"grid_ready_count\": %zu, \"grid_subscribed_count\": %zu, \"grid_revision\": %llu",
			shell_output->mux_snapshot.ready ? "true" : "false",
			(unsigned long long)shell_output->mux_snapshot.revision,
			shell_output->mux_snapshot.pane_count,
			shell_output->mux_snapshot.pane_id,
			shell_output->mux_snapshot.pane_generation,
			output_grid_ready_count, output_grid_subscribed_count,
			(unsigned long long)output_grid_revision);
		size_t console_scene_count = 0, presentation_surface_count = 0;
		size_t bound_presentation_surface_count = 0;
		size_t preview_count = 0;
		size_t rendered_pane_count = 0;
		uint64_t selected_renderer_frame = 0;
		const char *selected_renderer = NULL;
		struct engineos_mux_pane_model *output_selected =
			find_output_pane_model(shell_output,
				shell_output->mux_snapshot.pane_id,
				shell_output->mux_snapshot.pane_generation);
		struct engineos_mux_pane_scene *output_pane_scene;
		wl_list_for_each(output_pane_scene, &server->mux_pane_scenes, link) {
			struct engineos_mux_pane_output_scene *copy =
				find_mux_pane_output_scene(output_pane_scene,
					shell_output->mux_view_id);
			if (copy != NULL && copy->terminal_scene->node.enabled)
				console_scene_count++;
			if (copy != NULL && copy->renderer != NULL) {
				rendered_pane_count++;
				if (output_pane_scene->pane_id ==
						shell_output->mux_snapshot.pane_id &&
						output_pane_scene->generation ==
						shell_output->mux_snapshot.pane_generation) {
					selected_renderer_frame = copy->stats.frame;
					selected_renderer = engineos_terminal_renderer_mode(
						copy->renderer);
				}
			}
			struct engineos_preview_surface *output_preview;
			wl_list_for_each(output_preview, &server->previews, link) {
				if (copy != NULL && output_preview->scene_buffer != NULL &&
						output_preview->scene_buffer->node.parent == copy->tree &&
						output_preview->scene_buffer->node.enabled)
					preview_count++;
			}
			struct engineos_shell_view *surface_view;
			wl_list_for_each(surface_view, &server->views, link) {
				if (copy != NULL && surface_view->mapped && surface_view->mux_bound &&
						surface_view->scene_tree->node.parent == copy->tree) {
					bound_presentation_surface_count++;
					if (surface_view->scene_tree->node.enabled)
						presentation_surface_count++;
				}
			}
		}
		fprintf(file,
			", \"pixel_width\": %d, \"pixel_height\": %d, \"scale_milli\": %u, \"scene_x\": %d, \"scene_y\": %d, \"frame_commits\": %llu, \"frame_failures\": %llu, \"scheduled_mux_revision\": %llu, \"scheduled_grid_revision\": %llu, \"scheduled_renderer_frame\": %llu, \"committed_mux_revision\": %llu, \"committed_grid_revision\": %llu, \"committed_renderer_frame\": %llu, \"console_scene_count\": %zu, \"rendered_pane_count\": %zu, \"selected_renderer_frame\": %llu, \"selected_renderer\": ",
			output_width, output_height,
			(uint32_t)(shell_output->output->scale * 1000.0 + 0.5),
			shell_output->mux_scene_tree != NULL ?
				shell_output->mux_scene_tree->node.x : 0,
			shell_output->mux_scene_tree != NULL ?
				shell_output->mux_scene_tree->node.y : 0,
			(unsigned long long)shell_output->frame_commits,
			(unsigned long long)shell_output->frame_failures,
			(unsigned long long)shell_output->scheduled_mux_revision,
			(unsigned long long)shell_output->scheduled_grid_revision,
			(unsigned long long)shell_output->scheduled_renderer_frame,
			(unsigned long long)shell_output->committed_mux_revision,
			(unsigned long long)shell_output->committed_grid_revision,
			(unsigned long long)shell_output->committed_renderer_frame,
			console_scene_count, rendered_pane_count,
			(unsigned long long)selected_renderer_frame);
		json_write_string(file, selected_renderer);
		fprintf(file, ", \"panes\": [");
		bool first_output_pane = true;
		for (size_t pane_index = 0;
				pane_index < shell_output->mux_snapshot.pane_count;
				pane_index++) {
			struct engineos_mux_pane_model *pane =
				&shell_output->mux_snapshot.panes[pane_index];
			if (!pane->window_active)
				continue;
			struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(
				server, pane->pane_id, pane->generation);
			struct engineos_mux_pane_output_scene *copy = pane_scene != NULL ?
				find_mux_pane_output_scene(pane_scene,
					shell_output->mux_view_id) : NULL;
			if (!first_output_pane)
				fprintf(file, ",");
			first_output_pane = false;
			int pane_x = copy != NULL ? copy->tree->node.x : 0;
			int pane_y = copy != NULL ? copy->tree->node.y : 0;
			int pane_width = copy != NULL ? copy->stats.width : 0;
			int pane_height = copy != NULL ? copy->stats.height : 0;
			bool within_output = copy != NULL && pane_x >= 0 && pane_y >= 0 &&
				pane_width > 0 && pane_height > 0 &&
				pane_x + pane_width <= output_width &&
				pane_y + pane_height <= output_height;
			fprintf(file,
				"{\"pane_id\": \"%%%u\", \"generation\": %u, \"visible\": %s, \"terminal_visible\": %s, \"pixel_x\": %d, \"pixel_y\": %d, \"pixel_width\": %d, \"pixel_height\": %d, \"within_output\": %s, \"frame\": %llu, \"nonblank_pixels\": %u, \"renderer\": ",
				pane->pane_id, pane->generation,
				pane->visible ? "true" : "false",
				copy != NULL && pane->visible &&
					copy->terminal_scene->node.enabled ?
					"true" : "false",
				pane_x, pane_y, pane_width, pane_height,
				within_output ? "true" : "false",
				(unsigned long long)(copy != NULL ? copy->stats.frame : 0),
				copy != NULL ? copy->stats.nonblank_pixels : 0);
			json_write_string(file, copy != NULL ?
				engineos_terminal_renderer_mode(copy->renderer) : NULL);
			fprintf(file, "}");
		}
		fprintf(file, "]");
		fprintf(file,
			", \"ui\": {\"ready\": %s, \"columns\": %u, \"rows\": %u, \"status_y\": %d, \"status_rows\": %zu, \"mode\": ",
			shell_output->mux_snapshot.ui.ready ? "true" : "false",
			shell_output->mux_snapshot.ui.columns,
			shell_output->mux_snapshot.ui.rows,
			shell_output->mux_snapshot.ui.status_y,
			shell_output->mux_snapshot.ui.status_row_count);
		json_write_string(file, shell_output->mux_snapshot.ui.mode);
		fprintf(file, ", \"status_text\": ");
		json_write_string(file,
			shell_output->mux_snapshot.ui.status_row_count != 0 ?
			shell_output->mux_snapshot.ui.status_rows[0].text : NULL);
		fprintf(file,
			", \"rendered\": %s, \"renderer\": ",
			shell_output->mux_ui_scene != NULL &&
			shell_output->mux_ui_renderer != NULL ? "true" : "false");
		json_write_string(file, shell_output->mux_ui_renderer != NULL ?
			engineos_terminal_renderer_mode(shell_output->mux_ui_renderer) : NULL);
		fprintf(file,
			", \"frame\": %llu}, \"bound_presentation_surface_count\": %zu, \"presentation_surface_count\": %zu, \"preview_count\": %zu, \"preview_visible\": %s, \"focused\": %s, \"owns_selected_presentation\": %s}",
			(unsigned long long)shell_output->mux_ui_stats.frame,
			bound_presentation_surface_count,
			presentation_surface_count,
			preview_count, preview_count > 0 ? "true" : "false",
			shell_output->mux_view_id == server->mux_client.primary_view_id ?
				"true" : "false",
			output_selected != NULL && output_selected->lease_client_id ==
				server->mux_client.frontend_client_id &&
			shell_output->mux_view_id == output_selected->lease_view_id ?
				"true" : "false");
	}
	fprintf(file, "]");
	fprintf(file, ",\n  \"input\": {\"mode\": ");
	json_write_string(file, input_mode_name(server->input_mode));
	fprintf(file,
		", \"capture\": %s, \"emergency_released\": %s, \"view_id\": %u, \"pane_id\": \"%%%u\", \"pane_generation\": %u, \"pointer_view_id\": %u},\n",
		server->game_capture ? "true" : "false",
		server->emergency_released ? "true" : "false",
		ui_output != NULL ? ui_output->mux_view_id : 0,
		focused_state_pane != NULL ? focused_state_pane->pane_id : 0,
		focused_state_pane != NULL ? focused_state_pane->generation : 0,
		server->mux_pointer_view_id);
	fprintf(file,
		"  \"cursor\": {\"locked\": %s, \"constraint_active\": %s, \"constraint_type\": ",
		active_pointer_constraint_is_locked(server) ? "true" : "false",
		server->active_pointer_constraint != NULL ? "true" : "false");
	if (server->active_pointer_constraint != NULL) {
		json_write_string(file,
			pointer_constraint_type_name(server->active_pointer_constraint->type));
	} else {
		fputs("null", file);
	}
	fprintf(file,
		", \"hidden\": %s, \"client_owned\": %s, \"x\": %.1f, \"y\": %.1f},\n",
		server->cursor_hidden ? "true" : "false",
		server->cursor_client_owned ? "true" : "false",
		server->cursor != NULL ? server->cursor->x : 0.0,
		server->cursor != NULL ? server->cursor->y : 0.0);
	fprintf(file, "  \"counts\": {\"outputs\": %u, \"keyboards\": %u, \"pointers\": %u, \"views\": %u},\n",
		server->output_count, server->keyboard_count,
		server->pointer_count, server->view_count);
	fprintf(file, "  \"last_reason\": ");
	json_write_string(file, reason != NULL ? reason : "unspecified");
	struct engineos_preview_surface *primary_preview = NULL;
	struct engineos_preview_surface *state_preview;
	wl_list_for_each(state_preview, &server->previews, link)
		primary_preview = state_preview;
	fprintf(file, ",\n  \"preview\": ");
	write_preview_json(file, primary_preview);
	fprintf(file, ",\n  \"preview_reconciliation\": {\"status\": ");
	json_write_string(file, server->preview_reconciliation_status[0] != '\0' ?
		server->preview_reconciliation_status : "idle");
	fprintf(file, ", \"error\": ");
	json_write_string(file, server->preview_reconciliation_error[0] != '\0' ?
		server->preview_reconciliation_error : NULL);
	fprintf(file,
		", \"failed_pane_id\": \"%%%u\", \"failed_generation\": %u, \"failed_image_id\": %u}",
		server->preview_failed_pane_id, server->preview_failed_generation,
		server->preview_failed_image_id);
	fprintf(file, ",\n  \"previews\": [");
	bool first_preview = true;
	wl_list_for_each(state_preview, &server->previews, link) {
		if (!first_preview)
			fprintf(file, ",");
		first_preview = false;
		write_preview_json(file, state_preview);
	}
	fprintf(file, "]");
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
	fprintf(file, ",\n  \"windows\": [");

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
		fprintf(file, "\n    {\"id\": %u, \"role\": ", view->view_id);
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
			fprintf(file, ", \"bound\": %s, \"pane_key\": ",
				view->mux_bound ? "true" : "false");
			json_write_string(file, "");
			fprintf(file, ", \"pane_id\": ");
			char native_pane_id[32] = {0};
			if (view->mux_bound)
				snprintf(native_pane_id, sizeof(native_pane_id), "%%%u",
					view->mux_pane_id);
			json_write_string(file, view->mux_bound ? native_pane_id : "");
			fprintf(file,
				", \"mux_generation\": %u, \"surface_id\": %u, \"surface_role\": \"%s\", \"client_pid\": %ld, \"presentation_visible\": %s",
				view->mux_bound ? view->mux_pane_generation : 0,
				view->mux_bound ? view->view_id : 0,
				view->mux_transient ? "transient" : "toplevel",
				view->mux_bound ? (long)view->mux_client_pid : 0L,
				view->mux_bound && view->mux_presentation_visible ?
					"true" : "false");
			fprintf(file, "}");
		}
		if (!first_window) {
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
	wlr_log(WLR_DEBUG, "pointer focus cleared mode=%s capture=%s reason=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		reason != NULL ? reason : "unspecified");
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

static bool view_is_native_mux_game(struct engineos_shell_view *view) {
	if (view == NULL || !view->mux_bound)
		return false;
	struct engineos_mux_pane_model *pane = find_shell_pane_model(view->server,
		view->mux_pane_id, view->mux_pane_generation);
	return pane != NULL && strcmp(pane->presentation, "game") == 0;
}

static bool game_capture_active(struct engineos_shell_server *server) {
	return server != NULL &&
		server->game_capture &&
		server->input_mode == ENGINEOS_INPUT_GAME &&
		server->focused_view != NULL &&
		server->focused_view->mapped &&
		view_is_native_mux_game(server->focused_view);
}

static bool active_pointer_constraint_is_locked(
		struct engineos_shell_server *server) {
	return game_capture_active(server) &&
		server->active_pointer_constraint != NULL &&
		server->active_pointer_constraint->type ==
			WLR_POINTER_CONSTRAINT_V1_LOCKED;
}

static struct wlr_surface *focused_game_surface(
		struct engineos_shell_server *server) {
	if (!game_capture_active(server) ||
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
	sync_cursor_image(server, "pointer-constraint-destroyed");
	write_shell_state(server, "pointer-constraint-destroyed");
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

static void drag_icon_node_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_server *server =
		wl_container_of(listener, server, drag_icon_node_destroy);

	remove_listener_if_linked(&server->drag_icon_node_destroy);
	server->drag_icon_tree = NULL;
	wlr_log(WLR_INFO, "drag icon scene node destroyed");
}

static void clear_active_drag(struct engineos_shell_server *server,
		const char *reason) {
	if (server == NULL) {
		return;
	}

	remove_listener_if_linked(&server->active_drag_motion);
	remove_listener_if_linked(&server->active_drag_drop);
	remove_listener_if_linked(&server->active_drag_destroy);
	remove_listener_if_linked(&server->drag_icon_node_destroy);

	if (server->drag_icon_tree != NULL) {
		wlr_scene_node_destroy(&server->drag_icon_tree->node);
		server->drag_icon_tree = NULL;
	}

	if (server->active_drag != NULL) {
		wlr_log(WLR_INFO, "drag cleared reason=%s",
			reason != NULL ? reason : "unspecified");
	}
	server->active_drag = NULL;
	schedule_outputs(server);
}

static void update_drag_icon_position(struct engineos_shell_server *server,
		const char *reason) {
	if (server == NULL || server->drag_icon_tree == NULL ||
			server->cursor == NULL) {
		return;
	}

	wlr_scene_node_set_position(&server->drag_icon_tree->node,
		(int)server->cursor->x, (int)server->cursor->y);
	wlr_scene_node_raise_to_top(&server->drag_icon_tree->node);
	wlr_log(WLR_DEBUG, "drag icon position x=%.1f y=%.1f reason=%s",
		server->cursor->x, server->cursor->y,
		reason != NULL ? reason : "unspecified");
	schedule_outputs(server);
}

static void active_drag_motion(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_server *server =
		wl_container_of(listener, server, active_drag_motion);

	update_drag_icon_position(server, "drag-motion");
}

static void active_drag_drop(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, active_drag_drop);
	struct wlr_drag_drop_event *event = data;

	wlr_log(WLR_INFO, "drag drop time=%u", event != NULL ? event->time : 0);
	update_drag_icon_position(server, "drag-drop");
}

static void active_drag_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_server *server =
		wl_container_of(listener, server, active_drag_destroy);

	clear_active_drag(server, "drag-destroy");
}

static void seat_start_drag(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, start_drag);
	struct wlr_drag *drag = data;

	clear_active_drag(server, "new-drag");
	server->active_drag = drag;

	server->active_drag_motion.notify = active_drag_motion;
	wl_signal_add(&drag->events.motion, &server->active_drag_motion);
	server->active_drag_drop.notify = active_drag_drop;
	wl_signal_add(&drag->events.drop, &server->active_drag_drop);
	server->active_drag_destroy.notify = active_drag_destroy;
	wl_signal_add(&drag->events.destroy, &server->active_drag_destroy);

	if (drag->icon != NULL) {
		server->drag_icon_tree =
			wlr_scene_drag_icon_create(&server->scene->tree, drag->icon);
		if (server->drag_icon_tree != NULL) {
			server->drag_icon_tree->node.data = drag->icon;
			server->drag_icon_node_destroy.notify = drag_icon_node_destroy;
			wl_signal_add(&server->drag_icon_tree->node.events.destroy,
				&server->drag_icon_node_destroy);
			update_drag_icon_position(server, "drag-start");
		} else {
			wlr_log(WLR_ERROR, "failed to create drag icon scene node");
		}
	}

	wlr_log(WLR_INFO, "drag started source=%s icon=%s",
		drag->source != NULL ? "client" : "none",
		drag->icon != NULL ? "present" : "none");
}

static void seat_request_start_drag(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, request_start_drag);
	struct wlr_seat_request_start_drag_event *event = data;

	if (wlr_seat_validate_pointer_grab_serial(server->seat,
			event->origin, event->serial)) {
		wlr_log(WLR_INFO, "drag request accepted type=pointer serial=%u",
			event->serial);
		wlr_seat_start_pointer_drag(server->seat, event->drag, event->serial);
		return;
	}

	wlr_log(WLR_INFO, "drag request rejected invalid pointer serial=%u",
		event->serial);
	if (event->drag != NULL && event->drag->source != NULL) {
		wlr_data_source_destroy(event->drag->source);
	}
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

	if (game_capture_active(server)) {
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
	server->emergency_released = false;

	bool native_game = view_is_native_mux_game(view);
	server->game_capture = native_game;
	server->input_mode = native_game ? ENGINEOS_INPUT_GAME :
		ENGINEOS_INPUT_GRAPHICAL;

	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=click-focus role=%s",
		input_mode_name(server->input_mode),
		server->game_capture ? "game" : "none",
		surface_role_name(view->role));
	sync_pointer_constraint(server, "click-focus");
	sync_cursor_image(server, "click-focus");
	write_shell_state(server, "click-focus");
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

static void apply_view_layout(struct engineos_shell_view *view) {
	struct engineos_view_geometry geometry = {0};
	compute_view_geometry(view, &geometry);

	if (view->xdg_surface != NULL &&
			xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
		wlr_xdg_toplevel_set_fullscreen(view->xdg_surface->toplevel,
			geometry.fullscreen);
		wlr_xdg_toplevel_set_maximized(view->xdg_surface->toplevel,
			view->maximized);
		wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
			geometry.width, geometry.height);
		set_toplevel_suspended(view->xdg_surface->toplevel, view->minimized);
	}
	if (view->scene_tree != NULL) {
		if (geometry.layout != NULL &&
				strcmp(geometry.layout, "native-mux-presentation") == 0) {
			struct wlr_box clip = {
				.x = 0,
				.y = 0,
				.width = geometry.width,
				.height = geometry.height,
			};
			wlr_scene_subsurface_tree_set_clip(&view->scene_tree->node, &clip);
		} else {
			wlr_scene_subsurface_tree_set_clip(&view->scene_tree->node, NULL);
		}
	}
	wlr_scene_node_set_position(&view->scene_tree->node, geometry.x,
		geometry.y);
	wlr_log(WLR_INFO,
		"layout view role=%s layout=%s x=%d y=%d size=%dx%d maximized=%s minimized=%s title=%s app_id=%s",
		surface_role_name(view->role), geometry.layout,
		geometry.x, geometry.y, geometry.width, geometry.height,
		view->maximized ? "true" : "false",
		view->minimized ? "true" : "false",
		view_title(view), view_app_id(view));
}

static void relayout_shell_views(struct engineos_shell_server *server,
		const char *reason) {
	(void)reason;
	struct engineos_shell_view *previous_focus = server->focused_view;
	if (is_managed_floating_view(previous_focus) &&
			previous_focus->mapped && !previous_focus->minimized) {
		focus_view(previous_focus);
	}

	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (!view->mapped) {
			continue;
		}
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		apply_view_layout(view);
		wlr_scene_node_set_enabled(&view->scene_tree->node,
			view_geometry_render_enabled(server, view, &geometry));
	}
	if (is_managed_floating_view(server->focused_view) &&
			server->focused_view->mapped && !server->focused_view->minimized) {
		wlr_scene_node_raise_to_top(&server->focused_view->scene_tree->node);
	}
	schedule_outputs(server);
}

static void set_input_mode(struct engineos_shell_server *server,
		enum engineos_input_mode mode, const char *reason) {
	if (mode == ENGINEOS_INPUT_GAME &&
			!view_is_native_mux_game(server->focused_view)) {
		server->game_capture = false;
		wlr_log(WLR_INFO,
			"input mode request ignored requested=game reason=no-focused-game");
		return;
	}
	server->input_mode = mode;
	server->game_capture = mode == ENGINEOS_INPUT_GAME;
	if (mode == ENGINEOS_INPUT_SHELL)
		clear_keyboard_focus(server);
	sync_pointer_constraint(server, reason);
	sync_cursor_image(server, reason);
	write_shell_state(server, reason);
}

static void toggle_game_capture(struct engineos_shell_server *server) {
	if (!view_is_native_mux_game(server->focused_view)) {
		server->game_capture = false;
		return;
	}
	server->input_mode = ENGINEOS_INPUT_GAME;
	server->game_capture = !server->game_capture;
	if (game_capture_active(server))
		confine_cursor_to_view(server, server->focused_view, "capture-toggle");
	sync_pointer_constraint(server, "capture-toggle");
	sync_cursor_image(server, "capture-toggle");
	write_shell_state(server, "capture-toggle");
}
static void emergency_release(struct engineos_shell_server *server) {
	server->emergency_released = true;
	server->game_capture = false;
	set_input_mode(server, ENGINEOS_INPUT_SHELL, "emergency-release");
	wlr_log(WLR_INFO, "input emergency-release complete");
}

static bool send_mux_navigation_binding(struct engineos_shell_server *server,
		const char *key_name, const char *reason) {
	if (!server->mux_client.ready) {
		wlr_log(WLR_ERROR,
			"mux navigation unavailable key=%s reason=mux-not-ready",
			key_name);
		return false;
	}
	struct engineos_shell_output *output = focused_mux_output(server);
	struct engineos_mux_pane_model *pane = focused_mux_pane(server);
	if (output == NULL || pane == NULL) {
		wlr_log(WLR_ERROR,
			"mux navigation unavailable key=%s reason=no-focused-pane",
			key_name);
		return false;
	}

	bool grid_changed = false;
	bool key_grid_changed = false;
	char error[256] = {0};
	const char *keys[] = {server->mux_client.prefix, key_name};
	for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
		key_grid_changed = false;
		if (!engineos_mux_client_send_key(&server->mux_client,
				output->mux_view_id, pane->pane_id, pane->generation,
				keys[index], &key_grid_changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR,
				"mux navigation failed key=%s step=%s rejected=%s: %s",
				key_name, keys[index],
				server->mux_client.last_request_rejected ? "true" : "false",
				error[0] != '\0' ? error : "unknown error");
			if (!server->mux_client.last_request_rejected)
				server->mux_client.ready = false;
			return false;
		}
		grid_changed = grid_changed || key_grid_changed;
	}

	bool ui_changed = false;
	if (!engineos_mux_client_request_view_ui(&server->mux_client,
			output->mux_view_id, &output->mux_snapshot, &ui_changed,
			error, sizeof(error)) ||
			!engineos_mux_client_refresh_presentation(&server->mux_client,
				error, sizeof(error)) ||
			!refresh_native_output_snapshots(server, &grid_changed, error,
				sizeof(error))) {
		wlr_log(WLR_ERROR, "mux navigation refresh failed key=%s: %s",
			key_name, error[0] != '\0' ? error : "unknown error");
		server->mux_client.ready = false;
		return false;
	}

	sync_native_presentation_visibility(server, reason);
	if ((grid_changed || ui_changed) &&
			!refresh_native_terminal_scene(server, reason)) {
		wlr_log(WLR_ERROR,
			"mux navigation terminal refresh failed key=%s", key_name);
		server->mux_client.ready = false;
		return false;
	}
	wlr_log(WLR_INFO, "mux navigation complete key=%s reason=%s",
		key_name, reason);
	return true;
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
	struct engineos_shell_view *previous_view = server->focused_view;
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
	if (previous_view != NULL && previous_view != view &&
			is_managed_floating_view(previous_view) &&
			previous_view->mapped && previous_view->scene_tree != NULL) {
		struct engineos_view_geometry previous_geometry = {0};
		compute_view_geometry(previous_view, &previous_geometry);
		bool previous_visible =
			view_geometry_render_enabled(server, previous_view,
				&previous_geometry);
		apply_view_layout(previous_view);
		wlr_scene_node_set_enabled(&previous_view->scene_tree->node,
			previous_visible);
	}
	if (is_managed_floating_view(view) && view->scene_tree != NULL) {
		apply_view_layout(view);
		wlr_scene_node_set_enabled(&view->scene_tree->node, true);
	}
	wlr_scene_node_raise_to_top(&view->scene_tree->node);
	set_view_activated(view, true);

	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(server->seat);
	if (keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(server->seat, view->xdg_surface->surface,
			keyboard->keycodes, keyboard->num_keycodes, &keyboard->modifiers);
	}

	schedule_outputs(server);
	if (game_capture_active(server)) {
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
	server->emergency_released = false;
	bool native_game = view_is_native_mux_game(view);
	server->game_capture = native_game;
	server->input_mode = native_game ? ENGINEOS_INPUT_GAME :
		(view->mux_bound ? ENGINEOS_INPUT_GRAPHICAL : ENGINEOS_INPUT_TERMINAL);
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
			wlr_log(WLR_INFO,
				"keybinding ctrl+alt+backspace: release to tmux console");
			emergency_release(server);
			struct engineos_mux_pane_model *pane = focused_mux_pane(server);
			if (pane != NULL && strcmp(pane->view_mode, "presentation") == 0)
				send_mux_navigation_binding(server, "v",
					"ctrl-alt-backspace-console");
			return true;
		}
		return false;
	case XKB_KEY_F3:
		if (modifiers == 0 &&
				(!wl_list_empty(&server->previews) ||
				 server->wallpaper.scene_buffer != NULL)) {
			wlr_log(WLR_INFO, "keybinding f3: close image surfaces");
			if (!wl_list_empty(&server->previews)) {
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
	case XKB_KEY_Escape: {
		wlr_log(WLR_INFO, "keybinding alt+escape: release to tmux console");
		emergency_release(server);
		struct engineos_mux_pane_model *pane = focused_mux_pane(server);
		if (pane != NULL && strcmp(pane->view_mode, "presentation") == 0)
			send_mux_navigation_binding(server, "v", "alt-escape-console");
		return true;
	}
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
	case XKB_KEY_Tab: {
		struct engineos_mux_pane_model *pane = focused_mux_pane(server);
		if (pane != NULL && pane->presentation_mapped) {
			bool showing_presentation =
				strcmp(pane->view_mode, "presentation") == 0;
			wlr_log(WLR_INFO, "keybinding alt+tab: toggle mapped pane %s",
				showing_presentation ? "to console" : "to presentation");
			send_mux_navigation_binding(server, "v",
				showing_presentation ? "alt-tab-console" :
					"alt-tab-presentation");
		} else {
			wlr_log(WLR_INFO,
				"keybinding alt+tab: next tmux window (no mapped app)");
			send_mux_navigation_binding(server, "n", "alt-tab-next-window");
		}
		return true;
	}
	default:
		return false;
	}
}

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_keyboard *keyboard =
		wl_container_of(listener, keyboard, modifiers);
	keyboard->server->keyboard_modifiers =
		wlr_keyboard_get_modifiers(keyboard->keyboard);
	wlr_seat_set_keyboard(keyboard->server->seat, keyboard->keyboard);
	wlr_seat_keyboard_notify_modifiers(keyboard->server->seat,
		&keyboard->keyboard->modifiers);
}

static void cancel_native_terminal_key_repeat(
		struct engineos_shell_keyboard *keyboard) {
	keyboard->terminal_repeat_keycode = 0;
	if (keyboard->terminal_repeat_timer != NULL)
		wl_event_source_timer_update(keyboard->terminal_repeat_timer, 0);
}

static bool send_native_terminal_key(struct engineos_shell_server *server,
		const char *key_name) {
	struct engineos_shell_output *output = focused_mux_output(server);
	struct engineos_mux_pane_model *pane = focused_mux_pane(server);
	if (output == NULL || pane == NULL) {
		wlr_log(WLR_ERROR,
			"native tmux key has no authoritative focused output model");
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_send_key(&server->mux_client,
			output->mux_view_id, pane->pane_id, pane->generation, key_name,
			&grid_changed, error, sizeof(error))) {
		if (server->mux_client.last_request_rejected) {
			wlr_log(WLR_ERROR,
				"native tmux key rejected key=%s: %s", key_name, error);
			return false;
		}
		wlr_log(WLR_ERROR, "native tmux key transport failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	bool ui_grid_changed = false;
	if (!engineos_mux_client_request_view_ui(&server->mux_client,
			output->mux_view_id, &output->mux_snapshot, &ui_grid_changed,
			error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native tmux UI refresh failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	if (!refresh_native_output_snapshots(server, &grid_changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native terminal output refresh failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	if (!refresh_native_terminal_scene(server,
			grid_changed || ui_grid_changed ?
			"native-input-grid-and-ui-damage" : "native-input-ui-damage")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	return true;
}

static int native_terminal_key_repeat(void *data) {
	struct engineos_shell_keyboard *keyboard = data;
	struct engineos_shell_server *server = keyboard->server;
	if (keyboard->terminal_repeat_keycode == 0 ||
			!server->mux_client.ready ||
			server->input_mode != ENGINEOS_INPUT_TERMINAL) {
		cancel_native_terminal_key_repeat(keyboard);
		return 0;
	}

	char key_name[64];
	if (engineos_tmux_key_name(keyboard->terminal_repeat_sym,
			keyboard->terminal_repeat_modifiers, key_name) == 0 ||
			!send_native_terminal_key(server, key_name)) {
		cancel_native_terminal_key_repeat(keyboard);
		return 0;
	}

	int interval = engineos_tmux_key_repeat_interval_ms(
		keyboard->keyboard->repeat_info.rate);
	if (interval <= 0) {
		cancel_native_terminal_key_repeat(keyboard);
		return 0;
	}
	wl_event_source_timer_update(keyboard->terminal_repeat_timer, interval);
	return 0;
}

static void start_native_terminal_key_repeat(
		struct engineos_shell_keyboard *keyboard, xkb_keysym_t sym,
		uint32_t keycode, uint32_t modifiers) {
	if (keyboard->terminal_repeat_timer == NULL ||
			!engineos_tmux_key_repeats(keyboard->keyboard, keycode)) return;
	keyboard->terminal_repeat_keycode = keycode;
	keyboard->terminal_repeat_sym = sym;
	keyboard->terminal_repeat_modifiers = modifiers;
	int delay = keyboard->keyboard->repeat_info.delay;
	if (delay <= 0)
		delay = engineos_tmux_key_repeat_interval_ms(
			keyboard->keyboard->repeat_info.rate);
	wl_event_source_timer_update(keyboard->terminal_repeat_timer, delay);
}

static bool route_native_terminal_key(struct engineos_shell_keyboard *keyboard,
		struct wlr_keyboard_key_event *event, xkb_keysym_t sym,
		uint32_t keycode, uint32_t modifiers) {
	struct engineos_shell_server *server = keyboard->server;
	if (!server->mux_client.ready ||
			server->input_mode != ENGINEOS_INPUT_TERMINAL) return false;
	if (event->state == WL_KEYBOARD_KEY_STATE_RELEASED) {
		if (keyboard->terminal_repeat_keycode == keycode)
			cancel_native_terminal_key_repeat(keyboard);
		return true;
	}
	if (event->state != WL_KEYBOARD_KEY_STATE_PRESSED) return true;
	char key_name[64];
	if (engineos_tmux_key_name(sym, modifiers, key_name) == 0) return true;
	if (!send_native_terminal_key(server, key_name)) return true;
	start_native_terminal_key_repeat(keyboard, sym, keycode, modifiers);
	return true;
}

static bool route_native_graphical_prefix_key(
		struct engineos_shell_server *server, struct wlr_keyboard *keyboard,
		struct wlr_keyboard_key_event *event, xkb_keysym_t sym,
		uint32_t keycode, uint32_t modifiers) {
	(void)keyboard;
	(void)keycode;
	if (!server->mux_client.ready ||
			(server->input_mode != ENGINEOS_INPUT_GRAPHICAL &&
			 server->input_mode != ENGINEOS_INPUT_GAME))
		return false;
	if (server->mux_consumed_keycode == event->keycode) {
		if (event->state == WL_KEYBOARD_KEY_STATE_RELEASED)
			server->mux_consumed_keycode = 0;
		return true;
	}
	if (event->state != WL_KEYBOARD_KEY_STATE_PRESSED)
		return false;
	char key_name[64];
	if (engineos_tmux_key_name(sym, modifiers, key_name) == 0)
		return false;
	bool prefix = strcmp(key_name, server->mux_client.prefix) == 0 ||
		(strcmp(server->mux_client.prefix2, "None") != 0 &&
		 strcmp(key_name, server->mux_client.prefix2) == 0);
	if (!server->mux_prefix_pending && !prefix)
		return false;
	struct engineos_shell_output *output = focused_mux_output(server);
	struct engineos_mux_pane_model *pane = focused_mux_pane(server);
	if (output == NULL || pane == NULL) {
		wlr_log(WLR_ERROR,
			"native graphical prefix has no authoritative focused output model");
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	bool was_pending = server->mux_prefix_pending;
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_send_key(&server->mux_client,
			output->mux_view_id, pane->pane_id, pane->generation, key_name,
			&grid_changed,
			error, sizeof(error))) {
		if (server->mux_client.last_request_rejected) {
			wlr_log(WLR_ERROR,
				"native graphical prefix key rejected key=%s: %s",
				key_name, error);
			server->mux_prefix_pending = false;
			server->mux_consumed_keycode = event->keycode;
			return true;
		}
		wlr_log(WLR_ERROR,
			"native graphical prefix key transport failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	server->mux_prefix_pending = !was_pending;
	server->mux_consumed_keycode = event->keycode;
	bool ui_changed = false;
	if (!engineos_mux_client_request_view_ui(&server->mux_client,
			output->mux_view_id, &output->mux_snapshot, &ui_changed,
			error, sizeof(error)) ||
			!engineos_mux_client_refresh_presentation(&server->mux_client,
				error, sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native graphical prefix state refresh failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	if (!refresh_native_output_snapshots(server, &grid_changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native graphical prefix output refresh failed key=%s: %s",
			key_name, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	sync_native_presentation_visibility(server,
		was_pending ? "native-graphical-prefix-command" :
			"native-graphical-prefix");
	if ((grid_changed || ui_changed) &&
			!refresh_native_terminal_scene(server,
				"native-graphical-prefix-state")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	return true;
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
	server->keyboard_modifiers = modifiers;
	bool handled = false;

	if (event->state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		for (int i = 0; i < nsyms; i++) {
			handled = handle_keybinding(server, syms[i], modifiers) || handled;
		}
	}
	if (!handled && nsyms > 0) {
		handled = route_native_graphical_prefix_key(server,
			keyboard->keyboard, event, syms[0], keycode, modifiers);
	}
	if (!handled && nsyms > 0) {
		handled = route_native_terminal_key(keyboard, event, syms[0], keycode,
			modifiers);
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
	if (keyboard->terminal_repeat_timer != NULL)
		wl_event_source_remove(keyboard->terminal_repeat_timer);
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
	struct wl_event_loop *event_loop = wl_display_get_event_loop(server->display);
	keyboard->terminal_repeat_timer = wl_event_loop_add_timer(event_loop,
		native_terminal_key_repeat, keyboard);
	if (keyboard->terminal_repeat_timer == NULL) {
		wlr_log(WLR_ERROR, "failed to create native terminal key repeat timer");
		free(keyboard);
		return;
	}

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
	server->cursor_client_owned = false;
}

static void set_default_cursor(struct engineos_shell_server *server,
		const char *reason) {
	if (active_pointer_constraint_is_locked(server)) {
		hide_cursor(server, reason);
		return;
	}
	if (server->cursor_mgr == NULL) {
		return;
	}
	bool custom_cursor = server->cursor_hidden || server->cursor_client_owned;
	wlr_cursor_set_xcursor(server->cursor, server->cursor_mgr, "default");
	if (custom_cursor) {
		wlr_log(WLR_INFO, "cursor image=restored reason=%s",
			reason != NULL ? reason : "unspecified");
	}
	server->cursor_hidden = false;
	server->cursor_client_owned = false;
}

static void sync_cursor_image(struct engineos_shell_server *server,
		const char *reason) {
	if (active_pointer_constraint_is_locked(server)) {
		hide_cursor(server, reason);
		return;
	}
	set_default_cursor(server, reason);
}

static void cursor_log_event(struct engineos_shell_server *server,
		const char *event_name, struct wlr_pointer *pointer) {
	wlr_log(WLR_DEBUG, "pointer %s mode=%s capture=%s focus=%s x=%.1f y=%.1f device=%s",
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
	wlr_log(WLR_DEBUG, "pointer focus role=%s sx=%.1f sy=%.1f reason=%s",
		view != NULL ? surface_role_name(view->role) : "unknown",
		sx, sy, reason != NULL ? reason : "unspecified");
	return true;
}

static void send_game_relative_motion(struct engineos_shell_server *server,
		uint32_t time_msec, double dx, double dy,
		double dx_unaccel, double dy_unaccel, const char *reason) {
	if (!active_pointer_constraint_is_locked(server) ||
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

static const char *native_mux_button_name(uint32_t button) {
	switch (button) {
	case 0: return "none";
	case BTN_LEFT: return "left";
	case BTN_MIDDLE: return "middle";
	case BTN_RIGHT: return "right";
	default: return NULL;
	}
}

static uint32_t native_mux_mouse_modifiers(
		const struct engineos_shell_server *server) {
	uint32_t result = 0;
	if (server->keyboard_modifiers & WLR_MODIFIER_SHIFT) result |= 1;
	if (server->keyboard_modifiers & WLR_MODIFIER_ALT) result |= 2;
	if (server->keyboard_modifiers & WLR_MODIFIER_CTRL) result |= 4;
	return result;
}

static bool native_mux_pointer_cell(struct engineos_shell_server *server,
		uint32_t *view_id, uint32_t *cell_x, uint32_t *cell_y) {
	if (!server->mux_client.ready) return false;
	struct wlr_output *target = wlr_output_layout_output_at(
		server->output_layout, server->cursor->x, server->cursor->y);
	if (target == NULL) return false;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (output->output != target || !output->mux_registered) continue;
		struct wlr_output_layout_output *layout_output =
			wlr_output_layout_get(server->output_layout, target);
		if (layout_output == NULL) return false;
		const struct engineos_mux_ui_model *ui = &output->mux_snapshot.ui;
		uint32_t columns = ui->columns;
		uint32_t rows = ui->rows;
		int pixel_width = output->mux_ui_stats.width;
		int pixel_height = output->mux_ui_stats.height;
		if (!ui->ready || ui->invalidated || columns == 0 || rows == 0 ||
				pixel_width <= 0 || pixel_height <= 0) return false;
		double local_x = server->cursor->x - layout_output->x;
		double local_y = server->cursor->y - layout_output->y;
		if (local_x < 0 || local_y < 0 ||
				local_x >= pixel_width || local_y >= pixel_height) return false;
		uint32_t x = (uint32_t)(local_x * columns /
			(double)pixel_width);
		uint32_t y = (uint32_t)(local_y * rows /
			(double)pixel_height);
		if (x >= columns || y >= rows) return false;
		*view_id = output->mux_view_id;
		*cell_x = x;
		*cell_y = y;
		return true;
	}
	return false;
}

static enum engineos_pointer_target classify_pointer_target(
		struct engineos_shell_server *server, uint32_t *view_id,
		uint32_t *cell_x, uint32_t *cell_y) {
	if (game_capture_active(server))
		return ENGINEOS_POINTER_WAYLAND_SURFACE;

	if (!native_mux_pointer_cell(server, view_id, cell_x, cell_y))
		return ENGINEOS_POINTER_NONE;

	struct engineos_shell_output *output = NULL;
	struct engineos_shell_output *candidate;
	wl_list_for_each(candidate, &server->outputs, link) {
		if (candidate->mux_registered &&
				candidate->mux_view_id == *view_id) {
			output = candidate;
			break;
		}
	}
	if (output == NULL || !output->mux_snapshot.ready)
		return ENGINEOS_POINTER_NONE;

	const struct engineos_mux_ui_model *ui = &output->mux_snapshot.ui;
	if (ui->ready && !ui->invalidated) {
		if (ui->menu_active && *cell_x >= ui->menu_x &&
				*cell_x < ui->menu_x + ui->menu_width &&
				*cell_y >= ui->menu_y &&
				*cell_y < ui->menu_y + ui->menu_height)
			return ENGINEOS_POINTER_TMUX_UI;
		if (ui->status_y >= 0 &&
				*cell_y >= (uint32_t)ui->status_y &&
				*cell_y < (uint32_t)ui->status_y +
					ui->status_row_count)
			return ENGINEOS_POINTER_TMUX_UI;
	}

	for (size_t index = 0; index < output->mux_snapshot.pane_count;
			index++) {
		const struct engineos_mux_pane_model *pane =
			&output->mux_snapshot.panes[index];
		if (!pane->visible || !pane->window_active ||
				*cell_x < pane->left ||
				*cell_x >= pane->left + pane->columns ||
				*cell_y < pane->top ||
				*cell_y >= pane->top + pane->rows)
			continue;
		if (pane_presentation_owned_by_output(server, pane, output))
			return ENGINEOS_POINTER_WAYLAND_SURFACE;
		return ENGINEOS_POINTER_TMUX_PANE;
	}

	/* Cells outside pane content are tmux-owned borders and separators. */
	return ENGINEOS_POINTER_TMUX_PANE;
}

static bool pointer_target_is_tmux(enum engineos_pointer_target target) {
	return target == ENGINEOS_POINTER_TMUX_UI ||
		target == ENGINEOS_POINTER_TMUX_PANE;
}

static bool route_native_terminal_mouse_at(struct engineos_shell_server *server,
		uint32_t view_id, uint32_t x, uint32_t y, const char *event,
		const char *button, bool coalesce_motion) {
	if (coalesce_motion && server->mux_pointer_cell_valid &&
			server->mux_pointer_view_id == view_id &&
			server->mux_pointer_x == x && server->mux_pointer_y == y)
		return true;
	struct engineos_shell_output *output = NULL;
	struct engineos_shell_output *candidate;
	wl_list_for_each(candidate, &server->outputs, link) {
		if (candidate->mux_registered && candidate->mux_snapshot.ready &&
				candidate->mux_view_id == view_id) {
			output = candidate;
			break;
		}
	}
	if (output == NULL) {
		wlr_log(WLR_ERROR,
			"native tmux mouse has no authoritative output view=%u", view_id);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_send_mouse(&server->mux_client, view_id, x, y,
			event, button, native_mux_mouse_modifiers(server),
			&grid_changed, error, sizeof(error))) {
		if (server->mux_client.last_request_rejected) {
			wlr_log(WLR_DEBUG,
				"native tmux mouse rejected event=%s button=%s "
				"cell=%u,%u: %s",
				event, button, x, y, error);
			server->mux_pointer_cell_valid = false;
			return true;
		}
		wlr_log(WLR_ERROR,
			"native tmux mouse transport failed event=%s button=%s "
			"cell=%u,%u: %s",
			event, button, x, y, error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return true;
	}
	server->mux_pointer_view_id = view_id;
	server->mux_pointer_x = x;
	server->mux_pointer_y = y;
	server->mux_pointer_cell_valid = true;
	bool ui_invalidated = false;
	struct engineos_shell_output *ui_output;
	wl_list_for_each(ui_output, &server->outputs, link) {
		if (ui_output->mux_registered &&
				ui_output->mux_snapshot.ui.invalidated) {
			ui_invalidated = true;
			break;
		}
	}
	if (!grid_changed && !ui_invalidated &&
			!server->mux_client.state_invalidated_pending)
		return true;
	if (!refresh_native_terminal_scene(server,
			grid_changed ? "native-mouse-grid-damage" :
			"native-mouse-state-or-ui-damage")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	return true;
}

static bool route_native_terminal_mouse(struct engineos_shell_server *server,
		const char *event, const char *button, bool coalesce_motion) {
	uint32_t view_id, x, y;
	if (!native_mux_pointer_cell(server, &view_id, &x, &y)) return false;
	return route_native_terminal_mouse_at(server, view_id, x, y, event,
		button, coalesce_motion);
}

static void cursor_handle_motion(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;

	if (!active_pointer_constraint_is_locked(server)) {
		wlr_cursor_move(server->cursor, &event->pointer->base,
			event->delta_x, event->delta_y);
	}
	update_drag_icon_position(server, "pointer-motion");
	if (server->moving_view != NULL) {
		update_interactive_move(server, "pointer-motion");
		return;
	}
	cursor_log_event(server, "motion", event->pointer);
	const char *button = native_mux_button_name(server->mux_pointer_button);
	uint32_t view_id = 0, cell_x = 0, cell_y = 0;
	enum engineos_pointer_target target = game_capture_active(server) ?
		ENGINEOS_POINTER_WAYLAND_SURFACE :
		(server->pointer_grab_active ? server->pointer_grab_target :
		 classify_pointer_target(server, &view_id, &cell_x, &cell_y));
	if (pointer_target_is_tmux(target)) {
		if (view_id == 0 &&
				!native_mux_pointer_cell(server, &view_id, &cell_x, &cell_y))
			return;
		clear_pointer_focus(server, "tmux-pointer-motion");
		if (button != NULL &&
				(server->mux_pointer_button != 0 ||
				 view_id == server->mux_client.primary_view_id))
			route_native_terminal_mouse_at(server, view_id, cell_x, cell_y,
				"motion", button, server->mux_pointer_button == 0);
		return;
	}
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

	if (!active_pointer_constraint_is_locked(server)) {
		wlr_cursor_warp_absolute(server->cursor, &event->pointer->base,
			event->x, event->y);
	}
	update_drag_icon_position(server, "pointer-motion-absolute");
	if (server->moving_view != NULL) {
		update_interactive_move(server, "pointer-motion-absolute");
		return;
	}
	cursor_log_event(server, "motion-absolute", event->pointer);
	const char *button = native_mux_button_name(server->mux_pointer_button);
	uint32_t view_id = 0, cell_x = 0, cell_y = 0;
	enum engineos_pointer_target target = game_capture_active(server) ?
		ENGINEOS_POINTER_WAYLAND_SURFACE :
		(server->pointer_grab_active ? server->pointer_grab_target :
		 classify_pointer_target(server, &view_id, &cell_x, &cell_y));
	if (pointer_target_is_tmux(target)) {
		if (view_id == 0 &&
				!native_mux_pointer_cell(server, &view_id, &cell_x, &cell_y))
			return;
		clear_pointer_focus(server, "tmux-pointer-motion-absolute");
		if (button != NULL &&
				(server->mux_pointer_button != 0 ||
				 view_id == server->mux_client.primary_view_id))
			route_native_terminal_mouse_at(server, view_id, cell_x, cell_y,
				"motion", button, server->mux_pointer_button == 0);
		return;
	}
	if (cursor_update_pointer_focus(server, event->time_msec,
			"motion-absolute")) {
		sync_pointer_constraint(server, "motion-absolute");
	}
}

static bool focus_native_mux_output(struct engineos_shell_server *server,
		struct engineos_shell_output *output, const char *reason) {
	if (!output->mux_registered || !server->mux_client.ready) return false;
	if (server->mux_client.primary_view_id == output->mux_view_id) return true;
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_focus_view(&server->mux_client,
			output->mux_view_id, &grid_changed, error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native mux output focus failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	if (!refresh_native_output_snapshots(server, &grid_changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR, "native mux focused output model refresh failed: %s",
			error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	bool ui_grid_changed = false;
	if (!engineos_mux_client_request_view_ui(&server->mux_client,
			output->mux_view_id, &output->mux_snapshot, &ui_grid_changed,
			error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native mux output UI refresh failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	if (!refresh_native_terminal_scene(server,
			grid_changed || ui_grid_changed ?
			"native-output-focus-grid-and-ui" : "native-output-focus-ui")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
		return false;
	}
	sync_native_presentation_visibility(server,
		reason != NULL ? reason : "native-output-focused");
	server->mux_pointer_cell_valid = false;
	server->mux_pointer_view_id = 0;
	wlr_log(WLR_INFO, "native mux output focused view=%u output=%s reason=%s",
		output->mux_view_id,
		output->output->name[0] != '\0' ? output->output->name : "unnamed",
		reason != NULL ? reason : "unspecified");
	write_shell_state(server, reason != NULL ? reason : "native-output-focused");
	return true;
}

static void focus_native_mux_output_at_cursor(
		struct engineos_shell_server *server) {
	if (!server->mux_client.ready) return;
	struct wlr_output *target = wlr_output_layout_output_at(
		server->output_layout, server->cursor->x, server->cursor->y);
	if (target == NULL) return;
	struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (output->output != target) continue;
		focus_native_mux_output(server, output, "native-output-pointer-focus");
		return;
	}
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
		uint32_t view_id = 0, cell_x = 0, cell_y = 0;
		enum engineos_pointer_target target = classify_pointer_target(server,
			&view_id, &cell_x, &cell_y);
		server->pointer_grab_target = target;
		server->pointer_grab_active = true;
		const char *button = native_mux_button_name(event->button);
		if (button != NULL && pointer_target_is_tmux(target)) {
			focus_native_mux_output_at_cursor(server);
			clear_pointer_focus(server, "tmux-pointer-press");
			route_native_terminal_mouse_at(server, view_id, cell_x, cell_y,
				"press", button, false);
			server->mux_pointer_button = event->button;
			return;
		}
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
	if (event->state == WL_POINTER_BUTTON_STATE_RELEASED &&
			server->mux_pointer_button != 0) {
		const char *button =
			native_mux_button_name(server->mux_pointer_button);
		bool routed = button != NULL &&
			route_native_terminal_mouse(server, "release", button, false);
		if (!routed && button != NULL && server->mux_pointer_cell_valid &&
				server->mux_client.ready &&
				server->mux_pointer_view_id != 0) {
			routed = route_native_terminal_mouse_at(server,
				server->mux_pointer_view_id, server->mux_pointer_x,
				server->mux_pointer_y, "release", button, false);
		}
		server->mux_pointer_button = 0;
		server->mux_pointer_view_id = 0;
		server->pointer_grab_active = false;
		server->pointer_grab_target = ENGINEOS_POINTER_NONE;
		if (routed) return;
	}

	if (cursor_update_pointer_focus(server, event->time_msec, "button")) {
		wlr_seat_pointer_notify_button(server->seat, event->time_msec,
			event->button, event->state);
	}
	if (event->state == WL_POINTER_BUTTON_STATE_RELEASED) {
		server->pointer_grab_active = false;
		server->pointer_grab_target = ENGINEOS_POINTER_NONE;
	}
}

static void cursor_handle_axis(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;

	cursor_log_event(server, "axis", event->pointer);
	const char *button = NULL;
	if (event->orientation == WL_POINTER_AXIS_VERTICAL_SCROLL) {
		if (event->delta < 0 || event->delta_discrete < 0)
			button = "wheel-up";
		else if (event->delta > 0 || event->delta_discrete > 0)
			button = "wheel-down";
	}
	uint32_t view_id = 0, cell_x = 0, cell_y = 0;
	enum engineos_pointer_target target = classify_pointer_target(server,
		&view_id, &cell_x, &cell_y);
	if (button != NULL && pointer_target_is_tmux(target)) {
		clear_pointer_focus(server, "tmux-pointer-wheel");
		route_native_terminal_mouse_at(server, view_id, cell_x, cell_y,
			"wheel", button, false);
		return;
	}
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

	if (active_pointer_constraint_is_locked(server)) {
		hide_cursor(server, "client-cursor-request-game-capture");
		wlr_log(WLR_INFO,
			"cursor image request ignored reason=game-capture");
		return;
	}

	if (focused_client == event->seat_client) {
		wlr_cursor_set_surface(server->cursor, event->surface,
			event->hotspot_x, event->hotspot_y);
		server->cursor_hidden = event->surface == NULL;
		server->cursor_client_owned = true;
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

static bool init_test_pointer(struct engineos_shell_server *server) {
	const char *enabled = getenv("ENGINEOS_TEST_POINTER");
	if (enabled == NULL || strcmp(enabled, "1") != 0) {
		return true;
	}
	if (strcmp(server->mode_name, "headless") != 0) {
		wlr_log(WLR_ERROR,
			"test pointer requires explicit headless shell mode");
		return false;
	}

	static const struct wlr_pointer_impl test_pointer_impl = {
		.name = "engineos-test-pointer",
	};
	wlr_pointer_init(&server->test_pointer, &test_pointer_impl,
		"engineos-test-pointer");
	server->test_pointer_initialized = true;
	server_new_pointer(server, &server->test_pointer.base);
	wlr_log(WLR_INFO, "headless test pointer enabled");
	return true;
}

static bool native_mux_outputs_committed(
		const struct engineos_shell_server *server) {
	const struct engineos_shell_output *output;
	wl_list_for_each(output, &server->outputs, link) {
		if (!output->mux_registered || output->scheduled_renderer_frame == 0)
			continue;
		if (output->committed_mux_revision !=
				output->scheduled_mux_revision ||
				output->committed_grid_revision !=
				output->scheduled_grid_revision ||
				output->committed_renderer_frame !=
				output->scheduled_renderer_frame)
			return false;
	}
	return true;
}

static void output_frame(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_output *output =
		wl_container_of(listener, output, frame);

	if (!wlr_scene_output_commit(output->scene_output, NULL)) {
		bool first_failure = output->frame_failures == 0;
		output->frame_failures++;
		wlr_log(WLR_ERROR, "failed to commit scene output name=%s",
			output->output->name[0] != '\0' ? output->output->name : "(unnamed)");
		if (first_failure)
			write_shell_state(output->server, "output-frame-failed");
		return;
	}
	bool first_commit = output->frame_commits == 0;
	output->frame_commits++;
	bool mux_commit_changed = false;
	if (output->mux_registered && output->scheduled_renderer_frame != 0 &&
			(output->committed_mux_revision !=
				output->scheduled_mux_revision ||
			 output->committed_grid_revision !=
				output->scheduled_grid_revision ||
			 output->committed_renderer_frame !=
				output->scheduled_renderer_frame)) {
		output->committed_mux_revision = output->scheduled_mux_revision;
		output->committed_grid_revision = output->scheduled_grid_revision;
		output->committed_renderer_frame = output->scheduled_renderer_frame;
		mux_commit_changed = true;
	}
	if (first_commit)
		write_shell_state(output->server, "output-first-frame");
	else if (mux_commit_changed &&
			native_mux_outputs_committed(output->server))
		write_shell_state(output->server, "output-mux-frame-committed");

	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(output->scene_output, &now);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_output *output =
		wl_container_of(listener, output, destroy);
	struct engineos_shell_server *server = output->server;
	if (output->mux_registered && server->mux_client.ready) {
		bool was_focused = server->mux_client.primary_view_id ==
			output->mux_view_id;
		bool grid_changed = false;
		char error[256] = {0};
		if (!engineos_mux_client_unregister_view(&server->mux_client,
				output->mux_view_id, &grid_changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR, "native mux output unregister failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
		} else {
			output->mux_registered = false;
		}
		if (server->mux_client.ready && !was_focused &&
				server->mux_client.primary_view_id != 0) {
			struct engineos_shell_output *focused = focused_mux_output(server);
			bool ui_grid_changed = false;
			if (focused == NULL ||
					!engineos_mux_client_request_view_ui(&server->mux_client,
					focused->mux_view_id, &focused->mux_snapshot, &ui_grid_changed,
					error, sizeof(error)) ||
					!refresh_native_terminal_scene(server,
						grid_changed || ui_grid_changed ?
						"native-output-unregister-grid-and-ui" :
						"native-output-unregister-ui")) {
				wlr_log(WLR_ERROR,
					"native mux output unregister UI refresh failed: %s",
					error[0] != '\0' ? error : "render failed");
				server->mux_client.ready = false;
				wl_display_terminate(server->display);
			}
		}
		if (was_focused && server->mux_client.ready) {
			struct engineos_shell_output *candidate;
			wl_list_for_each(candidate, &server->outputs, link) {
				if (candidate == output || !candidate->mux_registered) continue;
				focus_native_mux_output(server, candidate,
					"native-output-destroy-focus-transfer");
				break;
			}
		}
	}

	wlr_log(WLR_INFO, "output destroyed name=%s",
		output->output->name[0] != '\0' ? output->output->name : "(unnamed)");
	wl_list_remove(&output->link);
	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->destroy.link);
	destroy_mux_output_scene(output);
	engineos_mux_client_release_view_snapshot(&server->mux_client,
		&output->mux_snapshot);
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
	destroy_mux_output_scene(output);
	engineos_mux_client_release_view_snapshot(&output->server->mux_client,
		&output->mux_snapshot);
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
	if (server->test_pointer_initialized) {
		wlr_output_state_set_custom_mode(&state, 1920, 1080, 0);
	} else if (!wl_list_empty(&output->modes)) {
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
	if (server->mux_client.ready) {
		int cell_width = 0;
		int cell_height = 0;
		char error[256] = {0};
		if (!engineos_terminal_cell_metrics(&cell_width, &cell_height, error,
				sizeof(error))) {
			wlr_log(WLR_ERROR, "native mux terminal metrics failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		uint32_t columns = (uint32_t)(width / cell_width);
		uint32_t rows = (uint32_t)(height / cell_height);
		if (columns == 0 || rows == 0) {
			wlr_log(WLR_ERROR,
				"native mux output is smaller than one terminal cell size=%dx%d cell=%dx%d",
				width, height, cell_width, cell_height);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		shell_output->mux_view_id = ++server->next_mux_view_id;
		bool focused = server->mux_client.primary_view_id == 0;
		bool grid_changed = false;
		uint32_t scale_milli = (uint32_t)(output->scale * 1000.0 + 0.5);
		const char *output_name = output->name[0] != '\0' ?
			output->name : "unnamed";
		if (!engineos_mux_client_register_view(&server->mux_client,
				shell_output->mux_view_id, output_name,
				columns, rows, (uint32_t)width, (uint32_t)height, scale_milli, focused,
				&grid_changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR, "native mux output registration failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		shell_output->mux_registered = true;
		bool snapshot_grid_changed = false;
		if (!engineos_mux_client_request_view_snapshot(&server->mux_client,
				shell_output->mux_view_id, &shell_output->mux_snapshot,
				&snapshot_grid_changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR, "native mux output snapshot failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		if (strcmp(shell_output->mux_snapshot.output, output_name) != 0) {
			wlr_log(WLR_ERROR,
				"native mux output snapshot identity mismatch view=%u",
				shell_output->mux_view_id);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		bool view_ui_grid_changed = false;
		if (!engineos_mux_client_request_view_ui(&server->mux_client,
				shell_output->mux_view_id, &shell_output->mux_snapshot,
				&view_ui_grid_changed, error, sizeof(error))) {
			wlr_log(WLR_ERROR,
				"native mux output UI model failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		grid_changed = grid_changed || snapshot_grid_changed;
		grid_changed = grid_changed || view_ui_grid_changed;
		if (!create_mux_output_scene(shell_output, error, sizeof(error))) {
			wlr_log(WLR_ERROR, "native mux output scene failed: %s", error);
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
		wlr_log(WLR_INFO,
			"native mux view registered view=%u output=%s session=%s grid=%ux%u focused=%s",
			shell_output->mux_view_id, output_name,
			shell_output->mux_snapshot.session_id,
			shell_output->mux_snapshot.ui.columns,
			shell_output->mux_snapshot.ui.rows,
			focused ? "true" : "false");
		if (server->mux_client.primary_view_id != 0 &&
				!refresh_native_terminal_scene(server,
				grid_changed ? "native-output-register-grid-and-ui" :
				"native-output-register-ui")) {
			server->mux_client.ready = false;
			wl_display_terminate(server->display);
			return;
		}
	}
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

static bool view_client_credentials(struct engineos_shell_view *view,
		pid_t *pid) {
	if (view == NULL || view->xdg_surface == NULL ||
			view->xdg_surface->surface == NULL ||
			view->xdg_surface->surface->resource == NULL || pid == NULL) {
		return false;
	}
	struct wl_client *client =
		wl_resource_get_client(view->xdg_surface->surface->resource);
	if (client == NULL)
		return false;
	uid_t uid = 0;
	gid_t gid = 0;
	wl_client_get_credentials(client, pid, &uid, &gid);
	return *pid > 0 && uid == getuid();
}

static bool xdg_surface_client_credentials(struct wlr_xdg_surface *surface,
		pid_t *pid) {
	if (surface == NULL || surface->surface == NULL ||
			surface->surface->resource == NULL || pid == NULL)
		return false;
	struct wl_client *client = wl_resource_get_client(surface->surface->resource);
	if (client == NULL)
		return false;
	uid_t uid = 0;
	gid_t gid = 0;
	wl_client_get_credentials(client, pid, &uid, &gid);
	return *pid > 0 && uid == getuid();
}

static struct engineos_shell_view *native_owner_view_for_xdg(
		struct engineos_shell_server *server, struct wlr_xdg_surface *surface) {
	if (surface == NULL)
		return NULL;
	struct engineos_shell_view *view;
	wl_list_for_each(view, &server->views, link) {
		if (view->xdg_surface == surface)
			return view;
	}
	if (surface->role == WLR_XDG_SURFACE_ROLE_TOPLEVEL &&
			surface->toplevel != NULL && surface->toplevel->parent != NULL)
		return native_owner_view_for_xdg(server,
			surface->toplevel->parent->base);
	if (surface->role == WLR_XDG_SURFACE_ROLE_POPUP &&
			surface->popup != NULL && surface->popup->parent != NULL)
		return native_owner_view_for_xdg(server,
			wlr_xdg_surface_try_from_wlr_surface(surface->popup->parent));
	return NULL;
}

static struct engineos_shell_view *native_presentation_other_view(
		struct engineos_shell_view *view) {
	struct engineos_shell_view *candidate;
	wl_list_for_each(candidate, &view->server->views, link) {
		if (candidate != view && candidate->mapped && candidate->mux_bound &&
				!candidate->mux_transient &&
				candidate->mux_presentation_visible &&
				candidate->mux_pane_id == view->mux_pane_id)
			return candidate;
	}
	return NULL;
}

static struct engineos_shell_view *native_presentation_any_tab(
		struct engineos_shell_view *view) {
	struct engineos_shell_view *candidate;
	wl_list_for_each(candidate, &view->server->views, link) {
		if (candidate != view && candidate->mapped && candidate->mux_bound &&
				!candidate->mux_transient &&
				candidate->mux_pane_id == view->mux_pane_id)
			return candidate;
	}
	return NULL;
}

static struct engineos_shell_view *native_presentation_root(
		struct engineos_shell_view *view) {
	while (view != NULL && view->mux_transient && view->mux_parent != NULL)
		view = view->mux_parent;
	return view;
}

static void native_presentation_set_tab_visible(
		struct engineos_shell_server *server,
		struct engineos_shell_view *root, bool visible) {
	struct engineos_mux_pane_model *pane = root != NULL ?
		find_shell_pane_model(server, root->mux_pane_id,
			root->mux_pane_generation) : NULL;
	struct engineos_mux_pane_scene *pane_scene = pane != NULL ?
		find_mux_pane_scene(server, pane->pane_id, pane->generation) : NULL;
	struct engineos_mux_pane_output_scene *lease_scene = pane_scene != NULL &&
		pane->lease_client_id == server->mux_client.frontend_client_id ?
		find_mux_pane_output_scene(pane_scene, pane->lease_view_id) : NULL;
	bool presentation_visible = pane != NULL && lease_scene != NULL &&
		pane_presentation_owned_by_output(server, pane, lease_scene->output);
	struct engineos_shell_view *candidate;
	wl_list_for_each(candidate, &server->views, link) {
		if (!candidate->mapped || !candidate->mux_bound ||
				native_presentation_root(candidate) != root)
			continue;
		candidate->mux_presentation_visible = visible;
		wlr_scene_node_set_enabled(&candidate->scene_tree->node,
			visible && presentation_visible);
	}
}

static bool native_presentation_map(struct engineos_shell_view *view) {
	struct engineos_shell_server *server = view->server;
	pid_t pid = 0;
	char error[256] = {0};
	bool grid_changed = false;
	struct engineos_mux_presentation_target target = {0};
	struct engineos_shell_view *parent = NULL;
	struct engineos_shell_output *target_output = NULL;
	const char *surface_role = "toplevel";

	if (!view_client_credentials(view, &pid) || pid > INT32_MAX) {
		snprintf(error, sizeof(error), "Wayland client credentials are invalid");
		goto reject;
	}
	if (!engineos_mux_client_resolve_presentation(&server->mux_client,
			(int32_t)pid, &target, &grid_changed, error, sizeof(error)))
		goto reject;
	if (view->xdg_surface->toplevel != NULL &&
			view->xdg_surface->toplevel->parent != NULL) {
		parent = native_owner_view_for_xdg(server,
			view->xdg_surface->toplevel->parent->base);
		if (parent == NULL || !parent->mux_bound ||
				parent->mux_pane_id != target.pane_id ||
				parent->mux_pane_generation != target.generation) {
			snprintf(error, sizeof(error),
				"transient parent is not bound to the resolved pane");
			goto reject;
		}
		surface_role = "transient";
	}
	struct engineos_mux_pane_scene *pane_scene = find_mux_pane_scene(server,
		target.pane_id, target.generation);
	struct engineos_mux_pane_model *target_pane = find_shell_pane_model(server,
		target.pane_id, target.generation);
	target_output = output_for_pane_model(server, target_pane);
	if (pane_scene == NULL) {
		snprintf(error, sizeof(error),
			"pane %%%u generation %u has no native scene",
			target.pane_id, target.generation);
		goto reject;
	}
	if (target_output == NULL || !target_output->mux_registered) {
		snprintf(error, sizeof(error),
			"pane %%%u generation %u has no owning graphical output model",
			target.pane_id, target.generation);
		goto reject;
	}
	if (!engineos_mux_client_map_presentation(&server->mux_client, &target,
			(int32_t)pid, view->view_id, target_output->mux_view_id,
			surface_role, &grid_changed,
			error, sizeof(error)))
		goto reject;
	if (!engineos_mux_client_refresh_presentation(&server->mux_client,
			error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native presentation map state refresh failed: %s",
			error);
		bool ignored = false;
		char unmap_error[256] = {0};
		engineos_mux_client_unmap_presentation(&server->mux_client,
			target.pane_id, target.generation, (int32_t)pid, view->view_id,
			&ignored, unmap_error, sizeof(unmap_error));
		goto reject;
	}
	if (!refresh_native_output_snapshots(server, &grid_changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR, "native presentation map output refresh failed: %s",
			error);
		bool ignored = false;
		char unmap_error[256] = {0};
		engineos_mux_client_unmap_presentation(&server->mux_client,
			target.pane_id, target.generation, (int32_t)pid, view->view_id,
			&ignored, unmap_error, sizeof(unmap_error));
		goto reject;
	}

	view->mux_bound = true;
	view->mux_client_pid = pid;
	view->mux_pane_id = target.pane_id;
	view->mux_pane_generation = target.generation;
	view->mux_transient = parent != NULL;
	view->mux_parent = parent;
	struct engineos_mux_pane_model *pane = find_shell_pane_model(server,
		target.pane_id, target.generation);
	struct engineos_mux_pane_output_scene *lease_scene = pane != NULL &&
		pane->lease_client_id == server->mux_client.frontend_client_id ?
		find_mux_pane_output_scene(pane_scene, pane->lease_view_id) : NULL;
	if (lease_scene == NULL) {
		snprintf(error, sizeof(error),
			"mapped presentation has no owning output scene");
		bool ignored = false;
		char unmap_error[256] = {0};
		engineos_mux_client_unmap_presentation(&server->mux_client,
			target.pane_id, target.generation, (int32_t)pid, view->view_id,
			&ignored, unmap_error, sizeof(unmap_error));
		goto reject;
	}
	view->mux_presentation_visible = parent != NULL ?
		parent->mux_presentation_visible :
		pane != NULL && pane->active_surface_id == view->view_id;
	/* Keep transient trees as pane siblings: wlroots recursively destroys
	 * child scene nodes with their parent, while XDG destroys each toplevel
	 * independently. The logical parent still owns placement and lifecycle. */
	wlr_scene_node_reparent(&view->scene_tree->node, lease_scene->tree);
	if (parent == NULL) {
		struct engineos_shell_view *other = native_presentation_other_view(view);
		if (other != NULL)
			native_presentation_set_tab_visible(server, other, false);
	}
	apply_view_layout(view);
	wlr_scene_node_set_enabled(&view->scene_tree->node,
		view->mux_presentation_visible);
	if (view->mux_presentation_visible) {
		wlr_scene_node_set_enabled(&lease_scene->terminal_scene->node, false);
		/* Mapping on a retained nonfocused output must not steal the seat from
		 * the focused graphical view. The surface is live and visible beneath
		 * its lease; it becomes the seat target when that output is focused. */
		if (lease_scene->output == focused_mux_output(server))
			activate_view(view, "native-presentation-mapped");
	}
	if (grid_changed && !refresh_native_terminal_scene(server,
			"native-presentation-map")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	wlr_log(WLR_INFO,
		"native presentation mapped pane=%%%u generation=%u pid=%ld surface=%u role=%s visible=%s title=%s app_id=%s",
		view->mux_pane_id, view->mux_pane_generation, (long)pid,
		view->view_id, surface_role,
		view->mux_presentation_visible ? "true" : "false",
		view_title(view), view_app_id(view));
	return true;

reject:
	wlr_log(WLR_ERROR,
		"native presentation rejected pid=%ld surface=%u reason=%s title=%s app_id=%s",
		(long)pid, view->view_id, error[0] != '\0' ? error : "unresolved scope",
		view_title(view), view_app_id(view));
	wlr_scene_node_set_enabled(&view->scene_tree->node, false);
	view->mapped = false;
	if (view->xdg_surface->toplevel != NULL)
		wlr_xdg_toplevel_send_close(view->xdg_surface->toplevel);
	return false;
}

static void native_presentation_unmap(struct engineos_shell_view *view) {
	if (!view->mux_bound)
		return;
	struct engineos_shell_server *server = view->server;
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_unmap_presentation(&server->mux_client,
			view->mux_pane_id, view->mux_pane_generation,
			(int32_t)view->mux_client_pid, view->view_id, &grid_changed,
			error, sizeof(error))) {
		wlr_log(WLR_INFO,
			"native presentation unmap already retired pane=%%%u generation=%u surface=%u reason=%s",
			view->mux_pane_id, view->mux_pane_generation, view->view_id,
			error[0] != '\0' ? error : "unknown");
	}
	if (!engineos_mux_client_refresh_presentation(&server->mux_client,
			error, sizeof(error))) {
		wlr_log(WLR_ERROR, "native presentation state refresh failed: %s",
			error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	if (!refresh_native_output_snapshots(server, &grid_changed, error,
			sizeof(error))) {
		wlr_log(WLR_ERROR,
			"native presentation unmap output refresh failed: %s", error);
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
	uint32_t pane_id = view->mux_pane_id;
	uint32_t pane_generation = view->mux_pane_generation;
	struct engineos_mux_pane_model *focused_pane = focused_mux_pane(server);
	bool pane_is_focused = focused_pane != NULL &&
		focused_pane->pane_id == pane_id &&
		focused_pane->generation == pane_generation;
	bool transient = view->mux_transient;
	bool was_visible = view->mux_presentation_visible;
	struct engineos_shell_view *parent = view->mux_parent;
	view->mux_bound = false;
	view->mux_presentation_visible = false;
	view->mux_transient = false;
	view->mux_parent = NULL;
	if (transient) {
		if (parent != NULL && parent->mapped && parent->mux_bound &&
				pane_is_focused)
			activate_view(parent, "native-transient-unmapped");
	} else if (was_visible) {
		struct engineos_shell_view *other =
			native_presentation_any_tab(view);
		if (other != NULL && pane_is_focused) {
			native_presentation_set_tab_visible(server, other, true);
			activate_view(other, "native-presentation-tab-promoted");
		} else {
			struct engineos_mux_pane_scene *pane_scene =
				find_mux_pane_scene(server, pane_id, pane_generation);
			if (pane_scene != NULL) {
				struct engineos_mux_pane_output_scene *output_scene;
				wl_list_for_each(output_scene, &pane_scene->output_scenes, link)
					wlr_scene_node_set_enabled(
						&output_scene->terminal_scene->node, true);
			}
			if (pane_is_focused)
				server->input_mode = ENGINEOS_INPUT_TERMINAL;
		}
	}
	if (grid_changed && !refresh_native_terminal_scene(server,
			"native-presentation-unmap")) {
		server->mux_client.ready = false;
		wl_display_terminate(server->display);
	}
}

static void xdg_surface_map(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, map);
	view->mapped = true;
	view->role = ENGINEOS_SURFACE_MUX_PRESENTATION;
	if (native_presentation_map(view))
		write_shell_state(view->server, "native-presentation-mapped");
	else
		write_shell_state(view->server, "native-presentation-rejected");
}

static void xdg_surface_unmap(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, unmap);
	bool native_game = view_is_native_mux_game(view);
	bool was_focused = view->server->focused_view == view;
	bool restore_cursor = was_focused;
	view->mapped = false;
	wlr_scene_node_set_enabled(&view->scene_tree->node, false);
	native_presentation_unmap(view);
	if (view->server->moving_view == view) {
		view->server->moving_view = NULL;
	}
	if (view->server->focused_view == view) {
		view->server->focused_view = NULL;
		set_view_activated(view, false);
		wlr_seat_keyboard_notify_clear_focus(view->server->seat);
	}
	if (native_game && view->server->game_capture) {
		view->server->game_capture = false;
		restore_cursor = true;
	}
	if (restore_cursor) {
		sync_pointer_constraint(view->server, "focused-view-unmapped");
		sync_cursor_image(view->server, "focused-view-unmapped");
	}
	schedule_outputs(view->server);
	wlr_log(WLR_INFO, "view unmapped role=%s id=%u title=%s app_id=%s",
		surface_role_name(view->role), view->view_id, view_title(view),
		view_app_id(view));
	write_shell_state(view->server, "view-unmapped");
}

static void xdg_surface_commit(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_view *view = wl_container_of(listener, view, commit);
	if (view->xdg_surface->initial_commit &&
			view->xdg_surface->toplevel != NULL) {
		view->role = ENGINEOS_SURFACE_MUX_PRESENTATION;
		set_toplevel_wm_capabilities(view->xdg_surface->toplevel);
		struct engineos_view_geometry geometry = {0};
		compute_view_geometry(view, &geometry);
		if (xdg_toplevel_can_configure(view->xdg_surface->toplevel)) {
			wlr_xdg_toplevel_set_size(view->xdg_surface->toplevel,
				geometry.width, geometry.height);
		}
		wlr_log(WLR_INFO, "view initial configure id=%u role=%s title=%s app_id=%s",
			view->view_id, surface_role_name(view->role), view_title(view),
			view_app_id(view));
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
	bool native_game = view_is_native_mux_game(view);
	bool was_focused = server->focused_view == view;
	bool restore_cursor = was_focused;
	if (view->mux_bound)
		native_presentation_unmap(view);

	wlr_log(WLR_INFO, "view destroyed role=%s id=%u title=%s app_id=%s",
		surface_role_name(view->role), view->view_id,
		view_title(view), view_app_id(view));
	if (server->focused_view == view) {
		server->focused_view = NULL;
		wlr_seat_keyboard_notify_clear_focus(server->seat);
	}
	if (server->moving_view == view) {
		server->moving_view = NULL;
	}
	if (native_game && server->game_capture) {
		server->game_capture = false;
		restore_cursor = true;
	}
	if (restore_cursor) {
		sync_pointer_constraint(server, "focused-view-destroyed");
		sync_cursor_image(server, "focused-view-destroyed");
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
	sync_cursor_image(server, "constraint-requested");
	write_shell_state(server, "constraint-requested");
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

static void xdg_popup_unmap_mux(struct engineos_shell_popup *popup) {
	if (!popup->mux_bound)
		return;
	bool grid_changed = false;
	char error[256] = {0};
	if (!engineos_mux_client_unmap_presentation(&popup->server->mux_client,
			popup->owner->mux_pane_id, popup->owner->mux_pane_generation,
			(int32_t)popup->client_pid, popup->surface_id, &grid_changed,
			error, sizeof(error))) {
		wlr_log(WLR_INFO,
			"native popup unmap already retired pane=%%%u surface=%u reason=%s",
			popup->owner->mux_pane_id, popup->surface_id,
			error[0] != '\0' ? error : "unknown");
	}
	popup->mux_bound = false;
	if (popup->server->mux_popup_count > 0)
		popup->server->mux_popup_count--;
}

static void xdg_popup_map(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_popup *popup =
		wl_container_of(listener, popup, map);
	popup->mapped = true;
	char error[256] = {0};
	bool grid_changed = false;
	if (popup->owner == NULL || !popup->owner->mux_bound ||
			!xdg_surface_client_credentials(popup->xdg_popup->base,
				&popup->client_pid) || popup->client_pid > INT32_MAX) {
		snprintf(error, sizeof(error),
			"popup parent or client credentials are not bound");
		goto reject;
	}
	struct engineos_mux_presentation_target target = {
		.pane_id = popup->owner->mux_pane_id,
		.generation = popup->owner->mux_pane_generation,
	};
	struct engineos_mux_pane_model *target_pane = find_shell_pane_model(
		popup->server, target.pane_id, target.generation);
	struct engineos_shell_output *target_output = output_for_pane_model(
		popup->server, target_pane);
	if (target_output == NULL) {
		snprintf(error, sizeof(error),
			"popup pane has no owning graphical output model");
		goto reject;
	}
	if (!engineos_mux_client_map_presentation(&popup->server->mux_client,
			&target, (int32_t)popup->client_pid, popup->surface_id,
			target_output->mux_view_id, "popup",
			&grid_changed, error, sizeof(error)))
		goto reject;
	popup->mux_bound = true;
	popup->server->mux_popup_count++;
	wlr_log(WLR_INFO,
		"native popup mapped pane=%%%u generation=%u pid=%ld surface=%u",
		target.pane_id, target.generation, (long)popup->client_pid,
		popup->surface_id);
	write_shell_state(popup->server, "native-popup-mapped");
	return;

reject:
	wlr_log(WLR_ERROR,
		"native popup rejected surface=%u reason=%s",
		popup->surface_id, error[0] != '\0' ? error : "unknown");
	popup->mapped = false;
	wlr_xdg_popup_destroy(popup->xdg_popup);
}

static void xdg_popup_unmap(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_popup *popup =
		wl_container_of(listener, popup, unmap);
	popup->mapped = false;
	xdg_popup_unmap_mux(popup);
	write_shell_state(popup->server, "native-popup-unmapped");
}

static void xdg_popup_destroy(struct wl_listener *listener, void *data) {
	(void)data;
	struct engineos_shell_popup *popup =
		wl_container_of(listener, popup, destroy);
	xdg_popup_unmap_mux(popup);

	if (popup->xdg_popup != NULL && popup->xdg_popup->base != NULL) {
		popup->xdg_popup->base->data = NULL;
	}
	wl_list_remove(&popup->map.link);
	wl_list_remove(&popup->unmap.link);
	wl_list_remove(&popup->commit.link);
	wl_list_remove(&popup->destroy.link);
	free(popup);
}

static void server_new_xdg_popup(struct wl_listener *listener, void *data) {
	struct engineos_shell_server *server =
		wl_container_of(listener, server, new_xdg_popup);
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
	popup->server = server;
	popup->scene_tree = popup_tree;
	popup->owner = native_owner_view_for_xdg(server, parent);
	if (server->next_view_id == 0)
		server->next_view_id = 1;
	popup->surface_id = server->next_view_id++;
	xdg_popup->base->data = popup_tree;
	popup->map.notify = xdg_popup_map;
	wl_signal_add(&xdg_popup->base->surface->events.map, &popup->map);
	popup->unmap.notify = xdg_popup_unmap;
	wl_signal_add(&xdg_popup->base->surface->events.unmap, &popup->unmap);
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
	if (server->next_view_id == 0) {
		server->next_view_id = 1;
	}
	view->view_id = server->next_view_id++;
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

	wlr_log(WLR_INFO, "view created id=%u count=%u role=toplevel surface_role=%s",
		view->view_id, server->view_count, surface_role_name(view->role));
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
	server->screencopy_mgr = wlr_screencopy_manager_v1_create(server->display);
	if (server->screencopy_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create screencopy manager");
		return false;
	}
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
	server->xdg_output_mgr = wlr_xdg_output_manager_v1_create(server->display,
		server->output_layout);
	if (server->xdg_output_mgr == NULL) {
		wlr_log(WLR_ERROR, "failed to create xdg-output manager");
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
	server->request_start_drag.notify = seat_request_start_drag;
	wl_signal_add(&server->seat->events.request_start_drag,
		&server->request_start_drag);
	server->start_drag.notify = seat_start_drag;
	wl_signal_add(&server->seat->events.start_drag, &server->start_drag);

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
	if (server->mux_event_source != NULL) {
		wl_event_source_remove(server->mux_event_source);
		server->mux_event_source = NULL;
	}
	if (server->mux_snapshot_retry_timer != NULL) {
		wl_event_source_remove(server->mux_snapshot_retry_timer);
		server->mux_snapshot_retry_timer = NULL;
	}
	if (server->terminal_blink_timer != NULL) {
		wl_event_source_remove(server->terminal_blink_timer);
		server->terminal_blink_timer = NULL;
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
	remove_listener_if_linked(&server->request_start_drag);
	remove_listener_if_linked(&server->start_drag);
	clear_active_drag(server, "shell-destroy");
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
	if (server->mux_pane_tree != NULL) {
		wlr_scene_node_destroy(&server->mux_pane_tree->node);
		server->mux_pane_tree = NULL;
		server->mux_terminal_scene = NULL;
		server->mux_ui_scene = NULL;
	}
	struct engineos_mux_pane_scene *pane_scene, *next_pane_scene;
	wl_list_for_each_safe(pane_scene, next_pane_scene,
			&server->mux_pane_scenes, link) {
		wl_list_remove(&pane_scene->link);
		free(pane_scene);
	}
	struct engineos_preview_failure *failure, *next_failure;
	wl_list_for_each_safe(failure, next_failure,
			&server->preview_failures, link) {
		wl_list_remove(&failure->link);
		free(failure);
	}
	server->mux_terminal_renderer = NULL;
	server->mux_terminal_buffer = NULL;
	if (server->scene != NULL) {
		wlr_scene_node_destroy(&server->scene->tree.node);
		server->scene = NULL;
	}
	if (server->cursor_mgr != NULL) {
		wlr_xcursor_manager_destroy(server->cursor_mgr);
		server->cursor_mgr = NULL;
	}
	if (server->test_pointer_initialized) {
		wlr_pointer_finish(&server->test_pointer);
		server->test_pointer_initialized = false;
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
	engineos_mux_client_destroy(&server->mux_client);
	free(server->state_file);
	server->state_file = NULL;
	free(server->state_dir);
	server->state_dir = NULL;
}

int main(int argc, char **argv) {
	setlocale(LC_CTYPE, "");
	enum engineos_shell_mode mode = ENGINEOS_SHELL_AUTO;
	struct engineos_shell_server server = {0};
	load_terminal_theme_defaults(&server);
	server.preview_socket_fd = -1;
	server.mux_client.fd = -1;
	wl_list_init(&server.mux_pane_scenes);
	wl_list_init(&server.previews);
	wl_list_init(&server.preview_failures);
	wl_list_init(&server.outputs);
	wl_list_init(&server.views);
	wl_list_init(&server.keyboards);
	wl_list_init(&server.pointers);

	static const struct option options[] = {
		{"headless", no_argument, NULL, 'H'},
		{"nested", no_argument, NULL, 'N'},
		{"tty", no_argument, NULL, 'T'},
		{"smoke", no_argument, NULL, 's'},
		{"smoke-ms", required_argument, NULL, 'm'},
		{"version", no_argument, NULL, 'v'},
		{"help", no_argument, NULL, 'h'},
		{0},
	};

	int opt;
	while ((opt = getopt_long(argc, argv, "HNTsm:vh", options, NULL)) != -1) {
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
	const char *wlr_debug = getenv("ENGINEOS_WLR_DEBUG");
	wlr_log_init(wlr_debug != NULL && strcmp(wlr_debug, "1") == 0 ?
		WLR_DEBUG : WLR_INFO, NULL);
	if (!init_shell_state_path(&server)) {
		fprintf(stderr, "engineos-shell: failed to allocate shell state paths\n");
		destroy_server(&server);
		return 1;
	}
	const char *configured_socket = getenv("ENGINEOS_MUX_SOCKET");
	char *default_socket = NULL;
	if (configured_socket == NULL || configured_socket[0] == '\0') {
		default_socket = join_state_path(server.state_dir, "mux.sock");
		configured_socket = default_socket;
	}
	char mux_error[256] = {0};
	bool connected = configured_socket != NULL &&
		engineos_mux_client_connect(&server.mux_client, configured_socket,
			mux_error, sizeof(mux_error));
	free(default_socket);
	if (!connected) {
		fprintf(stderr, "engineos-shell: mux handshake failed: %s\n",
			mux_error[0] != '\0' ? mux_error : "socket path allocation failed");
		engineos_mux_client_destroy(&server.mux_client);
		free(server.state_file);
		free(server.state_dir);
		return 1;
	}

	if (!setup_server(&server)) {
		destroy_server(&server);
		return 1;
	}
	if (!init_test_pointer(&server)) {
		destroy_server(&server);
		return 1;
	}
	if (!setup_native_terminal_scene(&server)) {
		destroy_server(&server);
		return 1;
	}

	struct wl_event_loop *event_loop = wl_display_get_event_loop(server.display);
	server.mux_event_source = wl_event_loop_add_fd(event_loop,
		server.mux_client.fd,
		WL_EVENT_READABLE | WL_EVENT_HANGUP | WL_EVENT_ERROR,
		native_mux_event, &server);
	if (server.mux_event_source == NULL) {
		wlr_log(WLR_ERROR, "failed to register mux event source");
		destroy_server(&server);
		return 1;
	}
	wl_event_loop_add_signal(event_loop, SIGINT, terminate_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGTERM, terminate_from_signal, &server);
	wl_event_loop_add_signal(event_loop, SIGHUP, relayout_from_signal, &server);
	server.mux_snapshot_retry_timer =
		wl_event_loop_add_timer(event_loop, native_mux_snapshot_retry, &server);
	if (server.mux_snapshot_retry_timer == NULL) {
		wlr_log(WLR_ERROR, "failed to add native mux snapshot retry timer");
		destroy_server(&server);
		return 1;
	}
	server.terminal_blink_timer =
		wl_event_loop_add_timer(event_loop, terminal_blink_tick, &server);
	if (server.terminal_blink_timer == NULL) {
		wlr_log(WLR_ERROR, "failed to add terminal blink timer");
		destroy_server(&server);
		return 1;
	}
	wl_event_source_timer_update(server.terminal_blink_timer, 500);

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
	if (!server.mux_client.ready) {
		wlr_log(WLR_ERROR, "native mux graphical view registration failed");
		destroy_server(&server);
		return 1;
	}

	wlr_log(WLR_INFO, "engineos-shell mode=%s backend=%s wayland_display=%s",
		server.mode_name, getenv("WLR_BACKENDS") ? getenv("WLR_BACKENDS") : "auto", socket);
	wlr_log(WLR_INFO, "input mode=%s capture=%s reason=startup",
		input_mode_name(server.input_mode),
		server.game_capture ? "game" : "none");
	wlr_log(WLR_INFO,
		"mux mode=%s connected=%s revision=%llu socket=%s pane=%%%u generation=%u grid_revision=%llu grid=%ux%u nonblank=%u",
		"native",
		server.mux_client.ready ? "true" : "false",
		(unsigned long long)server.mux_client.revision,
		server.mux_client.socket_path != NULL ? server.mux_client.socket_path : "(none)",
		server.mux_client.pane_id, server.mux_client.pane_generation,
		(unsigned long long)server.mux_client.grid_revision,
		server.mux_client.grid_columns, server.mux_client.grid_rows,
		server.mux_client.grid_nonblank_cells);
	wlr_log(WLR_INFO,
		"client launch environment wayland_display=%s xdg_session_type=wayland display=unset sdl=wayland gdk=wayland qt=wayland",
		socket);
	write_shell_state(&server, "startup");

	wl_display_run(server.display);
	bool runtime_failed = !server.mux_client.ready;
	wlr_log(WLR_INFO, "engineos-shell shutdown outputs=%u keyboards=%u pointers=%u views=%u",
		server.output_count, server.keyboard_count, server.pointer_count, server.view_count);
	write_shell_state(&server, "shutdown");
	destroy_server(&server);
	return runtime_failed ? 1 : 0;
}
