#include "engineos-tmux-key.h"

#include <string.h>

#include <wlr/types/wlr_keyboard.h>

size_t engineos_tmux_key_name(xkb_keysym_t sym, uint32_t modifiers,
		char key_name[64]) {
	if (modifiers & WLR_MODIFIER_LOGO)
		return 0;

	const char *special = NULL;
	switch (sym) {
	case XKB_KEY_Return: special = "Enter"; break;
	case XKB_KEY_KP_Enter: special = "KPEnter"; break;
	case XKB_KEY_BackSpace: special = "BSpace"; break;
	case XKB_KEY_Tab: special = "Tab"; break;
	case XKB_KEY_ISO_Left_Tab: special = "BTab"; break;
	case XKB_KEY_Escape: special = "Escape"; break;
	case XKB_KEY_space: special = "Space"; break;
	case XKB_KEY_Up: special = "Up"; break;
	case XKB_KEY_Down: special = "Down"; break;
	case XKB_KEY_Right: special = "Right"; break;
	case XKB_KEY_Left: special = "Left"; break;
	case XKB_KEY_Home: special = "Home"; break;
	case XKB_KEY_End: special = "End"; break;
	case XKB_KEY_Page_Up: special = "PageUp"; break;
	case XKB_KEY_Page_Down: special = "PageDown"; break;
	case XKB_KEY_Insert: special = "Insert"; break;
	case XKB_KEY_Delete: special = "Delete"; break;
	case XKB_KEY_F1: special = "F1"; break;
	case XKB_KEY_F2: special = "F2"; break;
	case XKB_KEY_F3: special = "F3"; break;
	case XKB_KEY_F4: special = "F4"; break;
	case XKB_KEY_F5: special = "F5"; break;
	case XKB_KEY_F6: special = "F6"; break;
	case XKB_KEY_F7: special = "F7"; break;
	case XKB_KEY_F8: special = "F8"; break;
	case XKB_KEY_F9: special = "F9"; break;
	case XKB_KEY_F10: special = "F10"; break;
	case XKB_KEY_F11: special = "F11"; break;
	case XKB_KEY_F12: special = "F12"; break;
	default: break;
	}

	char printable[16] = {0};
	if (special == NULL) {
		int count = xkb_keysym_to_utf8(sym, printable, sizeof(printable));
		if (count <= 0)
			return 0;
		special = printable;
	}

	size_t used = 0;
	if (modifiers & WLR_MODIFIER_CTRL) {
		memcpy(key_name + used, "C-", 2);
		used += 2;
	}
	if (modifiers & WLR_MODIFIER_ALT) {
		memcpy(key_name + used, "M-", 2);
		used += 2;
	}
	if ((modifiers & WLR_MODIFIER_SHIFT) && printable[0] == '\0' &&
			sym != XKB_KEY_ISO_Left_Tab) {
		memcpy(key_name + used, "S-", 2);
		used += 2;
	}

	size_t special_length = strlen(special);
	if (used + special_length >= 64)
		return 0;
	memcpy(key_name + used, special, special_length + 1);
	return used + special_length;
}
