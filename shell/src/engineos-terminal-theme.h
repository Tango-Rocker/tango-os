#ifndef ENGINEOS_TERMINAL_THEME_H
#define ENGINEOS_TERMINAL_THEME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct json_object;

#define ENGINEOS_TERMINAL_THEME_COLOR_COUNT 16
#define ENGINEOS_TERMINAL_THEME_NAME_SIZE 64

struct engineos_terminal_theme {
	char name[ENGINEOS_TERMINAL_THEME_NAME_SIZE];
	uint32_t foreground;
	uint32_t background;
	uint32_t colors[ENGINEOS_TERMINAL_THEME_COLOR_COUNT];
	uint64_t generation;
};

void engineos_terminal_theme_default(struct engineos_terminal_theme *theme);

bool engineos_terminal_theme_parse(struct engineos_terminal_theme *theme,
	struct json_object *object, char *error, size_t error_size);

uint32_t engineos_terminal_theme_resolve(
	const struct engineos_terminal_theme *theme, int value, bool foreground);

#endif
