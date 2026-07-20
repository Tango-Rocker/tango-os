#include "engineos-terminal-theme.h"

#include <json-c/json.h>
#include <stdio.h>
#include <string.h>

static int expect_colour(const char *label, uint32_t actual,
		uint32_t expected) {
	if (actual == expected) return 0;
	fprintf(stderr, "%s: expected #%06x, got #%06x\n",
		label, expected, actual);
	return 1;
}

int main(void) {
	const char *json =
		"{\"version\":1,\"name\":\"gruvbox-dark\","
		"\"foreground\":\"#ebdbb2\",\"background\":\"#282828\","
		"\"colors\":[\"#282828\",\"#cc241d\",\"#98971a\",\"#d79921\","
		"\"#458588\",\"#b16286\",\"#689d6a\",\"#a89984\","
		"\"#928374\",\"#fb4934\",\"#b8bb26\",\"#fabd2f\","
		"\"#83a598\",\"#d3869b\",\"#8ec07c\",\"#ebdbb2\"]}";
	struct json_object *object = json_tokener_parse(json);
	struct engineos_terminal_theme theme;
	char error[256] = {0};
	engineos_terminal_theme_default(&theme);
	int failed = 0;
	failed |= strcmp(theme.name, "gruvbox-dark") != 0;
	failed |= expect_colour("compiled default background",
		theme.background, 0x282828);
	failed |= expect_colour("compiled default foreground",
		theme.foreground, 0xebdbb2);
	if (object == NULL ||
			!engineos_terminal_theme_parse(&theme, object, error, sizeof(error))) {
		fprintf(stderr, "valid theme rejected: %s\n", error);
		json_object_put(object);
		return 1;
	}
	json_object_put(object);

	failed |= strcmp(theme.name, "gruvbox-dark") != 0;
	failed |= expect_colour("default background",
		engineos_terminal_theme_resolve(&theme, 9, false), 0x282828);
	failed |= expect_colour("default foreground",
		engineos_terminal_theme_resolve(&theme, 8, true), 0xebdbb2);
	failed |= expect_colour("ANSI red",
		engineos_terminal_theme_resolve(&theme, 0x01000001, true), 0xcc241d);
	failed |= expect_colour("bright blue",
		engineos_terminal_theme_resolve(&theme, 0x0100000c, true), 0x83a598);
	failed |= expect_colour("true color",
		engineos_terminal_theme_resolve(&theme, 0x02123456, false), 0x123456);
	failed |= expect_colour("xterm cube",
		engineos_terminal_theme_resolve(&theme, 0x01000015, true), 0x0000ff);

	object = json_tokener_parse(
		"{\"version\":1,\"name\":\"bad/theme\",\"foreground\":\"#ffffff\","
		"\"background\":\"#000000\",\"colors\":[]}");
	memset(error, 0, sizeof(error));
	if (object != NULL &&
			engineos_terminal_theme_parse(&theme, object, error, sizeof(error))) {
		fprintf(stderr, "invalid theme was accepted\n");
		failed = 1;
	}
	json_object_put(object);
	return failed;
}
