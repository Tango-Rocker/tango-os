#ifndef ENGINEOS_TERMINAL_RENDERER_H
#define ENGINEOS_TERMINAL_RENDERER_H

#include <stddef.h>
#include <stdint.h>

struct engineos_mux_client;
struct wlr_buffer;

struct wlr_buffer *engineos_terminal_render(
	const struct engineos_mux_client *client, int *width, int *height,
	uint32_t *glyph_cells, char *error, size_t error_size);

#endif
