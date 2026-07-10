#define _XOPEN_SOURCE 700

#include "engineos-terminal-renderer.h"

#include "engineos-image.h"
#include "engineos-mux-client.h"

#include <arpa/inet.h>
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

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
