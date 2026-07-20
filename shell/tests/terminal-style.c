#include "engineos-terminal-style.h"
#include "engineos-terminal-theme.h"

#include <stdio.h>

int main(void) {
	struct engineos_terminal_theme theme;
	engineos_terminal_theme_default(&theme);
	struct engineos_terminal_cell_style style;
	engineos_terminal_style_decode(&theme,
		ENGINEOS_GRID_ATTR_BRIGHT | ENGINEOS_GRID_ATTR_ITALICS |
		ENGINEOS_GRID_ATTR_UNDERSCORE_2 |
		ENGINEOS_GRID_ATTR_STRIKETHROUGH | ENGINEOS_GRID_ATTR_OVERLINE,
		8, 9, 1, true, &style);
	if (style.font != ENGINEOS_TERMINAL_FONT_BOLD_ITALIC ||
			style.underline != ENGINEOS_TERMINAL_UNDERLINE_DOUBLE ||
			!style.strikeout || !style.overline ||
			!style.draw_foreground)
		return 1;
	engineos_terminal_style_decode(&theme,
		ENGINEOS_GRID_ATTR_HIDDEN | ENGINEOS_GRID_ATTR_BLINK,
		8, 9, 8, false, &style);
	if (style.draw_foreground || !style.blink)
		return 1;
	engineos_terminal_style_decode(&theme, ENGINEOS_GRID_ATTR_REVERSE,
		8, 9, 8, true, &style);
	if (style.foreground != theme.background ||
			style.background != theme.foreground) {
		fprintf(stderr, "reverse colors were not swapped\n");
		return 1;
	}
	return 0;
}
