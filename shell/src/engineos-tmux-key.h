#ifndef ENGINEOS_TMUX_KEY_H
#define ENGINEOS_TMUX_KEY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <xkbcommon/xkbcommon.h>

struct wlr_keyboard;

size_t engineos_tmux_key_name(xkb_keysym_t sym, uint32_t modifiers,
	char key_name[64]);

bool engineos_tmux_key_repeats(const struct wlr_keyboard *keyboard,
	uint32_t keycode);

int engineos_tmux_key_repeat_interval_ms(int32_t rate_hz);

#endif
