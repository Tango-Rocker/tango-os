#define _XOPEN_SOURCE 700

#include "engineos-terminal-renderer.h"

#include "engineos-image.h"
#include "engineos-mux-client.h"

#include <arpa/inet.h>
#include <drm_fourcc.h>
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/render/gles2.h>
#include <wlr/render/pass.h>
#include <wlr/render/pixman.h>
#include <wlr/render/vulkan.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>

#define COLOUR_FLAG_256 0x01000000
#define COLOUR_FLAG_RGB 0x02000000
#define GRID_ATTR_REVERSE 0x10

static uint32_t palette_colour(int value, bool foreground) {
	static const uint32_t palette[16] = {
		0x1d1f21, 0xcc342b, 0x198844, 0xfba922,
		0x3971ed, 0xa36ac7, 0x3971ed, 0xc5c8c6,
		0x969896, 0xcc342b, 0x198844, 0xfba922,
		0x3971ed, 0xa36ac7, 0x3971ed, 0xffffff,
	};
	if (value & COLOUR_FLAG_RGB) return (uint32_t)value & 0xffffff;
	int index = value & 0xff;
	if (value & COLOUR_FLAG_256) {
		if (index < 16) return palette[index];
		if (index < 232) {
			index -= 16;
			int r = index / 36, g = index / 6 % 6, b = index % 6;
			return (uint32_t)((r ? r * 40 + 55 : 0) << 16 |
				(g ? g * 40 + 55 : 0) << 8 | (b ? b * 40 + 55 : 0));
		}
		int gray = 8 + (index - 232) * 10;
		return (uint32_t)(gray << 16 | gray << 8 | gray);
	}
	if (index == 8 || index == 9) return foreground ? 0xd8dee9 : 0x101419;
	return palette[index & 15];
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

static void blend_bitmap(uint8_t *pixels, int image_width, int image_height,
		FT_Bitmap *bitmap, int x, int y, uint32_t colour) {
	for (unsigned int by = 0; by < bitmap->rows; by++) {
		int py = y + (int)by;
		if (py < 0 || py >= image_height) continue;
		for (unsigned int bx = 0; bx < bitmap->width; bx++) {
			int px = x + (int)bx;
			if (px < 0 || px >= image_width) continue;
			uint8_t alpha = bitmap->buffer[by * bitmap->pitch + bx];
			uint8_t *pixel = pixels + ((size_t)py * image_width + px) * 4;
			pixel[0] = (uint8_t)((pixel[0] * (255 - alpha) + (colour >> 16) * alpha) / 255);
			pixel[1] = (uint8_t)((pixel[1] * (255 - alpha) + ((colour >> 8) & 255) * alpha) / 255);
			pixel[2] = (uint8_t)((pixel[2] * (255 - alpha) + (colour & 255) * alpha) / 255);
		}
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
		FT_Face face, int cell_width, int cell_height, int baseline,
		const struct engineos_mux_ui_row *rows, size_t row_count,
		uint32_t columns, uint32_t origin_x, uint32_t origin_y,
		uint32_t *glyph_cells) {
	for (size_t row_index = 0; row_index < row_count; row_index++) {
		const struct engineos_mux_ui_row *row = &rows[row_index];
		for (size_t span_index = 0; span_index < row->span_count; span_index++) {
			const struct engineos_mux_ui_span *span = &row->spans[span_index];
			uint32_t background = palette_colour(span->background, false);
			fill_rect(pixels, image_width, image_height,
				(int)(origin_x + span->start) * cell_width,
				(int)(origin_y + row_index) * cell_height,
				(int)(span->end - span->start) * cell_width,
				cell_height, background);
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
			int32_t foreground = span != NULL ? span->foreground : 8;
			int32_t background = span != NULL ? span->background : 9;
			if (span != NULL && (span->attributes & GRID_ATTR_REVERSE)) {
				int32_t swap = foreground; foreground = background; background = swap;
			}
			if (codepoint != 0 && codepoint != ' ' &&
					FT_Load_Char(face, codepoint, FT_LOAD_RENDER) == 0) {
				blend_bitmap(pixels, image_width, image_height,
					&face->glyph->bitmap,
					(int)(origin_x + glyph_column) * cell_width +
						face->glyph->bitmap_left,
					(int)(origin_y + row_index) * cell_height + baseline -
						face->glyph->bitmap_top,
					palette_colour(foreground, true));
				(*glyph_cells)++;
			}
			if (advance > 0) column += (uint32_t)advance;
		}
	}
}

struct wlr_buffer *engineos_terminal_render(
		const struct engineos_mux_client *client, int *width, int *height,
		uint32_t *glyph_cells, char *error, size_t error_size) {
	FcPattern *pattern = FcNameParse((const FcChar8 *)"monospace");
	FcConfigSubstitute(NULL, pattern, FcMatchPattern);
	FcDefaultSubstitute(pattern);
	FcResult match_result;
	FcPattern *match = FcFontMatch(NULL, pattern, &match_result);
	FcChar8 *font_path = NULL;
	if (match == NULL || FcPatternGetString(match, FC_FILE, 0, &font_path) != FcResultMatch) {
		snprintf(error, error_size, "no monospace font found");
		if (match != NULL) FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		return NULL;
	}
	FT_Library library;
	FT_Face face;
	if (FT_Init_FreeType(&library) != 0) {
		snprintf(error, error_size, "failed to initialize terminal font");
		FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		return NULL;
	}
	if (FT_New_Face(library, (const char *)font_path, 0, &face) != 0) {
		snprintf(error, error_size, "failed to initialize terminal font");
		FT_Done_FreeType(library);
		FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		return NULL;
	}
	if (FT_Set_Pixel_Sizes(face, 0, 16) != 0) {
		snprintf(error, error_size, "failed to size terminal font");
		FT_Done_Face(face);
		FT_Done_FreeType(library);
		FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		return NULL;
	}
	int cell_width = (int)(face->size->metrics.max_advance >> 6);
	int cell_height = (int)(face->size->metrics.height >> 6) + 2;
	int baseline = (int)(face->size->metrics.ascender >> 6) + 1;
	if (cell_width < 1) cell_width = 9;
	if (cell_height < 1) cell_height = 18;
	uint32_t render_columns = client->grid_columns;
	uint32_t render_rows = client->grid_rows;
	if (client->ui_columns > render_columns) render_columns = client->ui_columns;
	if (client->ui_rows > render_rows) render_rows = client->ui_rows;
	*width = (int)render_columns * cell_width;
	*height = (int)render_rows * cell_height;
	if (*width <= 0 || *height <= 0 || *width > 4096 || *height > 4096 ||
			(int64_t)*width * *height > 16777216) {
		snprintf(error, error_size, "terminal render target is too large");
		FT_Done_Face(face); FT_Done_FreeType(library);
		FcPatternDestroy(match); FcPatternDestroy(pattern); return NULL;
	}
	uint8_t *pixels = calloc((size_t)*width * *height, 4);
	if (pixels == NULL) {
		snprintf(error, error_size, "out of memory");
		FT_Done_Face(face);
		FT_Done_FreeType(library);
		FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		return NULL;
	}
	*glyph_cells = 0;
	for (uint32_t y = 0; y < client->grid_rows; y++) for (uint32_t x = 0; x < client->grid_columns; x++) {
		const struct engine_mux_grid_cell *cell = &client->grid_cells[(size_t)y * client->grid_columns + x];
		int fg_value = (int32_t)ntohl(cell->foreground), bg_value = (int32_t)ntohl(cell->background);
		if (ntohs(cell->attributes) & GRID_ATTR_REVERSE) { int swap = fg_value; fg_value = bg_value; bg_value = swap; }
		uint32_t fg = palette_colour(fg_value, true), bg = palette_colour(bg_value, false);
		fill_rect(pixels, *width, *height, (int)x * cell_width, (int)y * cell_height, cell_width, cell_height, bg);
		if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0) continue;
		size_t offset = 0; bool drew = false;
		while (offset < cell->text_length) {
			uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
			if (codepoint == 0 || codepoint == ' ') continue;
			if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER) != 0) continue;
			blend_bitmap(pixels, *width, *height, &face->glyph->bitmap,
				(int)x * cell_width + face->glyph->bitmap_left,
				(int)y * cell_height + baseline - face->glyph->bitmap_top, fg);
			drew = true;
		}
		if (drew) (*glyph_cells)++;
	}
	if (client->ui_status_y >= 0 && client->ui_status_row_count != 0) {
		render_ui_rows(pixels, *width, *height, face, cell_width, cell_height,
			baseline, client->ui_status_rows, client->ui_status_row_count,
			client->ui_columns, 0, (uint32_t)client->ui_status_y, glyph_cells);
	}
	if (client->ui_menu_active && client->ui_menu_row_count != 0) {
		render_ui_rows(pixels, *width, *height, face, cell_width, cell_height,
			baseline, client->ui_menu_rows, client->ui_menu_row_count,
			client->ui_menu_width, client->ui_menu_x, client->ui_menu_y,
			glyph_cells);
	}
	FT_Done_Face(face); FT_Done_FreeType(library);
	FcPatternDestroy(match); FcPatternDestroy(pattern);
	struct wlr_buffer *buffer = engineos_pixel_buffer_create(pixels, *width, *height);
	if (buffer == NULL) { free(pixels); snprintf(error, error_size, "failed to create terminal buffer"); }
	return buffer;
}

#define ATLAS_MAX_WIDTH 2048
#define ATLAS_MAX_HEIGHT 4096

struct engineos_atlas_entry {
	uint32_t codepoint;
	uint32_t colour;
};

struct engineos_terminal_renderer {
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_buffer *buffer;
	struct wlr_buffer *gpu_buffers[2];
	struct wlr_texture *gpu_buffer_textures[2];
	unsigned int gpu_buffer_index;
	struct wlr_texture *atlas;
	FT_Library library;
	FT_Face face;
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
	bool gpu;
	char mode[32];
	pixman_region32_t damage;
	struct engineos_terminal_render_stats stats;
};

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
		uint32_t codepoint, uint32_t colour) {
	for (size_t index = 0; index < terminal->entry_count; index++) {
		if (terminal->entries[index].codepoint == codepoint &&
				terminal->entries[index].colour == colour) return (ssize_t)index;
	}
	return -1;
}

static bool atlas_require(struct engineos_terminal_renderer *terminal,
		uint32_t codepoint, uint32_t colour, bool *changed,
		char *error, size_t error_size) {
	if (codepoint == 0 || codepoint == ' ') return true;
	if (atlas_find(terminal, codepoint, colour) >= 0) return true;
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
		(struct engineos_atlas_entry){.codepoint = codepoint, .colour = colour};
	*changed = true;
	return true;
}

static bool atlas_require_grid_cell(struct engineos_terminal_renderer *terminal,
		const struct engine_mux_grid_cell *cell, bool *changed,
		char *error, size_t error_size) {
	if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0)
		return true;
	int32_t foreground = (int32_t)ntohl(cell->foreground);
	int32_t background = (int32_t)ntohl(cell->background);
	if (ntohs(cell->attributes) & GRID_ATTR_REVERSE) {
		int32_t swap = foreground; foreground = background; background = swap;
	}
	uint32_t colour = palette_colour(foreground, true);
	size_t offset = 0;
	while (offset < cell->text_length) {
		uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
		if (!atlas_require(terminal, codepoint, colour, changed,
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
		int32_t foreground = span != NULL ? span->foreground : 8;
		int32_t background = span != NULL ? span->background : 9;
		if (span != NULL && (span->attributes & GRID_ATTR_REVERSE)) {
			int32_t swap = foreground; foreground = background; background = swap;
		}
		if (!atlas_require(terminal, codepoint,
				palette_colour(foreground, true), changed, error, error_size))
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
	for (size_t index = 0; index < terminal->entry_count; index++) {
		struct engineos_atlas_entry *entry = &terminal->entries[index];
		if (FT_Load_Char(terminal->face, entry->codepoint, FT_LOAD_RENDER) != 0)
			continue;
		FT_Bitmap *bitmap = &terminal->face->glyph->bitmap;
		int slot_x = (int)(index % (size_t)columns) * terminal->slot_width;
		int slot_y = (int)(index / (size_t)columns) * terminal->cell_height;
		int glyph_x = slot_x + terminal->face->glyph->bitmap_left;
		int glyph_y = slot_y + terminal->baseline - terminal->face->glyph->bitmap_top;
		for (unsigned int by = 0; by < bitmap->rows; by++) {
			int y = glyph_y + (int)by;
			if (y < slot_y || y >= slot_y + terminal->cell_height) continue;
			const uint8_t *bitmap_row = bitmap->pitch >= 0 ?
				bitmap->buffer + (size_t)by * (size_t)bitmap->pitch :
				bitmap->buffer + (size_t)(bitmap->rows - 1 - by) *
					(size_t)(-bitmap->pitch);
			for (unsigned int bx = 0; bx < bitmap->width; bx++) {
				int x = glyph_x + (int)bx;
				if (x < slot_x || x >= slot_x + terminal->slot_width) continue;
				uint8_t alpha = bitmap_row[bx];
				uint8_t *pixel = pixels + (size_t)y * stride + (size_t)x * 4;
				pixel[0] = (uint8_t)(((entry->colour >> 16) & 255) * alpha / 255);
				pixel[1] = (uint8_t)(((entry->colour >> 8) & 255) * alpha / 255);
				pixel[2] = (uint8_t)((entry->colour & 255) * alpha / 255);
				pixel[3] = alpha;
			}
		}
	}
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
		.blend_mode = alpha == 1.0f ? WLR_RENDER_BLEND_MODE_NONE :
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

static void pass_grid_background(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, const struct engine_mux_grid_cell *cell,
		uint32_t x, uint32_t y) {
	int32_t foreground = (int32_t)ntohl(cell->foreground);
	int32_t background = (int32_t)ntohl(cell->background);
	if (ntohs(cell->attributes) & GRID_ATTR_REVERSE) {
		int32_t swap = foreground; foreground = background; background = swap;
	}
	pass_rect(pass, (int)x * terminal->cell_width,
		(int)y * terminal->cell_height, terminal->cell_width,
		terminal->cell_height, palette_colour(background, false), 1.0f, NULL);
}

static void pass_grid_glyph(struct engineos_terminal_renderer *terminal,
		struct wlr_render_pass *pass, const struct engine_mux_grid_cell *cell,
		uint32_t x, uint32_t y) {
	if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) || cell->text_length == 0)
		return;
	int32_t foreground = (int32_t)ntohl(cell->foreground);
	int32_t background = (int32_t)ntohl(cell->background);
	if (ntohs(cell->attributes) & GRID_ATTR_REVERSE) {
		int32_t swap = foreground; foreground = background; background = swap;
	}
	uint32_t colour = palette_colour(foreground, true);
	size_t offset = 0;
	while (offset < cell->text_length) {
		uint32_t codepoint = next_codepoint(cell->text, cell->text_length, &offset);
		ssize_t entry = atlas_find(terminal, codepoint, colour);
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
			pass_rect(pass, (int)(origin_x + span->start) * terminal->cell_width,
				(int)(origin_y + row_index) * terminal->cell_height,
				(int)(span->end - span->start) * terminal->cell_width,
				terminal->cell_height, palette_colour(span->background, false),
				1.0f, clip);
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
			int32_t foreground = span != NULL ? span->foreground : 8;
			int32_t background = span != NULL ? span->background : 9;
			if (span != NULL && (span->attributes & GRID_ATTR_REVERSE)) {
				int32_t swap = foreground; foreground = background; background = swap;
			}
			ssize_t entry = atlas_find(terminal, codepoint,
				palette_colour(foreground, true));
			if (entry >= 0) pass_glyph(terminal, pass, (size_t)entry,
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
		DRM_FORMAT_XRGB8888, DRM_FORMAT_XBGR8888,
		DRM_FORMAT_ARGB8888, DRM_FORMAT_ABGR8888,
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
	uint32_t background = palette_colour(9, false);
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
	bool full = terminal->gpu_buffers[0] == NULL || client->grid_full_damage ||
		client->ui_changed || width != terminal->stats.width ||
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
	struct wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(
		terminal->renderer, terminal->gpu_buffers[destination], NULL);
	if (pass == NULL) {
		free(mask);
		snprintf(error, error_size, "failed to begin GPU terminal render pass");
		return false;
	}
	if (full)
		pass_rect(pass, 0, 0, width, height,
			palette_colour(9, false), 1.0f, NULL);
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
			terminal->cell_width, terminal->cell_height, 0xffffff, 0.35f, NULL);
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
	terminal->cursor_x = client->grid_cursor_x;
	terminal->cursor_y = client->grid_cursor_y;
	terminal->cursor_visible =
		(client->grid_flags & ENGINE_MUX_GRID_CURSOR_VISIBLE) != 0;
	terminal->stats.width = width;
	terminal->stats.height = height;
	terminal->stats.glyph_cells = client->grid_nonblank_cells;
	terminal->stats.atlas_entries = (uint32_t)terminal->entry_count;
	terminal->stats.damaged_cells = damaged_cells;
	terminal->stats.frame++;
	return true;
}

static bool cpu_update(struct engineos_terminal_renderer *terminal,
		const struct engineos_mux_client *client, char *error, size_t error_size) {
	int width = 0, height = 0;
	uint32_t glyph_cells = 0;
	struct wlr_buffer *buffer = engineos_terminal_render(client, &width, &height,
		&glyph_cells, error, error_size);
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
	return true;
}

struct engineos_terminal_renderer *engineos_terminal_renderer_create(
		struct wlr_renderer *renderer, struct wlr_allocator *allocator,
		const struct engineos_mux_client *client, char *error, size_t error_size) {
	struct engineos_terminal_renderer *terminal = calloc(1, sizeof(*terminal));
	if (terminal == NULL) {
		snprintf(error, error_size, "out of memory creating terminal renderer");
		return NULL;
	}
	terminal->renderer = renderer;
	terminal->allocator = allocator;
	pixman_region32_init(&terminal->damage);
	if (wlr_renderer_is_pixman(renderer)) {
		strcpy(terminal->mode, "cpu-pixman-smoke");
		if (!cpu_update(terminal, client, error, error_size)) goto fail;
		return terminal;
	}
	if (wlr_renderer_is_gles2(renderer))
		strcpy(terminal->mode, "gpu-glyph-atlas-gles2");
	else if (wlr_renderer_is_vk(renderer))
		strcpy(terminal->mode, "gpu-glyph-atlas-vulkan");
	else {
		snprintf(error, error_size, "unsupported terminal renderer backend");
		goto fail;
	}
	terminal->gpu = true;
	FcPattern *pattern = FcNameParse((const FcChar8 *)"monospace");
	if (pattern == NULL) {
		snprintf(error, error_size, "failed to create terminal font pattern");
		goto fail;
	}
	FcConfigSubstitute(NULL, pattern, FcMatchPattern);
	FcDefaultSubstitute(pattern);
	FcResult match_result;
	FcPattern *match = FcFontMatch(NULL, pattern, &match_result);
	FcChar8 *font_path = NULL;
	if (match == NULL ||
			FcPatternGetString(match, FC_FILE, 0, &font_path) != FcResultMatch) {
		snprintf(error, error_size, "no monospace font found");
		if (match != NULL) FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		goto fail;
	}
	if (FT_Init_FreeType(&terminal->library) != 0 ||
			FT_New_Face(terminal->library, (const char *)font_path, 0,
				&terminal->face) != 0 ||
			FT_Set_Pixel_Sizes(terminal->face, 0, 16) != 0) {
		snprintf(error, error_size, "failed to initialize GPU terminal font");
		FcPatternDestroy(match);
		FcPatternDestroy(pattern);
		goto fail;
	}
	FcPatternDestroy(match);
	FcPatternDestroy(pattern);
	terminal->cell_width = (int)(terminal->face->size->metrics.max_advance >> 6);
	terminal->cell_height = (int)(terminal->face->size->metrics.height >> 6) + 2;
	terminal->baseline = (int)(terminal->face->size->metrics.ascender >> 6) + 1;
	if (terminal->cell_width < 1) terminal->cell_width = 9;
	if (terminal->cell_height < 1) terminal->cell_height = 18;
	terminal->slot_width = terminal->cell_width * 2;
	if (!gpu_update(terminal, client, error, error_size)) goto fail;
	return terminal;

fail:
	engineos_terminal_renderer_destroy(terminal);
	return NULL;
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

const pixman_region32_t *engineos_terminal_renderer_damage(
		const struct engineos_terminal_renderer *terminal) {
	return &terminal->damage;
}

const char *engineos_terminal_renderer_mode(
		const struct engineos_terminal_renderer *terminal) {
	return terminal->mode;
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
	if (terminal->buffer != NULL) wlr_buffer_drop(terminal->buffer);
	for (size_t index = 0; index < 2; index++) {
		if (terminal->gpu_buffer_textures[index] != NULL)
			wlr_texture_destroy(terminal->gpu_buffer_textures[index]);
		if (terminal->gpu_buffers[index] != NULL)
			wlr_buffer_drop(terminal->gpu_buffers[index]);
	}
	if (terminal->face != NULL) FT_Done_Face(terminal->face);
	if (terminal->library != NULL) FT_Done_FreeType(terminal->library);
	free(terminal->entries);
	pixman_region32_fini(&terminal->damage);
	free(terminal);
}
