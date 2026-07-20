#include "engineos-terminal-style.h"

#include "engineos-terminal-theme.h"

static uint32_t blend(uint32_t foreground, uint32_t background) {
	uint32_t red = (((foreground >> 16) & 255) +
		((background >> 16) & 255)) / 2;
	uint32_t green = (((foreground >> 8) & 255) +
		((background >> 8) & 255)) / 2;
	uint32_t blue = ((foreground & 255) + (background & 255)) / 2;
	return red << 16 | green << 8 | blue;
}

void engineos_terminal_style_decode(
		const struct engineos_terminal_theme *theme,
		uint16_t attributes, int32_t foreground, int32_t background,
		int32_t underline_colour, bool blink_visible,
		struct engineos_terminal_cell_style *style) {
	style->foreground =
		engineos_terminal_theme_resolve(theme, foreground, true);
	style->background =
		engineos_terminal_theme_resolve(theme, background, false);
	if (attributes & ENGINEOS_GRID_ATTR_REVERSE) {
		uint32_t swap = style->foreground;
		style->foreground = style->background;
		style->background = swap;
	}
	if (attributes & ENGINEOS_GRID_ATTR_DIM)
		style->foreground = blend(style->foreground, style->background);
	style->decoration = underline_colour == 8 || underline_colour == 9 ?
		style->foreground :
		engineos_terminal_theme_resolve(theme, underline_colour, true);
	bool bold = (attributes & ENGINEOS_GRID_ATTR_BRIGHT) != 0;
	bool italic = (attributes & ENGINEOS_GRID_ATTR_ITALICS) != 0;
	style->font = bold && italic ? ENGINEOS_TERMINAL_FONT_BOLD_ITALIC :
		bold ? ENGINEOS_TERMINAL_FONT_BOLD :
		italic ? ENGINEOS_TERMINAL_FONT_ITALIC :
		ENGINEOS_TERMINAL_FONT_REGULAR;
	style->underline =
		attributes & ENGINEOS_GRID_ATTR_UNDERSCORE_2 ?
			ENGINEOS_TERMINAL_UNDERLINE_DOUBLE :
		attributes & ENGINEOS_GRID_ATTR_UNDERSCORE_3 ?
			ENGINEOS_TERMINAL_UNDERLINE_CURLY :
		attributes & ENGINEOS_GRID_ATTR_UNDERSCORE_4 ?
			ENGINEOS_TERMINAL_UNDERLINE_DOTTED :
		attributes & ENGINEOS_GRID_ATTR_UNDERSCORE_5 ?
			ENGINEOS_TERMINAL_UNDERLINE_DASHED :
		attributes & ENGINEOS_GRID_ATTR_UNDERSCORE ?
			ENGINEOS_TERMINAL_UNDERLINE_SINGLE :
			ENGINEOS_TERMINAL_UNDERLINE_NONE;
	style->strikeout =
		(attributes & ENGINEOS_GRID_ATTR_STRIKETHROUGH) != 0;
	style->overline = (attributes & ENGINEOS_GRID_ATTR_OVERLINE) != 0;
	style->blink = (attributes & ENGINEOS_GRID_ATTR_BLINK) != 0;
	style->draw_foreground =
		(attributes & ENGINEOS_GRID_ATTR_HIDDEN) == 0 &&
		(!style->blink || blink_visible);
}
