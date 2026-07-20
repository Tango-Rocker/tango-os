#include "engineos-terminal-theme.h"

#include <ctype.h>
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COLOUR_FLAG_256 0x01000000
#define COLOUR_FLAG_RGB 0x02000000

static bool parse_colour(struct json_object *object, const char *field,
		uint32_t *colour, char *error, size_t error_size) {
	if (object == NULL || !json_object_is_type(object, json_type_string)) {
		snprintf(error, error_size, "terminal theme %s must be a color string",
			field);
		return false;
	}
	const char *value = json_object_get_string(object);
	if (value == NULL || strlen(value) != 7 || value[0] != '#') {
		snprintf(error, error_size,
			"terminal theme %s must use #RRGGBB", field);
		return false;
	}
	for (size_t index = 1; index < 7; index++) {
		if (!isxdigit((unsigned char)value[index])) {
			snprintf(error, error_size,
				"terminal theme %s must use #RRGGBB", field);
			return false;
		}
	}
	*colour = (uint32_t)strtoul(value + 1, NULL, 16);
	return true;
}

static bool valid_name(const char *name) {
	if (name == NULL || name[0] == '\0' ||
			strlen(name) >= ENGINEOS_TERMINAL_THEME_NAME_SIZE)
		return false;
	for (const unsigned char *cursor = (const unsigned char *)name;
			*cursor != '\0'; cursor++) {
		if (!isalnum(*cursor) && *cursor != '-' && *cursor != '_')
			return false;
	}
	return true;
}

void engineos_terminal_theme_default(struct engineos_terminal_theme *theme) {
	static const uint32_t colors[ENGINEOS_TERMINAL_THEME_COLOR_COUNT] = {
		0x282828, 0xcc241d, 0x98971a, 0xd79921,
		0x458588, 0xb16286, 0x689d6a, 0xa89984,
		0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f,
		0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
	};
	memset(theme, 0, sizeof(*theme));
	strcpy(theme->name, "gruvbox-dark");
	theme->foreground = 0xebdbb2;
	theme->background = 0x282828;
	memcpy(theme->colors, colors, sizeof(colors));
	theme->generation = 1;
}

bool engineos_terminal_theme_parse(struct engineos_terminal_theme *theme,
		struct json_object *object, char *error, size_t error_size) {
	if (theme == NULL || object == NULL ||
			!json_object_is_type(object, json_type_object)) {
		snprintf(error, error_size, "terminal theme must be a JSON object");
		return false;
	}
	struct json_object *version_object = NULL;
	if (!json_object_object_get_ex(object, "version", &version_object) ||
			!json_object_is_type(version_object, json_type_int) ||
			json_object_get_int(version_object) != 1) {
		snprintf(error, error_size, "terminal theme version must be 1");
		return false;
	}
	struct json_object *name_object = NULL;
	const char *name = NULL;
	if (!json_object_object_get_ex(object, "name", &name_object) ||
			!json_object_is_type(name_object, json_type_string) ||
			!valid_name(name = json_object_get_string(name_object))) {
		snprintf(error, error_size,
			"terminal theme name must contain only letters, numbers, - or _");
		return false;
	}

	struct engineos_terminal_theme parsed = {0};
	strcpy(parsed.name, name);
	struct json_object *foreground_object = NULL;
	struct json_object *background_object = NULL;
	if (!json_object_object_get_ex(object, "foreground", &foreground_object) ||
			!parse_colour(foreground_object, "foreground", &parsed.foreground,
				error, error_size))
		return false;
	if (!json_object_object_get_ex(object, "background", &background_object) ||
			!parse_colour(background_object, "background", &parsed.background,
				error, error_size))
		return false;

	struct json_object *colors = NULL;
	if (!json_object_object_get_ex(object, "colors", &colors) ||
			!json_object_is_type(colors, json_type_array) ||
			json_object_array_length(colors) !=
				ENGINEOS_TERMINAL_THEME_COLOR_COUNT) {
		snprintf(error, error_size,
			"terminal theme colors must contain exactly 16 entries");
		return false;
	}
	for (size_t index = 0;
			index < ENGINEOS_TERMINAL_THEME_COLOR_COUNT; index++) {
		char field[32];
		snprintf(field, sizeof(field), "colors[%zu]", index);
		if (!parse_colour(json_object_array_get_idx(colors, index), field,
				&parsed.colors[index], error, error_size))
			return false;
	}
	*theme = parsed;
	return true;
}

uint32_t engineos_terminal_theme_resolve(
		const struct engineos_terminal_theme *theme, int value,
		bool foreground) {
	if (value & COLOUR_FLAG_RGB)
		return (uint32_t)value & 0xffffff;
	int index = value & 0xff;
	if (value & COLOUR_FLAG_256) {
		if (index < ENGINEOS_TERMINAL_THEME_COLOR_COUNT)
			return theme->colors[index];
		if (index < 232) {
			index -= 16;
			int red = index / 36;
			int green = index / 6 % 6;
			int blue = index % 6;
			return (uint32_t)(
				(red ? red * 40 + 55 : 0) << 16 |
				(green ? green * 40 + 55 : 0) << 8 |
				(blue ? blue * 40 + 55 : 0));
		}
		int gray = 8 + (index - 232) * 10;
		return (uint32_t)(gray << 16 | gray << 8 | gray);
	}
	if (index == 8 || index == 9)
		return foreground ? theme->foreground : theme->background;
	return theme->colors[index & 15];
}
