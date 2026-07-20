#define _XOPEN_SOURCE 700

#include "engineos-terminal-renderer.h"

#include "engineos-image.h"
#include "engineos-mux-client.h"
#include "engineos-terminal-style.h"
#include "engineos-terminal-theme.h"

#include <arpa/inet.h>
#include <drm_fourcc.h>
#include <fcft/fcft.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wchar.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/render/gles2.h>
#include <wlr/render/pass.h>
#include <wlr/render/pixman.h>
#include <wlr/render/vulkan.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>

static uint32_t palette_colour(const struct engineos_terminal_theme *theme,
		int value, bool foreground) {
	return engineos_terminal_theme_resolve(theme, value, foreground);
}

static uint32_t next_codepoint(const uint8_t *text, size_t length,
		size_t *offset) {
	uint8_t first = text[(*offset)++];
	if (first < 0x80) return first;
	uint32_t value;
	int extra;
	if ((first & 0xe0) == 0xc0) { value = first & 0x1f; extra = 1; }
	else if ((first & 0xf0) == 0xe0) { value = first & 0x0f; extra = 2; }
	else if ((first & 0xf8) == 0xf0) { value = first & 0x07; extra = 3; }
	else return 0xfffd;
	while (extra-- > 0) {
		if (*offset >= length || (text[*offset] & 0xc0) != 0x80) return 0xfffd;
		value = value << 6 | (text[(*offset)++] & 0x3f);
	}
	return value;
}

static void fill_rect(uint8_t *pixels, int image_width, int image_height,
		int x, int y, int width, int height, uint32_t colour) {
	int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
	int x1 = x + width > image_width ? image_width : x + width;
	int y1 = y + height > image_height ? image_height : y + height;
	for (int py = y0; py < y1; py++) for (int px = x0; px < x1; px++) {
		uint8_t *pixel = pixels + ((size_t)py * image_width + px) * 4;
		pixel[0] = colour >> 16; pixel[1] = colour >> 8;
		pixel[2] = colour; pixel[3] = 0xff;
	}
}

static bool ensure_fcft(char *error, size_t error_size) {
	static bool initialized;
	if (initialized) return true;
	if (!fcft_init(FCFT_LOG_COLORIZE_NEVER, false, FCFT_LOG_CLASS_ERROR)) {
		snprintf(error, error_size, "failed to initialize fcft");
		return false;
	}
	initialized = true;
	return true;
}

static struct fcft_font *create_terminal_font(
		enum engineos_terminal_font_style style,
		char *error, size_t error_size) {
	if (!ensure_fcft(error, error_size)) return NULL;
	const char *primary = style == ENGINEOS_TERMINAL_FONT_BOLD ?
		"monospace:style=Bold:pixelsize=16" :
		style == ENGINEOS_TERMINAL_FONT_ITALIC ?
		"monospace:style=Italic:pixelsize=16" :
		style == ENGINEOS_TERMINAL_FONT_BOLD_ITALIC ?
		"monospace:style=Bold Italic:pixelsize=16" :
		"monospace:pixelsize=16";
	const char *names[] = {
		primary,
		"Symbols Nerd Font Mono:pixelsize=16",
		"Noto Sans Mono CJK SC:pixelsize=16",
		"Noto Color Emoji:pixelsize=16",
	};
	struct fcft_font *font = fcft_from_name(
		sizeof(names) / sizeof(names[0]), names, NULL);
	if (font == NULL)
		snprintf(error, error_size, "failed to load terminal font through fcft");
	return font;
}

static bool create_terminal_fonts(
		struct fcft_font *fonts[ENGINEOS_TERMINAL_FONT_COUNT],
		char *error, size_t error_size) {
	for (size_t index = 0; index < ENGINEOS_TERMINAL_FONT_COUNT; index++) {
		fonts[index] = create_terminal_font(
			(enum engineos_terminal_font_style)index, error, error_size);
		if (fonts[index] == NULL) {
			for (size_t cleanup = 0; cleanup < index; cleanup++) {
				fcft_destroy(fonts[cleanup]);
				fonts[cleanup] = NULL;
			}
			return false;
		}
	}
	return true;
}

static void destroy_terminal_fonts(
		struct fcft_font *fonts[ENGINEOS_TERMINAL_FONT_COUNT]) {
	for (size_t index = 0; index < ENGINEOS_TERMINAL_FONT_COUNT; index++)
		if (fonts[index] != NULL) {
			fcft_destroy(fonts[index]);
			fonts[index] = NULL;
		}
}

static bool blink_visible_now(void) {
	struct timespec now = {0};
	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((now.tv_sec * 2 + now.tv_nsec / 500000000L) & 1) == 0;
}

static void terminal_font_metrics(struct fcft_font *font, int *cell_width,
		int *cell_height, int *baseline) {
	/* fcft's max_advance includes explicit wide fallback fonts. Canonical tmux
	 * columns must instead follow the primary monospace advance; wide glyphs
	 * are drawn into the atlas's existing two-cell slots. */
	const struct fcft_glyph *primary = fcft_rasterize_char_utf32(font, 'M',
		FCFT_SUBPIXEL_NONE);
	*cell_width = primary != NULL && primary->advance.x > 0 ?
		primary->advance.x : 9;
	*cell_height = font->height + 2;
	if (*cell_height < 1) *cell_height = 18;
	if (baseline != NULL) *baseline = font->ascent + 1;
}

static pixman_image_t *solid_colour(uint32_t colour) {
	pixman_color_t value = {
		.red = (uint16_t)(((colour >> 16) & 0xff) * 0x101),
		.green = (uint16_t)(((colour >> 8) & 0xff) * 0x101),
		.blue = (uint16_t)((colour & 0xff) * 0x101),
		.alpha = 0xffff,
	};
	return pixman_image_create_solid_fill(&value);
}

static void composite_glyph(pixman_image_t *target,
		const struct fcft_glyph *glyph, int x, int y, uint32_t colour) {
	if (glyph == NULL || glyph->pix == NULL || glyph->width <= 0 ||
			glyph->height <= 0) return;
	if (glyph->is_color_glyph) {
		pixman_image_composite32(PIXMAN_OP_OVER, glyph->pix, NULL, target,
			0, 0, 0, 0, x + glyph->x, y - glyph->y,
			glyph->width, glyph->height);
		return;
	}
	pixman_image_t *source = solid_colour(colour);
	if (source == NULL) return;
	pixman_image_composite32(PIXMAN_OP_OVER, source, glyph->pix, target,
		0, 0, 0, 0, x + glyph->x, y - glyph->y,
		glyph->width, glyph->height);
	pixman_image_unref(source);
}

static void blend_glyph(uint8_t *pixels, int image_width, int image_height,
		const struct fcft_glyph *glyph, int x, int baseline_y,
		uint32_t colour) {
	pixman_image_t *target = pixman_image_create_bits(PIXMAN_a8b8g8r8,
		image_width, image_height, (uint32_t *)pixels, image_width * 4);
	if (target == NULL) return;
	composite_glyph(target, glyph, x, baseline_y, colour);
	pixman_image_unref(target);
}

static void cpu_draw_decorations(uint8_t *pixels, int image_width,
		int image_height, int x, int y, int width, int height,
		const struct engineos_terminal_cell_style *style) {
	if (!style->draw_foreground) return;
	if (style->overline)
		fill_rect(pixels, image_width, image_height, x, y + 1,
			width, 1, style->decoration);
	if (style->strikeout)
		fill_rect(pixels, image_width, image_height, x,
			y + height / 2, width, 1, style->decoration);
	int underline_y = y + height - 2;
	switch (style->underline) {
	case ENGINEOS_TERMINAL_UNDERLINE_SINGLE:
		fill_rect(pixels, image_width, image_height, x, underline_y,
			width, 1, style->decoration);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DOUBLE:
		fill_rect(pixels, image_width, image_height, x, underline_y - 2,
			width, 1, style->decoration);
		fill_rect(pixels, image_width, image_height, x, underline_y,
			width, 1, style->decoration);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_CURLY:
		for (int dx = 0; dx < width; dx++)
			fill_rect(pixels, image_width, image_height, x + dx,
				underline_y - (dx & 1), 1, 1, style->decoration);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DOTTED:
		for (int dx = 0; dx < width; dx += 2)
			fill_rect(pixels, image_width, image_height, x + dx,
				underline_y, 1, 1, style->decoration);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DASHED:
		for (int dx = 0; dx < width; dx += 4)
			fill_rect(pixels, image_width, image_height, x + dx,
				underline_y, dx + 2 <= width ? 2 : 1, 1,
				style->decoration);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_NONE:
		break;
	}
}

static const struct engineos_mux_ui_span *ui_span_at(
		const struct engineos_mux_ui_row *row, uint32_t column) {
	for (size_t index = 0; index < row->span_count; index++) {
		if (column >= row->spans[index].start &&
				column < row->spans[index].end) return &row->spans[index];
	}
	return NULL;
}

static void render_ui_rows(uint8_t *pixels, int image_width, int image_height,
		struct fcft_font *fonts[ENGINEOS_TERMINAL_FONT_COUNT],
		int cell_width, int cell_height, int baseline,
		const struct engineos_terminal_theme *theme,
		const struct engineos_mux_ui_row *rows, size_t row_count,
		uint32_t columns, uint32_t origin_x, uint32_t origin_y,
		uint32_t *glyph_cells) {
	for (size_t row_index = 0; row_index < row_count; row_index++) {
		const struct engineos_mux_ui_row *row = &rows[row_index];
		for (size_t span_index = 0; span_index < row->span_count; span_index++) {
			const struct engineos_mux_ui_span *span = &row->spans[span_index];
			struct engineos_terminal_cell_style style;
			engineos_terminal_style_decode(theme, span->attributes,
				span->foreground, span->background,
				span->underline_colour, blink_visible_now(), &style);
			fill_rect(pixels, image_width, image_height,
				(int)(origin_x + span->start) * cell_width,
				(int)(origin_y + row_index) * cell_height,
				(int)(span->end - span->start) * cell_width,
				cell_height, style.background);
			cpu_draw_decorations(pixels, image_width, image_height,
				(int)(origin_x + span->start) * cell_width,
				(int)(origin_y + row_index) * cell_height,
				(int)(span->end - span->start) * cell_width,
				cell_height, &style);
		}
		size_t offset = 0, length = strlen(row->text);
		uint32_t column = 0;
		while (offset < length && column < columns) {
			uint32_t codepoint = next_codepoint((const uint8_t *)row->text,
				length, &offset);
			int advance = wcwidth((wchar_t)codepoint);
			if (advance < 0) advance = 1;
			uint32_t glyph_column = advance == 0 && column != 0 ? column - 1 : column;
			const struct engineos_mux_ui_span *span = ui_span_at(row, glyph_column);
			struct engineos_terminal_cell_style style;
			engineos_terminal_style_decode(theme,
				span != NULL ? span->attributes : 0,
				span != NULL ? span->foreground : 8,
				span != NULL ? span->background : 9,
				span != NULL ? span->underline_colour : 8,
				blink_visible_now(), &style);
			const struct fcft_glyph *glyph = codepoint == 0 || codepoint == ' ' ?
				NULL : fcft_rasterize_char_utf32(fonts[style.font], codepoint,
					FCFT_SUBPIXEL_NONE);
			if (glyph != NULL && style.draw_foreground) {
				blend_glyph(pixels, image_width, image_height, glyph,
					(int)(origin_x + glyph_column) * cell_width,
					(int)(origin_y + row_index) * cell_height + baseline,
					style.foreground);
				(*glyph_cells)++;
			}
			if (advance > 0) column += (uint32_t)advance;
		}
	}
}

bool engineos_terminal_cell_metrics(int *cell_width, int *cell_height,
		char *error, size_t error_size) {
	if (cell_width == NULL || cell_height == NULL) {
		snprintf(error, error_size, "terminal cell metric output is missing");
		return false;
	}
	struct fcft_font *font = create_terminal_font(
		ENGINEOS_TERMINAL_FONT_REGULAR, error, error_size);
	if (font == NULL) return false;
	terminal_font_metrics(font, cell_width, cell_height, NULL);
	fcft_destroy(font);
	return true;
}

struct wlr_buffer *engineos_terminal_render(
		const struct engineos_mux_client *client,
		const struct engineos_terminal_theme *theme, int *width, int *height,
		uint32_t *glyph_cells, char *error, size_t error_size) {
	struct fcft_font *fonts[ENGINEOS_TERMINAL_FONT_COUNT] = {0};
	if (!create_terminal_fonts(fonts, error, error_size)) return NULL;
	int cell_width, cell_height, baseline;
	terminal_font_metrics(fonts[ENGINEOS_TERMINAL_FONT_REGULAR],
		&cell_width, &cell_height, &baseline);
	uint32_t render_columns = client->grid_columns;
	uint32_t render_rows = client->grid_rows;
	if (client->ui_columns > render_columns) render_columns = client->ui_columns;
	if (client->ui_rows > render_rows) render_rows = client->ui_rows;
	*width = (int)render_columns * cell_width;
	*height = (int)render_rows * cell_height;
	if (*width <= 0 || *height <= 0 || *width > 4096 || *height > 4096 ||
			(int64_t)*width * *height > 16777216) {
		snprintf(error, error_size, "terminal render target is too large");
		destroy_terminal_fonts(fonts); return NULL;
	}
	uint8_t *pixels = calloc((size_t)*width * *height, 4);
	if (pixels == NULL) {
		snprintf(error, error_size, "out of memory");
		destroy_terminal_fonts(fonts);
		return NULL;
	}
	*glyph_cells = 0;
	for (uint32_t y = 0; y < client->grid_rows; y++) for (uint32_t x = 0; x < client->grid_columns; x++) {
		const struct engine_mux_grid_cell *cell = &client->grid_cells[(size_t)y * client->grid_columns + x];
		struct engineos_terminal_cell_style style;
		engineos_terminal_style_decode(theme, ntohs(cell->attributes),
			(int32_t)ntohl(cell->foreground),
			(int32_t)ntohl(cell->background),
			(int32_t)ntohl(cell->underline_colour),
			blink_visible_now(), &style);
		fill_rect(pixels, *width, *height, (int)x * cell_width,
			(int)y * cell_height, cell_width, cell_height, style.background);
		cpu_draw_decorations(pixels, *width, *height,
			(int)x * cell_width, (int)y * cell_height,
			cell_width, cell_height, &style);
		if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0) continue;
		size_t offset = 0; bool drew = false;
		while (offset < cell->text_length) {
			uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
			if (codepoint == 0 || codepoint == ' ') continue;
			const struct fcft_glyph *glyph =
				fcft_rasterize_char_utf32(fonts[style.font],
				codepoint, FCFT_SUBPIXEL_NONE);
			if (glyph == NULL || !style.draw_foreground) continue;
			blend_glyph(pixels, *width, *height, glyph,
				(int)x * cell_width, (int)y * cell_height + baseline,
				style.foreground);
			drew = true;
		}
		if (drew) (*glyph_cells)++;
	}
	if (client->ui_status_y >= 0 && client->ui_status_row_count != 0) {
		render_ui_rows(pixels, *width, *height, fonts, cell_width, cell_height,
			baseline, theme, client->ui_status_rows,
			client->ui_status_row_count,
			client->ui_columns, 0, (uint32_t)client->ui_status_y, glyph_cells);
	}
	if (client->ui_menu_active && client->ui_menu_row_count != 0) {
		render_ui_rows(pixels, *width, *height, fonts, cell_width, cell_height,
			baseline, theme, client->ui_menu_rows, client->ui_menu_row_count,
			client->ui_menu_width, client->ui_menu_x, client->ui_menu_y,
			glyph_cells);
	}
	destroy_terminal_fonts(fonts);
	struct wlr_buffer *buffer = engineos_pixel_buffer_create(pixels, *width, *height);
	if (buffer == NULL) { free(pixels); snprintf(error, error_size, "failed to create terminal buffer"); }
	return buffer;
}

#define ATLAS_MAX_WIDTH 2048
#define ATLAS_MAX_HEIGHT 4096

struct engineos_atlas_entry {
	uint32_t codepoint;
	uint32_t colour;
	enum engineos_terminal_font_style font;
};

struct engineos_terminal_renderer {
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct engineos_terminal_theme theme;
	bool theme_changed;
	struct wlr_buffer *buffer;
	struct wlr_buffer *gpu_buffers[2];
	struct wlr_texture *gpu_buffer_textures[2];
	struct wlr_drm_syncobj_timeline *timeline;
	uint64_t timeline_point;
	uint64_t gpu_buffer_points[2];
	unsigned int gpu_buffer_index;
	struct wlr_texture *atlas;
	struct fcft_font *fonts[ENGINEOS_TERMINAL_FONT_COUNT];
	struct engineos_atlas_entry *entries;
	size_t entry_count;
	size_t entry_capacity;
	int cell_width;
	int cell_height;
	int baseline;
	int slot_width;
	int atlas_width;
	int atlas_height;
	uint32_t cursor_x;
	uint32_t cursor_y;
	bool cursor_visible;
	bool blink_phase;
	bool contains_blink;
	bool gpu;
	char mode[32];
	pixman_region32_t damage;
	struct engineos_terminal_render_stats stats;
};

static bool client_contains_blink(const struct engineos_mux_client *client) {
	for (uint32_t y = 0; y < client->grid_rows; y++)
		for (uint32_t x = 0; x < client->grid_columns; x++)
			if (ntohs(client->grid_cells[
					(size_t)y * client->grid_columns + x].attributes) &
					ENGINEOS_GRID_ATTR_BLINK)
				return true;
	for (size_t row = 0; row < client->ui_status_row_count; row++)
		for (size_t span = 0;
				span < client->ui_status_rows[row].span_count; span++)
			if (client->ui_status_rows[row].spans[span].attributes &
					ENGINEOS_GRID_ATTR_BLINK)
				return true;
	for (size_t row = 0; row < client->ui_menu_row_count; row++)
		for (size_t span = 0;
				span < client->ui_menu_rows[row].span_count; span++)
			if (client->ui_menu_rows[row].spans[span].attributes &
					ENGINEOS_GRID_ATTR_BLINK)
				return true;
	return false;
}

static bool terminal_dimensions(const struct engineos_mux_client *client,
		int cell_width, int cell_height, int *width, int *height,
		char *error, size_t error_size) {
	uint32_t columns = client->grid_columns;
	uint32_t rows = client->grid_rows;
	if (client->ui_columns > columns) columns = client->ui_columns;
	if (client->ui_rows > rows) rows = client->ui_rows;
	if (columns == 0 || rows == 0 || columns > INT32_MAX / (uint32_t)cell_width ||
			rows > INT32_MAX / (uint32_t)cell_height) {
		snprintf(error, error_size, "terminal render dimensions are invalid");
		return false;
	}
	*width = (int)columns * cell_width;
	*height = (int)rows * cell_height;
	if (*width > 4096 || *height > 4096 ||
			(int64_t)*width * *height > 16777216) {
		snprintf(error, error_size, "terminal render target is too large");
		return false;
	}
	return true;
}

static ssize_t atlas_find(const struct engineos_terminal_renderer *terminal,
		uint32_t codepoint, uint32_t colour,
		enum engineos_terminal_font_style font) {
	for (size_t index = 0; index < terminal->entry_count; index++) {
		if (terminal->entries[index].codepoint == codepoint &&
				terminal->entries[index].colour == colour &&
				terminal->entries[index].font == font)
			return (ssize_t)index;
	}
	return -1;
}

static bool atlas_require(struct engineos_terminal_renderer *terminal,
		uint32_t codepoint, uint32_t colour,
		enum engineos_terminal_font_style font, bool *changed,
		char *error, size_t error_size) {
	if (codepoint == 0 || codepoint == ' ') return true;
	if (atlas_find(terminal, codepoint, colour, font) >= 0) return true;
	if (terminal->entry_count == terminal->entry_capacity) {
		size_t capacity = terminal->entry_capacity == 0 ? 64 :
			terminal->entry_capacity * 2;
		struct engineos_atlas_entry *entries = realloc(terminal->entries,
			capacity * sizeof(*entries));
		if (entries == NULL) {
			snprintf(error, error_size, "out of memory growing glyph atlas");
			return false;
		}
		terminal->entries = entries;
		terminal->entry_capacity = capacity;
	}
	terminal->entries[terminal->entry_count++] =
		(struct engineos_atlas_entry){
			.codepoint = codepoint, .colour = colour, .font = font};
	*changed = true;
	return true;
}

static bool atlas_require_grid_cell(struct engineos_terminal_renderer *terminal,
		const struct engine_mux_grid_cell *cell, bool *changed,
		char *error, size_t error_size) {
	if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0)
		return true;
	struct engineos_terminal_cell_style style;
	engineos_terminal_style_decode(&terminal->theme,
		ntohs(cell->attributes), (int32_t)ntohl(cell->foreground),
		(int32_t)ntohl(cell->background),
		(int32_t)ntohl(cell->underline_colour),
		blink_visible_now(), &style);
	if (!style.draw_foreground) return true;
	size_t offset = 0;
	while (offset < cell->text_length) {
		uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
		if (!atlas_require(terminal, codepoint, style.foreground, style.font,
				changed,
				error, error_size)) return false;
	}
	return true;
}

static bool atlas_require_ui_row(struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_ui_row *row, bool *changed,
		char *error, size_t error_size) {
	size_t offset = 0, length = strlen(row->text);
	uint32_t column = 0;
	while (offset < length) {
		uint32_t codepoint = next_codepoint((const uint8_t *)row->text,
			length, &offset);
		int advance = wcwidth((wchar_t)codepoint);
		if (advance < 0) advance = 1;
		uint32_t glyph_column = advance == 0 && column != 0 ? column - 1 : column;
		const struct engineos_mux_ui_span *span = ui_span_at(row, glyph_column);
		struct engineos_terminal_cell_style style;
		engineos_terminal_style_decode(&terminal->theme,
			span != NULL ? span->attributes : 0,
			span != NULL ? span->foreground : 8,
			span != NULL ? span->background : 9,
			span != NULL ? span->underline_colour : 8,
			blink_visible_now(), &style);
		if (style.draw_foreground && !atlas_require(terminal, codepoint,
				style.foreground, style.font, changed,
				error, error_size))
			return false;
		if (advance > 0) column += (uint32_t)advance;
	}
	return true;
}

static bool atlas_require_client(struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_client *client, const bool *mask, bool full,
		bool *changed, char *error, size_t error_size) {
	for (uint32_t y = 0; y < client->grid_rows; y++) {
		for (uint32_t x = 0; x < client->grid_columns; x++) {
			size_t index = (size_t)y * client->grid_columns + x;
			if (!full && mask != NULL && !mask[index]) continue;
			if (!atlas_require_grid_cell(terminal, &client->grid_cells[index],
					changed, error, error_size)) return false;
		}
	}
	for (size_t index = 0; index < client->ui_status_row_count; index++) {
		if (!atlas_require_ui_row(terminal, &client->ui_status_rows[index],
				changed, error, error_size)) return false;
	}
	for (size_t index = 0; index < client->ui_menu_row_count; index++) {
		if (!atlas_require_ui_row(terminal, &client->ui_menu_rows[index],
				changed, error, error_size)) return false;
	}
	return true;
}

static bool atlas_rebuild(struct engineos_terminal_renderer *terminal,
		char *error, size_t error_size) {
	int columns = ATLAS_MAX_WIDTH / terminal->slot_width;
	if (columns < 1) columns = 1;
	int rows = terminal->entry_count == 0 ? 1 :
		(int)((terminal->entry_count + (size_t)columns - 1) / (size_t)columns);
	terminal->atlas_width = columns * terminal->slot_width;
	terminal->atlas_height = rows * terminal->cell_height;
	if (terminal->atlas_height > ATLAS_MAX_HEIGHT) {
		snprintf(error, error_size, "glyph atlas exceeded %dx%d",
			ATLAS_MAX_WIDTH, ATLAS_MAX_HEIGHT);
		return false;
	}
	size_t stride = (size_t)terminal->atlas_width * 4;
	uint8_t *pixels = calloc(stride * (size_t)terminal->atlas_height, 1);
	if (pixels == NULL) {
		snprintf(error, error_size, "out of memory building glyph atlas");
		return false;
	}
	pixman_image_t *target = pixman_image_create_bits(PIXMAN_a8b8g8r8,
		terminal->atlas_width, terminal->atlas_height, (uint32_t *)pixels,
		(int)stride);
	if (target == NULL) {
		free(pixels);
		snprintf(error, error_size, "failed to create fcft glyph atlas image");
		return false;
	}
	for (size_t index = 0; index < terminal->entry_count; index++) {
		struct engineos_atlas_entry *entry = &terminal->entries[index];
		const struct fcft_glyph *glyph = fcft_rasterize_char_utf32(
			terminal->fonts[entry->font], entry->codepoint,
			FCFT_SUBPIXEL_NONE);
		if (glyph == NULL) continue;
		int slot_x = (int)(index % (size_t)columns) * terminal->slot_width;
		int slot_y = (int)(index / (size_t)columns) * terminal->cell_height;
		pixman_region32_t clip;
		pixman_region32_init_rect(&clip, slot_x, slot_y,
			(uint32_t)terminal->slot_width, (uint32_t)terminal->cell_height);
		pixman_image_set_clip_region32(target, &clip);
		composite_glyph(target, glyph, slot_x, slot_y + terminal->baseline,
			entry->colour);
		pixman_region32_fini(&clip);
	}
	pixman_image_unref(target);
	struct wlr_texture *atlas = wlr_texture_from_pixels(terminal->renderer,
		DRM_FORMAT_ABGR8888, (uint32_t)stride,
		(uint32_t)terminal->atlas_width, (uint32_t)terminal->atlas_height,
		pixels);
	free(pixels);
	if (atlas == NULL) {
		snprintf(error, error_size, "failed to upload GPU glyph atlas");
		return false;
	}
	if (terminal->atlas != NULL) wlr_texture_destroy(terminal->atlas);
	terminal->atlas = atlas;
	return true;
}

static struct wlr_render_color render_colour(uint32_t colour, float alpha) {
	return (struct wlr_render_color){
		.r = (float)((colour >> 16) & 255) / 255.0f * alpha,
		.g = (float)((colour >> 8) & 255) / 255.0f * alpha,
		.b = (float)(colour & 255) / 255.0f * alpha,
		.a = alpha,
	};
}

static void pass_rect(struct wlr_render_pass *pass, int x, int y,
		int width, int height, uint32_t colour, float alpha,
		const pixman_region32_t *clip) {
	struct wlr_render_rect_options options = {
		.box = {.x = x, .y = y, .width = width, .height = height},
		.color = render_colour(colour, alpha),
		.clip = clip,
		/* Alpha-zero is a render-target clear, not a source-over draw. Blending a
		 * transparent source preserves the destination and leaves closed menus
		 * visible in the compositor UI overlay. */
		.blend_mode = (alpha == 0.0f || alpha == 1.0f) ?
			WLR_RENDER_BLEND_MODE_NONE :
			WLR_RENDER_BLEND_MODE_PREMULTIPLIED,
	};
	wlr_render_pass_add_rect(pass, &options);
}

static void pass_glyph(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, size_t entry_index, int x, int y,
		const pixman_region32_t *clip) {
	int columns = terminal->atlas_width / terminal->slot_width;
	struct wlr_render_texture_options options = {
		.texture = terminal->atlas,
		.src_box = {
			.x = (double)(entry_index % (size_t)columns) * terminal->slot_width,
			.y = (double)(entry_index / (size_t)columns) * terminal->cell_height,
			.width = terminal->slot_width,
			.height = terminal->cell_height,
		},
		.dst_box = {.x = x, .y = y, .width = terminal->slot_width,
			.height = terminal->cell_height},
		.clip = clip,
		.transform = WL_OUTPUT_TRANSFORM_NORMAL,
		.filter_mode = WLR_SCALE_FILTER_NEAREST,
		.blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED,
	};
	wlr_render_pass_add_texture(pass, &options);
}

static void pass_decorations(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, int x, int y, int width,
		const struct engineos_terminal_cell_style *style,
		const pixman_region32_t *clip) {
	if (!style->draw_foreground) return;
	if (style->overline)
		pass_rect(pass, x, y + 1, width, 1, style->decoration,
			1.0f, clip);
	if (style->strikeout)
		pass_rect(pass, x, y + terminal->cell_height / 2, width, 1,
			style->decoration, 1.0f, clip);
	int underline_y = y + terminal->cell_height - 2;
	switch (style->underline) {
	case ENGINEOS_TERMINAL_UNDERLINE_SINGLE:
		pass_rect(pass, x, underline_y, width, 1, style->decoration,
			1.0f, clip);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DOUBLE:
		pass_rect(pass, x, underline_y - 2, width, 1, style->decoration,
			1.0f, clip);
		pass_rect(pass, x, underline_y, width, 1, style->decoration,
			1.0f, clip);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_CURLY:
		for (int dx = 0; dx < width; dx++)
			pass_rect(pass, x + dx, underline_y - (dx & 1), 1, 1,
				style->decoration, 1.0f, clip);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DOTTED:
		for (int dx = 0; dx < width; dx += 2)
			pass_rect(pass, x + dx, underline_y, 1, 1,
				style->decoration, 1.0f, clip);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_DASHED:
		for (int dx = 0; dx < width; dx += 4)
			pass_rect(pass, x + dx, underline_y,
				dx + 2 <= width ? 2 : 1, 1,
				style->decoration, 1.0f, clip);
		break;
	case ENGINEOS_TERMINAL_UNDERLINE_NONE:
		break;
	}
}

static void pass_grid_background(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, const struct engine_mux_grid_cell *cell,
		uint32_t x, uint32_t y) {
	struct engineos_terminal_cell_style style;
	engineos_terminal_style_decode(&terminal->theme,
		ntohs(cell->attributes), (int32_t)ntohl(cell->foreground),
		(int32_t)ntohl(cell->background),
		(int32_t)ntohl(cell->underline_colour),
		blink_visible_now(), &style);
	pass_rect(pass, (int)x * terminal->cell_width,
		(int)y * terminal->cell_height, terminal->cell_width,
		terminal->cell_height, style.background, 1.0f, NULL);
	pass_decorations(terminal, pass, (int)x * terminal->cell_width,
		(int)y * terminal->cell_height, terminal->cell_width,
		&style, NULL);
}

static void pass_grid_glyph(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, const struct engine_mux_grid_cell *cell,
		uint32_t x, uint32_t y) {
	if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0)
		return;
	struct engineos_terminal_cell_style style;
	engineos_terminal_style_decode(&terminal->theme,
		ntohs(cell->attributes), (int32_t)ntohl(cell->foreground),
		(int32_t)ntohl(cell->background),
		(int32_t)ntohl(cell->underline_colour),
		blink_visible_now(), &style);
	if (!style.draw_foreground) return;
	size_t offset = 0;
	while (offset < cell->text_length) {
		uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
		ssize_t entry = atlas_find(terminal, codepoint, style.foreground,
			style.font);
		if (entry >= 0) pass_glyph(terminal, pass, (size_t)entry,
			(int)x * terminal->cell_width, (int)y * terminal->cell_height, NULL);
	}
}

static void pass_ui_rows(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, const struct engineos_mux_ui_row *rows,
		size_t row_count, uint32_t origin_x, uint32_t origin_y,
		const pixman_region32_t *clip) {
	for (size_t row_index = 0; row_index < row_count; row_index++) {
		const struct engineos_mux_ui_row *row = &rows[row_index];
		for (size_t span_index = 0; span_index < row->span_count; span_index++) {
			const struct engineos_mux_ui_span *span = &row->spans[span_index];
			struct engineos_terminal_cell_style style;
			engineos_terminal_style_decode(&terminal->theme,
				span->attributes, span->foreground, span->background,
				span->underline_colour, blink_visible_now(), &style);
			pass_rect(pass, (int)(origin_x + span->start) * terminal->cell_width,
				(int)(origin_y + row_index) * terminal->cell_height,
				(int)(span->end - span->start) * terminal->cell_width,
				terminal->cell_height,
				style.background,
				1.0f, clip);
			pass_decorations(terminal, pass,
				(int)(origin_x + span->start) * terminal->cell_width,
				(int)(origin_y + row_index) * terminal->cell_height,
				(int)(span->end - span->start) * terminal->cell_width,
				&style, clip);
		}
	}
	for (size_t row_index = 0; row_index < row_count; row_index++) {
		const struct engineos_mux_ui_row *row = &rows[row_index];
		size_t offset = 0, length = strlen(row->text);
		uint32_t column = 0;
		while (offset < length) {
			uint32_t codepoint = next_codepoint((const uint8_t *)row->text,
				length, &offset);
			int advance = wcwidth((wchar_t)codepoint);
			if (advance < 0) advance = 1;
			uint32_t glyph_column = advance == 0 && column != 0 ? column - 1 : column;
			const struct engineos_mux_ui_span *span = ui_span_at(row, glyph_column);
			struct engineos_terminal_cell_style style;
			engineos_terminal_style_decode(&terminal->theme,
				span != NULL ? span->attributes : 0,
				span != NULL ? span->foreground : 8,
				span != NULL ? span->background : 9,
				span != NULL ? span->underline_colour : 8,
				blink_visible_now(), &style);
			ssize_t entry = atlas_find(terminal, codepoint,
				style.foreground, style.font);
			if (entry >= 0 && style.draw_foreground)
				pass_glyph(terminal, pass, (size_t)entry,
				(int)(origin_x + glyph_column) * terminal->cell_width,
				(int)(origin_y + row_index) * terminal->cell_height, clip);
			if (advance > 0) column += (uint32_t)advance;
		}
	}
}

static const struct wlr_drm_format *terminal_buffer_format(
		struct engineos_terminal_renderer *terminal) {
	const struct wlr_drm_format_set *formats = wlr_renderer_get_texture_formats(
		terminal->renderer, terminal->allocator->buffer_caps);
	if (formats == NULL) return NULL;
	const uint32_t preferred[] = {
		/* UI renderers share this allocator path with pane renderers. Prefer
		 * alpha-capable targets so status, prompt, and menu cells can overlay
		 * pane scenes without an opaque full-output background. Pane cells are
		 * still explicitly rendered opaque. */
		DRM_FORMAT_ARGB8888, DRM_FORMAT_ABGR8888,
		DRM_FORMAT_XRGB8888, DRM_FORMAT_XBGR8888,
	};
	for (size_t index = 0; index < sizeof(preferred) / sizeof(preferred[0]); index++) {
		const struct wlr_drm_format *format =
			wlr_drm_format_set_get(formats, preferred[index]);
		if (format != NULL) return format;
	}
	return NULL;
}

static bool terminal_allocate_buffers(struct engineos_terminal_renderer *terminal,
		int width, int height, char *error, size_t error_size) {
	const struct wlr_drm_format *format = terminal_buffer_format(terminal);
	if (format == NULL) {
		snprintf(error, error_size, "renderer has no terminal render-target format");
		return false;
	}
	struct wlr_buffer *buffers[2] = {NULL, NULL};
	struct wlr_texture *textures[2] = {NULL, NULL};
	for (size_t index = 0; index < 2; index++) {
		buffers[index] = wlr_allocator_create_buffer(terminal->allocator,
			width, height, format);
		if (buffers[index] != NULL)
			textures[index] = wlr_texture_from_buffer(terminal->renderer,
				buffers[index]);
		if (buffers[index] == NULL || textures[index] == NULL) {
			for (size_t cleanup = 0; cleanup < 2; cleanup++) {
				if (textures[cleanup] != NULL)
					wlr_texture_destroy(textures[cleanup]);
				if (buffers[cleanup] != NULL) wlr_buffer_drop(buffers[cleanup]);
			}
			snprintf(error, error_size,
				"failed to allocate GPU terminal render targets");
			return false;
		}
	}
	for (size_t index = 0; index < 2; index++) {
		if (terminal->gpu_buffer_textures[index] != NULL)
			wlr_texture_destroy(terminal->gpu_buffer_textures[index]);
		if (terminal->gpu_buffers[index] != NULL)
			wlr_buffer_drop(terminal->gpu_buffers[index]);
		terminal->gpu_buffers[index] = buffers[index];
		terminal->gpu_buffer_textures[index] = textures[index];
		terminal->gpu_buffer_points[index] = 0;
	}
	terminal->gpu_buffer_index = 0;
	if (terminal->gpu_buffers[0] == NULL) {
		snprintf(error, error_size, "failed to allocate GPU terminal render target");
		return false;
	}
	return true;
}

static void pass_copy_target(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, unsigned int source, int width, int height) {
	struct wlr_render_texture_options options = {
		.texture = terminal->gpu_buffer_textures[source],
		.dst_box = {.x = 0, .y = 0, .width = width, .height = height},
		.transform = WL_OUTPUT_TRANSFORM_NORMAL,
		.filter_mode = WLR_SCALE_FILTER_NEAREST,
		.blend_mode = WLR_RENDER_BLEND_MODE_NONE,
		.wait_timeline = terminal->gpu_buffer_points[source] != 0 ?
			terminal->timeline : NULL,
		.wait_point = terminal->gpu_buffer_points[source],
	};
	wlr_render_pass_add_texture(pass, &options);
}

static void mark_cell(bool *mask, uint32_t columns, uint32_t rows,
		uint32_t x, uint32_t y) {
	if (x >= columns || y >= rows) return;
	mask[(size_t)y * columns + x] = true;
	if (x > 0) mask[(size_t)y * columns + x - 1] = true;
	if (x + 1 < columns) mask[(size_t)y * columns + x + 1] = true;
}

static bool readback_nonblank_pixels(struct engineos_terminal_renderer *terminal,
		unsigned int index, int width, int height, uint32_t *nonblank,
		char *error, size_t error_size) {
	size_t stride = (size_t)width * 4;
	uint8_t *pixels = malloc(stride * (size_t)height);
	if (pixels == NULL) {
		snprintf(error, error_size, "out of memory reading GPU terminal target");
		return false;
	}
	struct wlr_texture_read_pixels_options options = {
		.data = pixels,
		.format = DRM_FORMAT_ABGR8888,
		.stride = (uint32_t)stride,
	};
	if (!wlr_texture_read_pixels(terminal->gpu_buffer_textures[index], &options)) {
		free(pixels);
		snprintf(error, error_size, "failed to read GPU terminal target");
		return false;
	}
	uint32_t background = palette_colour(&terminal->theme, 9, false);
	*nonblank = 0;
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *pixel = pixels + (size_t)y * stride + (size_t)x * 4;
			uint32_t colour = (uint32_t)pixel[0] << 16 |
				(uint32_t)pixel[1] << 8 | pixel[2];
			if (colour != background) (*nonblank)++;
		}
	}
	free(pixels);
	return true;
}

static bool gpu_update(struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_client *client, char *error, size_t error_size) {
	int width, height;
	if (!terminal_dimensions(client, terminal->cell_width, terminal->cell_height,
			&width, &height, error, error_size)) return false;
	bool blink_phase = blink_visible_now();
	bool contains_blink = client_contains_blink(client);
	bool blink_changed = (terminal->contains_blink || contains_blink) &&
		terminal->blink_phase != blink_phase;
	bool full = terminal->gpu_buffers[0] == NULL || terminal->theme_changed ||
		blink_changed ||
		client->grid_full_damage || client->ui_changed ||
		width != terminal->stats.width ||
		height != terminal->stats.height;
	bool reallocated = terminal->gpu_buffers[0] == NULL ||
		width != terminal->stats.width || height != terminal->stats.height;
	if (reallocated) {
		if (!terminal_allocate_buffers(terminal, width, height, error, error_size))
			return false;
	}
	size_t cell_count = (size_t)client->grid_columns * client->grid_rows;
	bool *mask = full ? NULL : calloc(cell_count, sizeof(*mask));
	if (!full && mask == NULL && cell_count != 0) {
		snprintf(error, error_size, "out of memory tracking terminal damage");
		return false;
	}
	if (!full) {
		for (size_t index = 0; index < client->grid_damage_count; index++) {
			mark_cell(mask, client->grid_columns, client->grid_rows,
				client->grid_damage_cells[index].x,
				client->grid_damage_cells[index].y);
		}
		if (terminal->cursor_visible) mark_cell(mask, client->grid_columns,
			client->grid_rows, terminal->cursor_x, terminal->cursor_y);
		if (client->grid_flags & ENGINE_MUX_GRID_CURSOR_VISIBLE)
			mark_cell(mask, client->grid_columns, client->grid_rows,
				client->grid_cursor_x, client->grid_cursor_y);
	}
	if (terminal->theme_changed) {
		if (terminal->atlas != NULL) {
			wlr_texture_destroy(terminal->atlas);
			terminal->atlas = NULL;
		}
		free(terminal->entries);
		terminal->entries = NULL;
		terminal->entry_count = 0;
		terminal->entry_capacity = 0;
	}
	bool atlas_changed = false;
	if (!atlas_require_client(terminal, client, mask, full, &atlas_changed,
			error, error_size)) {
		free(mask);
		return false;
	}
	if ((terminal->atlas == NULL || atlas_changed) &&
			!atlas_rebuild(terminal, error, error_size)) {
		free(mask);
		return false;
	}
	pixman_region32_clear(&terminal->damage);
	uint32_t damaged_cells = 0;
	if (full) {
		pixman_region32_union_rect(&terminal->damage, &terminal->damage,
			0, 0, (uint32_t)width, (uint32_t)height);
		damaged_cells = (uint32_t)cell_count;
	} else {
		for (uint32_t y = 0; y < client->grid_rows; y++) {
			for (uint32_t x = 0; x < client->grid_columns; x++) {
				if (!mask[(size_t)y * client->grid_columns + x]) continue;
				pixman_region32_union_rect(&terminal->damage, &terminal->damage,
					x * (uint32_t)terminal->cell_width,
					y * (uint32_t)terminal->cell_height,
					(uint32_t)terminal->cell_width,
					(uint32_t)terminal->cell_height);
				damaged_cells++;
			}
		}
	}
	if (!full && damaged_cells == 0) {
		free(mask);
		return true;
	}
	unsigned int source = terminal->gpu_buffer_index;
	unsigned int destination = reallocated ? 0 : 1 - source;
	struct wlr_buffer_pass_options pass_options = {0};
	const struct wlr_buffer_pass_options *pass_options_ptr = NULL;
	uint64_t signal_point = 0;
	if (terminal->timeline != NULL) {
		signal_point = ++terminal->timeline_point;
		pass_options.signal_timeline = terminal->timeline;
		pass_options.signal_point = signal_point;
		pass_options_ptr = &pass_options;
	}
	struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(
		terminal->renderer, terminal->gpu_buffers[destination], pass_options_ptr);
	if (pass == NULL) {
		free(mask);
		snprintf(error, error_size, "failed to begin GPU terminal render pass");
		return false;
	}
	if (full) {
		bool ui_overlay = client->grid_columns == 0 && client->grid_rows == 0;
		pass_rect(pass, 0, 0, width, height,
			ui_overlay ? 0 : palette_colour(&terminal->theme, 9, false),
			ui_overlay ? 0.0f : 1.0f, NULL);
	}
	else
		pass_copy_target(terminal, pass, source, width, height);
	for (uint32_t y = 0; y < client->grid_rows; y++) {
		for (uint32_t x = 0; x < client->grid_columns; x++) {
			size_t index = (size_t)y * client->grid_columns + x;
			if (!full && !mask[index]) continue;
			pass_grid_background(terminal, pass, &client->grid_cells[index], x, y);
		}
	}
	for (uint32_t y = 0; y < client->grid_rows; y++) {
		for (uint32_t x = 0; x < client->grid_columns; x++) {
			size_t index = (size_t)y * client->grid_columns + x;
			if (!full && !mask[index]) continue;
			pass_grid_glyph(terminal, pass, &client->grid_cells[index], x, y);
		}
	}
	if ((client->grid_flags & ENGINE_MUX_GRID_CURSOR_VISIBLE) &&
			client->grid_cursor_x < client->grid_columns &&
			client->grid_cursor_y < client->grid_rows) {
		pass_rect(pass, (int)client->grid_cursor_x * terminal->cell_width,
			(int)client->grid_cursor_y * terminal->cell_height,
			terminal->cell_width, terminal->cell_height,
			terminal->theme.foreground, 0.35f, NULL);
	}
	const pixman_region32_t *clip = full ? NULL : &terminal->damage;
	if (client->ui_status_y >= 0 && client->ui_status_row_count != 0) {
		pass_ui_rows(terminal, pass, client->ui_status_rows,
			client->ui_status_row_count, 0, (uint32_t)client->ui_status_y, clip);
	}
	if (client->ui_menu_active && client->ui_menu_row_count != 0) {
		pass_ui_rows(terminal, pass, client->ui_menu_rows,
			client->ui_menu_row_count, client->ui_menu_x, client->ui_menu_y, clip);
	}
	if (!wlr_render_pass_submit(pass)) {
		free(mask);
		snprintf(error, error_size, "GPU terminal render pass failed");
		return false;
	}
	free(mask);
	if (terminal->stats.frame == 0 &&
			!readback_nonblank_pixels(terminal, destination, width, height,
				&terminal->stats.nonblank_pixels, error, error_size)) return false;
	terminal->gpu_buffer_index = destination;
	terminal->gpu_buffer_points[destination] = signal_point;
	terminal->cursor_x = client->grid_cursor_x;
	terminal->cursor_y = client->grid_cursor_y;
	terminal->cursor_visible =
		(client->grid_flags & ENGINE_MUX_GRID_CURSOR_VISIBLE) != 0;
	terminal->blink_phase = blink_phase;
	terminal->contains_blink = contains_blink;
	terminal->stats.width = width;
	terminal->stats.height = height;
	terminal->stats.glyph_cells = client->grid_nonblank_cells;
	terminal->stats.atlas_entries = (uint32_t)terminal->entry_count;
	terminal->stats.damaged_cells = damaged_cells;
	terminal->stats.frame++;
	terminal->theme_changed = false;
	return true;
}

static bool cpu_update(struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_client *client, char *error, size_t error_size) {
	int width = 0, height = 0;
	uint32_t glyph_cells = 0;
	struct wlr_buffer *buffer = engineos_terminal_render(client,
		&terminal->theme, &width, &height, &glyph_cells, error, error_size);
	if (buffer == NULL) return false;
	if (terminal->buffer != NULL) wlr_buffer_drop(terminal->buffer);
	terminal->buffer = buffer;
	pixman_region32_clear(&terminal->damage);
	pixman_region32_union_rect(&terminal->damage, &terminal->damage,
		0, 0, (uint32_t)width, (uint32_t)height);
	terminal->stats.width = width;
	terminal->stats.height = height;
	terminal->stats.glyph_cells = glyph_cells;
	terminal->stats.atlas_entries = 0;
	terminal->stats.damaged_cells = client->grid_columns * client->grid_rows;
	terminal->stats.frame++;
	terminal->contains_blink = client_contains_blink(client);
	terminal->blink_phase = blink_visible_now();
	terminal->theme_changed = false;
	return true;
}

struct engineos_terminal_renderer *engineos_terminal_renderer_create(
		struct wlr_renderer *renderer, struct wlr_allocator *allocator,
		const struct engineos_mux_client *client,
		const struct engineos_terminal_theme *theme, char *error,
		size_t error_size) {
	struct engineos_terminal_renderer *terminal = calloc(1, sizeof(*terminal));
	if (terminal == NULL) {
		snprintf(error, error_size, "out of memory creating terminal renderer");
		return NULL;
	}
	terminal->renderer = renderer;
	terminal->allocator = allocator;
	if (theme != NULL)
		terminal->theme = *theme;
	else
		engineos_terminal_theme_default(&terminal->theme);
	terminal->theme_changed = true;
	pixman_region32_init(&terminal->damage);
	if (wlr_renderer_is_pixman(renderer)) {
		strcpy(terminal->mode, "cpu-pixman-smoke");
		if (!cpu_update(terminal, client, error, error_size)) goto fail;
		return terminal;
	}
	if (wlr_renderer_is_gles2(renderer))
		strcpy(terminal->mode, "gpu-fcft-atlas-gles2");
	else if (wlr_renderer_is_vk(renderer))
		strcpy(terminal->mode, "gpu-fcft-atlas-vulkan");
	else {
		snprintf(error, error_size, "unsupported terminal renderer backend");
		goto fail;
	}
	terminal->gpu = true;
	if (renderer->features.timeline) {
		int drm_fd = wlr_renderer_get_drm_fd(renderer);
		if (drm_fd < 0 || (terminal->timeline =
				wlr_drm_syncobj_timeline_create(drm_fd)) == NULL) {
			snprintf(error, error_size,
				"failed to create GPU terminal synchronization timeline");
			goto fail;
		}
	}
	if (!create_terminal_fonts(terminal->fonts, error, error_size)) goto fail;
	terminal_font_metrics(
		terminal->fonts[ENGINEOS_TERMINAL_FONT_REGULAR],
		&terminal->cell_width,
		&terminal->cell_height, &terminal->baseline);
	terminal->slot_width = terminal->cell_width * 2;
	if (!gpu_update(terminal, client, error, error_size)) goto fail;
	return terminal;

fail:
	engineos_terminal_renderer_destroy(terminal);
	return NULL;
}

void engineos_terminal_renderer_set_theme(
		struct engineos_terminal_renderer *terminal,
		const struct engineos_terminal_theme *theme) {
	if (terminal == NULL || theme == NULL)
		return;
	terminal->theme = *theme;
	terminal->theme_changed = true;
}

bool engineos_terminal_renderer_update(
		struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_client *client, char *error, size_t error_size) {
	return terminal->gpu ? gpu_update(terminal, client, error, error_size) :
		cpu_update(terminal, client, error, error_size);
}

struct wlr_buffer *engineos_terminal_renderer_buffer(
		const struct engineos_terminal_renderer *terminal) {
	return terminal->gpu ? terminal->gpu_buffers[terminal->gpu_buffer_index] :
		terminal->buffer;
}

struct wlr_drm_syncobj_timeline *engineos_terminal_renderer_wait_timeline(
		const struct engineos_terminal_renderer *terminal) {
	return terminal->gpu ? terminal->timeline : NULL;
}

uint64_t engineos_terminal_renderer_wait_point(
		const struct engineos_terminal_renderer *terminal) {
	return terminal->gpu && terminal->timeline != NULL ?
		terminal->gpu_buffer_points[terminal->gpu_buffer_index] : 0;
}

const pixman_region32_t *engineos_terminal_renderer_damage(
		const struct engineos_terminal_renderer *terminal) {
	return &terminal->damage;
}

const char *engineos_terminal_renderer_mode(
		const struct engineos_terminal_renderer *terminal) {
	return terminal->mode;
}

bool engineos_terminal_renderer_has_blink(
		const struct engineos_terminal_renderer *terminal) {
	return terminal != NULL && terminal->contains_blink;
}

void engineos_terminal_renderer_stats(
		const struct engineos_terminal_renderer *terminal,
		struct engineos_terminal_render_stats *stats) {
	*stats = terminal->stats;
}

void engineos_terminal_renderer_destroy(
		struct engineos_terminal_renderer *terminal) {
	if (terminal == NULL) return;
	if (terminal->atlas != NULL) wlr_texture_destroy(terminal->atlas);
	wlr_drm_syncobj_timeline_unref(terminal->timeline);
	if (terminal->buffer != NULL) wlr_buffer_drop(terminal->buffer);
	for (size_t index = 0; index < 2; index++) {
		if (terminal->gpu_buffer_textures[index] != NULL)
			wlr_texture_destroy(terminal->gpu_buffer_textures[index]);
		if (terminal->gpu_buffers[index] != NULL)
			wlr_buffer_drop(terminal->gpu_buffers[index]);
	}
	destroy_terminal_fonts(terminal->fonts);
	free(terminal->entries);
	pixman_region32_fini(&terminal->damage);
	free(terminal);
}
