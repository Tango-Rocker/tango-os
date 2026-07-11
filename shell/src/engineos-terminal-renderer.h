#ifndef ENGINEOS_TERMINAL_RENDERER_H
#define ENGINEOS_TERMINAL_RENDERER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <pixman.h>

struct engineos_mux_client;
struct wlr_allocator;
struct wlr_buffer;
struct wlr_drm_syncobj_timeline;
struct wlr_renderer;

struct engineos_terminal_renderer;

struct engineos_terminal_render_stats {
	int width;
	int height;
	uint32_t glyph_cells;
	uint32_t atlas_entries;
	uint32_t damaged_cells;
	uint32_t nonblank_pixels;
	uint64_t frame;
};

bool engineos_terminal_cell_metrics(int *cell_width, int *cell_height,
	char *error, size_t error_size);

struct wlr_buffer *engineos_terminal_render(
	const struct engineos_mux_client *client, int *width, int *height,
	uint32_t *glyph_cells, char *error, size_t error_size);

struct engineos_terminal_renderer *engineos_terminal_renderer_create(
	struct wlr_renderer *renderer, struct wlr_allocator *allocator,
	const struct engineos_mux_client *client, char *error, size_t error_size);
bool engineos_terminal_renderer_update(
	struct engineos_terminal_renderer *terminal,
	const struct engineos_mux_client *client, char *error, size_t error_size);
struct wlr_buffer *engineos_terminal_renderer_buffer(
	const struct engineos_terminal_renderer *terminal);
struct wlr_drm_syncobj_timeline *engineos_terminal_renderer_wait_timeline(
	const struct engineos_terminal_renderer *terminal);
uint64_t engineos_terminal_renderer_wait_point(
	const struct engineos_terminal_renderer *terminal);
const pixman_region32_t *engineos_terminal_renderer_damage(
	const struct engineos_terminal_renderer *terminal);
const char *engineos_terminal_renderer_mode(
	const struct engineos_terminal_renderer *terminal);
void engineos_terminal_renderer_stats(
	const struct engineos_terminal_renderer *terminal,
	struct engineos_terminal_render_stats *stats);
void engineos_terminal_renderer_destroy(
	struct engineos_terminal_renderer *terminal);

#endif
