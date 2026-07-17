#include <stdio.h>
#include <string.h>

#include <wlr/types/wlr_keyboard.h>

#include "engineos-tmux-key.h"

static int expect_key(const char *label, xkb_keysym_t sym, uint32_t modifiers,
		const char *expected) {
	char actual[64] = {0};
	size_t length = engineos_tmux_key_name(sym, modifiers, actual);
	if (length != strlen(expected) || strcmp(actual, expected) != 0) {
		fprintf(stderr, "%s: expected %s, got %s (length %zu)\n",
			label, expected, length == 0 ? "<unsupported>" : actual, length);
		return 1;
	}
	return 0;
}

int main(void) {
	int failed = 0;
	failed |= expect_key("printable", XKB_KEY_c, 0, "c");
	failed |= expect_key("ctrl-c", XKB_KEY_c, WLR_MODIFIER_CTRL, "C-c");
	failed |= expect_key("prefix", XKB_KEY_b, WLR_MODIFIER_CTRL, "C-b");
	failed |= expect_key("alt", XKB_KEY_x, WLR_MODIFIER_ALT, "M-x");
	failed |= expect_key("shifted printable", XKB_KEY_C, WLR_MODIFIER_SHIFT,
		"C");
	failed |= expect_key("shifted special", XKB_KEY_Up, WLR_MODIFIER_SHIFT,
		"S-Up");
	failed |= expect_key("backtab", XKB_KEY_ISO_Left_Tab, WLR_MODIFIER_SHIFT,
		"BTab");
	failed |= expect_key("ctrl-space", XKB_KEY_space, WLR_MODIFIER_CTRL,
		"C-Space");
	failed |= expect_key("unicode", XKB_KEY_udiaeresis, 0, "ü");

	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = context == NULL ? NULL :
		xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (keymap == NULL) {
		fprintf(stderr, "failed to construct XKB keymap for repeat checks\n");
		failed = 1;
	} else {
		struct wlr_keyboard keyboard = {0};
		keyboard.keymap = keymap;
		keyboard.repeat_info.rate = 25;
		failed |= !engineos_tmux_key_repeats(&keyboard, 119); /* evdev Delete + 8 */
		failed |= engineos_tmux_key_repeats(&keyboard, 50); /* evdev Left Shift + 8 */
		keyboard.repeat_info.rate = 0;
		failed |= engineos_tmux_key_repeats(&keyboard, 119);
		failed |= engineos_tmux_key_repeat_interval_ms(25) != 40;
		xkb_keymap_unref(keymap);
	}
	if (context != NULL) xkb_context_unref(context);
	return failed;
}
