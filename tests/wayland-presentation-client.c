#define _POSIX_C_SOURCE 200809L

#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

struct client_state {
	struct wl_display *display;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct wl_seat *seat;
	struct wl_pointer *pointer;
	struct zwp_pointer_constraints_v1 *pointer_constraints;
	struct zwp_locked_pointer_v1 *locked_pointer;
	struct zwp_relative_pointer_manager_v1 *relative_pointer_manager;
	struct zwp_relative_pointer_v1 *relative_pointer;
	struct xdg_wm_base *wm_base;
	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct wl_buffer *buffer;
	struct wl_surface *popup_surface;
	struct xdg_surface *popup_xdg_surface;
	struct xdg_popup *popup;
	struct wl_buffer *popup_buffer;
	struct wl_surface *transient_surface;
	struct xdg_surface *transient_xdg_surface;
	struct xdg_toplevel *transient_toplevel;
	struct wl_buffer *transient_buffer;
	struct wl_surface *tab_surface;
	struct xdg_surface *tab_xdg_surface;
	struct xdg_toplevel *tab_toplevel;
	struct wl_buffer *tab_buffer;
	bool configured;
	bool popup_configured;
	bool transient_configured;
	bool tab_configured;
	bool request_popup;
	bool request_transient;
	bool request_tab;
	bool request_pointer_lock;
	FILE *pointer_log;
	int configured_width;
	int configured_height;
	int buffer_width;
	int buffer_height;
	int wake_read_fd;
	int wake_write_fd;
	bool running;
};

static const struct xdg_toplevel_listener toplevel_listener;
static const struct wl_seat_listener seat_listener;
static const struct wl_pointer_listener pointer_listener;
static void destroy_tab(struct client_state *state);
static int signal_wake_fd = -1;

static void log_pointer_event(struct client_state *state,
		const char *format, ...) {
	if (state->pointer_log == NULL)
		return;
	va_list args;
	va_start(args, format);
	vfprintf(state->pointer_log, format, args);
	va_end(args);
	fputc('\n', state->pointer_log);
	fflush(state->pointer_log);
}

static void request_close_tab(int signal_number) {
	(void)signal_number;
	if (signal_wake_fd >= 0) {
		const char byte = 'x';
		(void)write(signal_wake_fd, &byte, 1);
	}
}

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base,
		uint32_t serial) {
	(void)data;
	xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = wm_base_ping,
};

static void registry_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct client_state *state = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		state->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, version < 4 ? version : 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		state->seat = wl_registry_bind(registry, name, &wl_seat_interface,
			version < 9 ? version : 9);
		wl_seat_add_listener(state->seat, &seat_listener, state);
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, version < 6 ? version : 6);
		xdg_wm_base_add_listener(state->wm_base, &wm_base_listener, state);
	} else if (strcmp(interface,
			zwp_pointer_constraints_v1_interface.name) == 0) {
		state->pointer_constraints = wl_registry_bind(registry, name,
			&zwp_pointer_constraints_v1_interface, 1);
	} else if (strcmp(interface,
			zwp_relative_pointer_manager_v1_interface.name) == 0) {
		state->relative_pointer_manager = wl_registry_bind(registry, name,
			&zwp_relative_pointer_manager_v1_interface, 1);
	}
}

static void registry_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

static void pointer_enter(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface,
		wl_fixed_t surface_x, wl_fixed_t surface_y) {
	(void)pointer;
	(void)serial;
	(void)surface;
	struct client_state *state = data;
	log_pointer_event(state, "enter %.2f %.2f",
		wl_fixed_to_double(surface_x), wl_fixed_to_double(surface_y));
}

static void pointer_leave(void *data, struct wl_pointer *pointer,
		uint32_t serial, struct wl_surface *surface) {
	(void)pointer;
	(void)serial;
	(void)surface;
	log_pointer_event(data, "leave");
}

static void pointer_motion(void *data, struct wl_pointer *pointer,
		uint32_t time, wl_fixed_t surface_x, wl_fixed_t surface_y) {
	(void)pointer;
	(void)time;
	log_pointer_event(data, "motion %.2f %.2f",
		wl_fixed_to_double(surface_x), wl_fixed_to_double(surface_y));
}

static void pointer_button(void *data, struct wl_pointer *pointer,
		uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
	(void)pointer;
	(void)serial;
	(void)time;
	log_pointer_event(data, "button %u %s", button,
		state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed" : "released");
}

static void pointer_axis(void *data, struct wl_pointer *pointer,
		uint32_t time, uint32_t axis, wl_fixed_t value) {
	(void)pointer;
	(void)time;
	log_pointer_event(data, "axis %u %.2f", axis,
		wl_fixed_to_double(value));
}

static void pointer_frame(void *data, struct wl_pointer *pointer) {
	(void)pointer;
	log_pointer_event(data, "frame");
}

static void pointer_axis_source(void *data, struct wl_pointer *pointer,
		uint32_t source) {
	(void)data;
	(void)pointer;
	(void)source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *pointer,
		uint32_t time, uint32_t axis) {
	(void)data;
	(void)pointer;
	(void)time;
	(void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *pointer,
		uint32_t axis, int32_t discrete) {
	(void)data;
	(void)pointer;
	(void)axis;
	(void)discrete;
}

static void pointer_axis_value120(void *data, struct wl_pointer *pointer,
		uint32_t axis, int32_t value120) {
	(void)data;
	(void)pointer;
	(void)axis;
	(void)value120;
}

static void pointer_axis_relative_direction(void *data,
		struct wl_pointer *pointer, uint32_t axis, uint32_t direction) {
	(void)data;
	(void)pointer;
	(void)axis;
	(void)direction;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
	.frame = pointer_frame,
	.axis_source = pointer_axis_source,
	.axis_stop = pointer_axis_stop,
	.axis_discrete = pointer_axis_discrete,
	.axis_value120 = pointer_axis_value120,
	.axis_relative_direction = pointer_axis_relative_direction,
};

static void seat_capabilities(void *data, struct wl_seat *seat,
		uint32_t capabilities) {
	struct client_state *state = data;
	if ((capabilities & WL_SEAT_CAPABILITY_POINTER) != 0 &&
			state->pointer == NULL) {
		state->pointer = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(state->pointer, &pointer_listener, state);
	}
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
	(void)data;
	(void)seat;
	(void)name;
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = seat_name,
};

static void locked_pointer_locked(void *data,
		struct zwp_locked_pointer_v1 *locked_pointer) {
	(void)locked_pointer;
	log_pointer_event(data, "constraint locked");
}

static void locked_pointer_unlocked(void *data,
		struct zwp_locked_pointer_v1 *locked_pointer) {
	(void)locked_pointer;
	log_pointer_event(data, "constraint unlocked");
}

static const struct zwp_locked_pointer_v1_listener locked_pointer_listener = {
	.locked = locked_pointer_locked,
	.unlocked = locked_pointer_unlocked,
};

static void relative_pointer_motion(void *data,
		struct zwp_relative_pointer_v1 *relative_pointer,
		uint32_t utime_hi, uint32_t utime_lo, wl_fixed_t dx, wl_fixed_t dy,
		wl_fixed_t dx_unaccel, wl_fixed_t dy_unaccel) {
	(void)relative_pointer;
	(void)utime_hi;
	(void)utime_lo;
	log_pointer_event(data, "relative %.2f %.2f %.2f %.2f",
		wl_fixed_to_double(dx), wl_fixed_to_double(dy),
		wl_fixed_to_double(dx_unaccel), wl_fixed_to_double(dy_unaccel));
}

static const struct zwp_relative_pointer_v1_listener relative_pointer_listener = {
	.relative_motion = relative_pointer_motion,
};

static bool create_locked_pointer(struct client_state *state) {
	if (!state->request_pointer_lock)
		return true;
	if (state->pointer == NULL || state->pointer_constraints == NULL ||
			state->relative_pointer_manager == NULL) {
		fprintf(stderr,
			"wayland test client: pointer lock globals unavailable\n");
		return false;
	}
	state->relative_pointer =
		zwp_relative_pointer_manager_v1_get_relative_pointer(
			state->relative_pointer_manager, state->pointer);
	zwp_relative_pointer_v1_add_listener(state->relative_pointer,
		&relative_pointer_listener, state);
	state->locked_pointer = zwp_pointer_constraints_v1_lock_pointer(
		state->pointer_constraints, state->surface, state->pointer, NULL,
		ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
	zwp_locked_pointer_v1_add_listener(state->locked_pointer,
		&locked_pointer_listener, state);
	return true;
}

static void buffer_release(void *data, struct wl_buffer *buffer) {
	(void)data;
	(void)buffer;
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static struct wl_buffer *create_buffer(struct client_state *state,
		int width, int height) {
	const int stride = width * 4;
	const size_t size = (size_t)stride * height;
	char path[] = "/tmp/engineos-wayland-client-XXXXXX";
	int fd = mkstemp(path);
	if (fd < 0)
		return NULL;
	unlink(path);
	if (ftruncate(fd, (off_t)size) < 0) {
		close(fd);
		return NULL;
	}
	uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, 0);
	if (pixels == MAP_FAILED) {
		close(fd);
		return NULL;
	}
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint8_t red = (uint8_t)(40 + x * 2);
			uint8_t green = (uint8_t)(60 + y * 2);
			pixels[y * width + x] = UINT32_C(0xff000000) |
				((uint32_t)red << 16) | ((uint32_t)green << 8) | 0x70;
		}
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(state->shm, fd, (int)size);
	struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width,
		height, stride, WL_SHM_FORMAT_XRGB8888);
	wl_buffer_add_listener(buffer, &buffer_listener, state);
	wl_shm_pool_destroy(pool);
	munmap(pixels, size);
	close(fd);
	return buffer;
}

static void popup_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct client_state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (!state->popup_configured) {
		state->popup_configured = true;
		wl_surface_attach(state->popup_surface, state->popup_buffer, 0, 0);
		wl_surface_damage_buffer(state->popup_surface, 0, 0,
			INT32_MAX, INT32_MAX);
		wl_surface_commit(state->popup_surface);
	}
}

static const struct xdg_surface_listener popup_surface_listener = {
	.configure = popup_surface_configure,
};

static void popup_configure(void *data, struct xdg_popup *popup,
		int32_t x, int32_t y, int32_t width, int32_t height) {
	(void)data;
	(void)popup;
	(void)x;
	(void)y;
	(void)width;
	(void)height;
}

static void popup_done(void *data, struct xdg_popup *popup) {
	(void)data;
	(void)popup;
}

static void popup_repositioned(void *data, struct xdg_popup *popup,
		uint32_t token) {
	(void)data;
	(void)popup;
	(void)token;
}

static const struct xdg_popup_listener popup_listener = {
	.configure = popup_configure,
	.popup_done = popup_done,
	.repositioned = popup_repositioned,
};

static bool create_popup(struct client_state *state) {
	state->popup_surface = wl_compositor_create_surface(state->compositor);
	state->popup_xdg_surface = xdg_wm_base_get_xdg_surface(state->wm_base,
		state->popup_surface);
	xdg_surface_add_listener(state->popup_xdg_surface,
		&popup_surface_listener, state);
	struct xdg_positioner *positioner =
		xdg_wm_base_create_positioner(state->wm_base);
	xdg_positioner_set_size(positioner, 48, 32);
	xdg_positioner_set_anchor_rect(positioner, 8, 8, 24, 16);
	xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
	xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
	state->popup = xdg_surface_get_popup(state->popup_xdg_surface,
		state->xdg_surface, positioner);
	xdg_positioner_destroy(positioner);
	xdg_popup_add_listener(state->popup, &popup_listener, state);
	state->popup_buffer = create_buffer(state, 48, 32);
	if (state->popup_buffer == NULL)
		return false;
	wl_surface_commit(state->popup_surface);
	return true;
}

static void transient_surface_configure(void *data,
		struct xdg_surface *surface, uint32_t serial) {
	struct client_state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (!state->transient_configured) {
		state->transient_configured = true;
		wl_surface_attach(state->transient_surface, state->transient_buffer,
			0, 0);
		wl_surface_damage_buffer(state->transient_surface, 0, 0,
			INT32_MAX, INT32_MAX);
		wl_surface_commit(state->transient_surface);
	}
}

static const struct xdg_surface_listener transient_surface_listener = {
	.configure = transient_surface_configure,
};

static bool create_transient(struct client_state *state) {
	state->transient_surface = wl_compositor_create_surface(state->compositor);
	state->transient_xdg_surface = xdg_wm_base_get_xdg_surface(state->wm_base,
		state->transient_surface);
	xdg_surface_add_listener(state->transient_xdg_surface,
		&transient_surface_listener, state);
	state->transient_toplevel =
		xdg_surface_get_toplevel(state->transient_xdg_surface);
	xdg_toplevel_add_listener(state->transient_toplevel,
		&toplevel_listener, state);
	xdg_toplevel_set_parent(state->transient_toplevel, state->toplevel);
	xdg_toplevel_set_title(state->transient_toplevel,
		"EngineOS scoped transient proof");
	xdg_toplevel_set_app_id(state->transient_toplevel,
		"engineos.presentation-transient-proof");
	state->transient_buffer = create_buffer(state, 56, 40);
	if (state->transient_buffer == NULL)
		return false;
	wl_surface_commit(state->transient_surface);
	return true;
}

static void tab_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct client_state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (!state->tab_configured) {
		state->tab_configured = true;
		wl_surface_attach(state->tab_surface, state->tab_buffer, 0, 0);
		wl_surface_damage_buffer(state->tab_surface, 0, 0,
			INT32_MAX, INT32_MAX);
		wl_surface_commit(state->tab_surface);
	}
}

static const struct xdg_surface_listener tab_surface_listener = {
	.configure = tab_surface_configure,
};

static bool create_tab(struct client_state *state) {
	state->tab_surface = wl_compositor_create_surface(state->compositor);
	state->tab_xdg_surface = xdg_wm_base_get_xdg_surface(state->wm_base,
		state->tab_surface);
	xdg_surface_add_listener(state->tab_xdg_surface,
		&tab_surface_listener, state);
	state->tab_toplevel = xdg_surface_get_toplevel(state->tab_xdg_surface);
	xdg_toplevel_add_listener(state->tab_toplevel,
		&toplevel_listener, state);
	xdg_toplevel_set_title(state->tab_toplevel,
		"EngineOS scoped secondary tab proof");
	xdg_toplevel_set_app_id(state->tab_toplevel,
		"engineos.presentation-tab-proof");
	state->tab_buffer = create_buffer(state, 72, 48);
	if (state->tab_buffer == NULL)
		return false;
	wl_surface_commit(state->tab_surface);
	return true;
}

static void destroy_tab(struct client_state *state) {
	if (state->tab_buffer != NULL) {
		wl_buffer_destroy(state->tab_buffer);
		state->tab_buffer = NULL;
	}
	if (state->tab_toplevel != NULL) {
		xdg_toplevel_destroy(state->tab_toplevel);
		state->tab_toplevel = NULL;
	}
	if (state->tab_xdg_surface != NULL) {
		xdg_surface_destroy(state->tab_xdg_surface);
		state->tab_xdg_surface = NULL;
	}
	if (state->tab_surface != NULL) {
		wl_surface_destroy(state->tab_surface);
		state->tab_surface = NULL;
	}
}

static void xdg_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct client_state *state = data;
	xdg_surface_ack_configure(surface, serial);
	bool first_configure = !state->configured;
	state->configured = true;
	if (state->buffer == NULL ||
			state->buffer_width != state->configured_width ||
			state->buffer_height != state->configured_height) {
		struct wl_buffer *next_buffer = create_buffer(state,
			state->configured_width, state->configured_height);
		if (next_buffer == NULL) {
			state->running = false;
			return;
		}
		if (state->buffer != NULL)
			wl_buffer_destroy(state->buffer);
		state->buffer = next_buffer;
		state->buffer_width = state->configured_width;
		state->buffer_height = state->configured_height;
		wl_surface_attach(state->surface, state->buffer, 0, 0);
		wl_surface_damage_buffer(state->surface, 0, 0, INT32_MAX, INT32_MAX);
		wl_surface_commit(state->surface);
		log_pointer_event(state, "configured %d %d",
			state->buffer_width, state->buffer_height);
	}
	if (first_configure) {
		if (state->request_popup && !create_popup(state))
			state->running = false;
		if (state->request_transient && !create_transient(state))
			state->running = false;
		if (state->request_tab && !create_tab(state))
			state->running = false;
		if (!create_locked_pointer(state))
			state->running = false;
	}
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	struct client_state *state = data;
	(void)toplevel;
	(void)states;
	if (width > 0 && height > 0) {
		state->configured_width = width;
		state->configured_height = height;
	}
}

static void toplevel_close(void *data, struct xdg_toplevel *toplevel) {
	(void)toplevel;
	struct client_state *state = data;
	state->running = false;
}

static void toplevel_configure_bounds(void *data,
		struct xdg_toplevel *toplevel, int32_t width, int32_t height) {
	(void)data;
	(void)toplevel;
	(void)width;
	(void)height;
}

static void toplevel_wm_capabilities(void *data,
		struct xdg_toplevel *toplevel, struct wl_array *capabilities) {
	(void)data;
	(void)toplevel;
	(void)capabilities;
}

static const struct xdg_toplevel_listener toplevel_listener = {
	.configure = toplevel_configure,
	.close = toplevel_close,
	.configure_bounds = toplevel_configure_bounds,
	.wm_capabilities = toplevel_wm_capabilities,
};

static void destroy_state(struct client_state *state) {
	destroy_tab(state);
	if (state->locked_pointer != NULL)
		zwp_locked_pointer_v1_destroy(state->locked_pointer);
	if (state->relative_pointer != NULL)
		zwp_relative_pointer_v1_destroy(state->relative_pointer);
	if (state->transient_buffer != NULL)
		wl_buffer_destroy(state->transient_buffer);
	if (state->transient_toplevel != NULL)
		xdg_toplevel_destroy(state->transient_toplevel);
	if (state->transient_xdg_surface != NULL)
		xdg_surface_destroy(state->transient_xdg_surface);
	if (state->transient_surface != NULL)
		wl_surface_destroy(state->transient_surface);
	if (state->popup_buffer != NULL) wl_buffer_destroy(state->popup_buffer);
	if (state->popup != NULL) xdg_popup_destroy(state->popup);
	if (state->popup_xdg_surface != NULL)
		xdg_surface_destroy(state->popup_xdg_surface);
	if (state->popup_surface != NULL) wl_surface_destroy(state->popup_surface);
	if (state->buffer != NULL) wl_buffer_destroy(state->buffer);
	if (state->toplevel != NULL) xdg_toplevel_destroy(state->toplevel);
	if (state->xdg_surface != NULL) xdg_surface_destroy(state->xdg_surface);
	if (state->surface != NULL) wl_surface_destroy(state->surface);
	if (state->wm_base != NULL) xdg_wm_base_destroy(state->wm_base);
	if (state->pointer != NULL) wl_pointer_release(state->pointer);
	if (state->seat != NULL) wl_seat_release(state->seat);
	if (state->relative_pointer_manager != NULL)
		zwp_relative_pointer_manager_v1_destroy(
			state->relative_pointer_manager);
	if (state->pointer_constraints != NULL)
		zwp_pointer_constraints_v1_destroy(state->pointer_constraints);
	if (state->shm != NULL) wl_shm_destroy(state->shm);
	if (state->compositor != NULL) wl_compositor_destroy(state->compositor);
	if (state->display != NULL) wl_display_disconnect(state->display);
	if (state->wake_read_fd >= 0) close(state->wake_read_fd);
	if (state->wake_write_fd >= 0) close(state->wake_write_fd);
	if (state->pointer_log != NULL) fclose(state->pointer_log);
}

int main(void) {
	struct client_state state = {
		.wake_read_fd = -1,
		.wake_write_fd = -1,
		.running = true,
		.configured_width = 96,
		.configured_height = 64,
	};
	state.request_popup = getenv("ENGINEOS_WAYLAND_TEST_POPUP") != NULL;
	state.request_transient =
		getenv("ENGINEOS_WAYLAND_TEST_TRANSIENT") != NULL;
	state.request_tab = getenv("ENGINEOS_WAYLAND_TEST_TAB") != NULL;
	state.request_pointer_lock =
		getenv("ENGINEOS_WAYLAND_TEST_LOCK_POINTER") != NULL;
	const char *pointer_log_path = getenv("ENGINEOS_WAYLAND_TEST_POINTER_LOG");
	if (pointer_log_path != NULL && pointer_log_path[0] != '\0') {
		state.pointer_log = fopen(pointer_log_path, "w");
		if (state.pointer_log == NULL) {
			fprintf(stderr, "wayland test client: pointer log: %s\n",
				strerror(errno));
			return 1;
		}
	}
	int wake_pipe[2];
	if (pipe(wake_pipe) < 0) {
		fprintf(stderr, "wayland test client: pipe: %s\n", strerror(errno));
		return 1;
	}
	state.wake_read_fd = wake_pipe[0];
	state.wake_write_fd = wake_pipe[1];
	if (fcntl(state.wake_read_fd, F_SETFL, O_NONBLOCK) < 0 ||
			fcntl(state.wake_write_fd, F_SETFL, O_NONBLOCK) < 0) {
		fprintf(stderr, "wayland test client: pipe flags: %s\n",
			strerror(errno));
		destroy_state(&state);
		return 1;
	}
	signal_wake_fd = state.wake_write_fd;
	struct sigaction action = {.sa_handler = request_close_tab};
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGUSR1, &action, NULL) < 0) {
		fprintf(stderr, "wayland test client: sigaction: %s\n",
			strerror(errno));
		destroy_state(&state);
		return 1;
	}
	const char *delay_text = getenv("ENGINEOS_WAYLAND_TEST_DELAY_MS");
	if (delay_text != NULL && *delay_text != '\0') {
		char *end = NULL;
		long delay_ms = strtol(delay_text, &end, 10);
		if (*end != '\0' || delay_ms < 0 || delay_ms > 5000) {
			fprintf(stderr, "wayland test client: invalid delay\n");
			return 2;
		}
		struct timespec delay = {
			.tv_sec = delay_ms / 1000,
			.tv_nsec = (delay_ms % 1000) * 1000000L,
		};
		while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {
		}
	}
	state.display = wl_display_connect(NULL);
	if (state.display == NULL) {
		fprintf(stderr, "wayland test client: connect: %s\n", strerror(errno));
		return 1;
	}
	struct wl_registry *registry = wl_display_get_registry(state.display);
	wl_registry_add_listener(registry, &registry_listener, &state);
	int roundtrip_status = wl_display_roundtrip(state.display);
	if (roundtrip_status >= 0 && state.request_pointer_lock &&
			state.pointer == NULL) {
		roundtrip_status = wl_display_roundtrip(state.display);
	}
	if (roundtrip_status < 0 || state.compositor == NULL ||
			state.shm == NULL || state.wm_base == NULL ||
			(state.request_pointer_lock && (state.pointer == NULL ||
			 state.pointer_constraints == NULL ||
			 state.relative_pointer_manager == NULL))) {
		fprintf(stderr, "wayland test client: required globals unavailable\n");
		wl_registry_destroy(registry);
		destroy_state(&state);
		return 1;
	}
	wl_registry_destroy(registry);
	state.surface = wl_compositor_create_surface(state.compositor);
	state.xdg_surface = xdg_wm_base_get_xdg_surface(state.wm_base, state.surface);
	xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, &state);
	state.toplevel = xdg_surface_get_toplevel(state.xdg_surface);
	xdg_toplevel_add_listener(state.toplevel, &toplevel_listener, &state);
	xdg_toplevel_set_title(state.toplevel, "EngineOS scoped presentation proof");
	xdg_toplevel_set_app_id(state.toplevel, "engineos.presentation-proof");
	wl_surface_commit(state.surface);
	while (state.running) {
		while (wl_display_prepare_read(state.display) != 0) {
			if (wl_display_dispatch_pending(state.display) < 0)
				goto dispatch_done;
		}
		if (wl_display_flush(state.display) < 0 && errno != EAGAIN) {
			wl_display_cancel_read(state.display);
			break;
		}
		struct pollfd fds[2] = {
			{.fd = wl_display_get_fd(state.display), .events = POLLIN},
			{.fd = state.wake_read_fd, .events = POLLIN},
		};
		int poll_result;
		do
			poll_result = poll(fds, 2, -1);
		while (poll_result < 0 && errno == EINTR);
		if (poll_result < 0) {
			wl_display_cancel_read(state.display);
			break;
		}
		if ((fds[1].revents & POLLIN) != 0) {
			char bytes[32];
			while (read(state.wake_read_fd, bytes, sizeof(bytes)) > 0) {
			}
			wl_display_cancel_read(state.display);
			destroy_tab(&state);
			continue;
		}
		if ((fds[0].revents & (POLLIN | POLLERR | POLLHUP)) != 0) {
			if (wl_display_read_events(state.display) < 0 ||
					wl_display_dispatch_pending(state.display) < 0)
				break;
		} else {
			wl_display_cancel_read(state.display);
		}
	}
dispatch_done:
	bool closed = !state.running;
	destroy_state(&state);
	return closed ? 0 : 1;
}
