#define _POSIX_C_SOURCE 200809L

#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <fcntl.h>
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
	struct xdg_wm_base *wm_base;
	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *toplevel;
	struct wl_buffer *buffer;
	bool configured;
	bool running;
};

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
	} else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
		state->wm_base = wl_registry_bind(registry, name,
			&xdg_wm_base_interface, version < 6 ? version : 6);
		xdg_wm_base_add_listener(state->wm_base, &wm_base_listener, state);
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

static void buffer_release(void *data, struct wl_buffer *buffer) {
	(void)data;
	(void)buffer;
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static struct wl_buffer *create_buffer(struct client_state *state) {
	const int width = 96;
	const int height = 64;
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

static void xdg_surface_configure(void *data, struct xdg_surface *surface,
		uint32_t serial) {
	struct client_state *state = data;
	xdg_surface_ack_configure(surface, serial);
	if (!state->configured) {
		state->configured = true;
		wl_surface_attach(state->surface, state->buffer, 0, 0);
		wl_surface_damage_buffer(state->surface, 0, 0, INT32_MAX, INT32_MAX);
		wl_surface_commit(state->surface);
	}
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void toplevel_configure(void *data, struct xdg_toplevel *toplevel,
		int32_t width, int32_t height, struct wl_array *states) {
	(void)data;
	(void)toplevel;
	(void)width;
	(void)height;
	(void)states;
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
	if (state->buffer != NULL) wl_buffer_destroy(state->buffer);
	if (state->toplevel != NULL) xdg_toplevel_destroy(state->toplevel);
	if (state->xdg_surface != NULL) xdg_surface_destroy(state->xdg_surface);
	if (state->surface != NULL) wl_surface_destroy(state->surface);
	if (state->wm_base != NULL) xdg_wm_base_destroy(state->wm_base);
	if (state->shm != NULL) wl_shm_destroy(state->shm);
	if (state->compositor != NULL) wl_compositor_destroy(state->compositor);
	if (state->display != NULL) wl_display_disconnect(state->display);
}

int main(void) {
	struct client_state state = {.running = true};
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
	if (wl_display_roundtrip(state.display) < 0 || state.compositor == NULL ||
			state.shm == NULL || state.wm_base == NULL) {
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
	state.buffer = create_buffer(&state);
	if (state.buffer == NULL) {
		fprintf(stderr, "wayland test client: buffer allocation failed\n");
		destroy_state(&state);
		return 1;
	}
	wl_surface_commit(state.surface);
	while (state.running && wl_display_dispatch(state.display) >= 0) {
	}
	bool closed = !state.running;
	destroy_state(&state);
	return closed ? 0 : 1;
}
