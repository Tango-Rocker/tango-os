#ifndef ENGINEOS_TMUX_KEY_H
#define ENGINEOS_TMUX_KEY_H

#include <stddef.h>
#include <stdint.h>

#include <xkbcommon/xkbcommon.h>

size_t engineos_tmux_key_name(xkb_keysym_t sym, uint32_t modifiers,
	char key_name[64]);

#endif
