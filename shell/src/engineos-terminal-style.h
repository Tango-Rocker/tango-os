#ifndef ENGINEOS_TERMINAL_STYLE_H
#define ENGINEOS_TERMINAL_STYLE_H

#include <stdbool.h>
#include <stdint.h>

struct engineos_terminal_theme;

#define ENGINEOS_GRID_ATTR_BRIGHT 0x0001
#define ENGINEOS_GRID_ATTR_DIM 0x0002
#define ENGINEOS_GRID_ATTR_UNDERSCORE 0x0004
#define ENGINEOS_GRID_ATTR_BLINK 0x0008
#define ENGINEOS_GRID_ATTR_REVERSE 0x0010
#define ENGINEOS_GRID_ATTR_HIDDEN 0x0020
#define ENGINEOS_GRID_ATTR_ITALICS 0x0040
#define ENGINEOS_GRID_ATTR_CHARSET 0x0080
#define ENGINEOS_GRID_ATTR_STRIKETHROUGH 0x0100
#define ENGINEOS_GRID_ATTR_UNDERSCORE_2 0x0200
#define ENGINEOS_GRID_ATTR_UNDERSCORE_3 0x0400
#define ENGINEOS_GRID_ATTR_UNDERSCORE_4 0x0800
#define ENGINEOS_GRID_ATTR_UNDERSCORE_5 0x1000
#define ENGINEOS_GRID_ATTR_OVERLINE 0x2000

enum engineos_terminal_font_style {
	ENGINEOS_TERMINAL_FONT_REGULAR,
	ENGINEOS_TERMINAL_FONT_BOLD,
	ENGINEOS_TERMINAL_FONT_ITALIC,
	ENGINEOS_TERMINAL_FONT_BOLD_ITALIC,
	ENGINEOS_TERMINAL_FONT_COUNT,
};

enum engineos_terminal_underline_style {
	ENGINEOS_TERMINAL_UNDERLINE_NONE,
	ENGINEOS_TERMINAL_UNDERLINE_SINGLE,
	ENGINEOS_TERMINAL_UNDERLINE_DOUBLE,
	ENGINEOS_TERMINAL_UNDERLINE_CURLY,
	ENGINEOS_TERMINAL_UNDERLINE_DOTTED,
	ENGINEOS_TERMINAL_UNDERLINE_DASHED,
};

struct engineos_terminal_cell_style {
	uint32_t foreground;
	uint32_t background;
	uint32_t decoration;
	enum engineos_terminal_font_style font;
	enum engineos_terminal_underline_style underline;
	bool draw_foreground;
	bool strikeout;
	bool overline;
	bool blink;
};

void engineos_terminal_style_decode(
	const struct engineos_terminal_theme *theme,
	uint16_t attributes, int32_t foreground, int32_t background,
	int32_t underline_colour, bool blink_visible,
	struct engineos_terminal_cell_style *style);

#endif
