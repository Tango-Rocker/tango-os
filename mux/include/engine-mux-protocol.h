#ifndef ENGINE_MUX_PROTOCOL_H
#define ENGINE_MUX_PROTOCOL_H

#include <stdint.h>

#define ENGINE_MUX_MAGIC 0x454d5558u /* EMUX */
#define ENGINE_MUX_PROTOCOL_VERSION 1u
#define ENGINE_MUX_MAX_PAYLOAD (1024u * 1024u)

enum engine_mux_message_type {
	ENGINE_MUX_CLIENT_HELLO = 1,
	ENGINE_MUX_SNAPSHOT_REQUEST = 2,
	ENGINE_MUX_COMMAND_REQUEST = 3,
	ENGINE_MUX_GRID_REQUEST = 4,
	ENGINE_MUX_GRID_DAMAGE_REQUEST = 5,
	ENGINE_MUX_SCROLLBACK_REQUEST = 6,
	ENGINE_MUX_GRID_SUBSCRIBE_REQUEST = 7,
	ENGINE_MUX_SERVER_HELLO = 0x8001,
	ENGINE_MUX_SNAPSHOT = 0x8002,
	ENGINE_MUX_GRID_SNAPSHOT = 0x8003,
	ENGINE_MUX_GRID_DAMAGE = 0x8004,
	ENGINE_MUX_SCROLLBACK = 0x8005,
	ENGINE_MUX_GRID_INVALIDATED = 0x8006,
	ENGINE_MUX_GRID_SUBSCRIBE_ACK = 0x8007,
	ENGINE_MUX_ERROR = 0xffff,
};

#define ENGINE_MUX_GRID_VERSION 1u
#define ENGINE_MUX_GRID_CELL_TEXT_MAX 32u

enum engine_mux_grid_flags {
	ENGINE_MUX_GRID_ALTERNATE = 1u << 0,
	ENGINE_MUX_GRID_CURSOR_VISIBLE = 1u << 1,
};

enum engine_mux_grid_cell_flags {
	ENGINE_MUX_GRID_CELL_PADDING = 1u << 2,
};

struct engine_mux_grid_request {
	uint32_t pane_id;
	uint32_t generation;
} __attribute__((packed));

struct engine_mux_grid_damage_request {
	uint32_t pane_id;
	uint32_t generation;
	uint64_t grid_revision;
} __attribute__((packed));

struct engine_mux_grid_header {
	uint16_t version;
	uint16_t flags;
	uint32_t pane_id;
	uint32_t generation;
	uint64_t grid_revision;
	uint32_t columns;
	uint32_t rows;
	uint32_t cursor_x;
	uint32_t cursor_y;
	uint16_t cursor_style;
	uint16_t reserved;
	uint32_t cursor_colour;
	uint32_t screen_mode;
	uint32_t cell_count;
} __attribute__((packed));

struct engine_mux_grid_cell {
	uint16_t attributes;
	uint8_t flags;
	uint8_t width;
	uint8_t text_length;
	uint8_t reserved[3];
	uint32_t foreground;
	uint32_t background;
	uint32_t underline_colour;
	uint32_t hyperlink;
	uint8_t text[ENGINE_MUX_GRID_CELL_TEXT_MAX];
} __attribute__((packed));

struct engine_mux_grid_damage_header {
	struct engine_mux_grid_header grid;
	uint32_t damage_count;
} __attribute__((packed));

struct engine_mux_grid_damage_cell {
	uint32_t x;
	uint32_t y;
	struct engine_mux_grid_cell cell;
} __attribute__((packed));

struct engine_mux_scrollback_request {
	uint32_t pane_id;
	uint32_t generation;
	uint32_t start_row;
	uint32_t row_count;
} __attribute__((packed));

struct engine_mux_scrollback_header {
	uint16_t version;
	uint16_t reserved;
	uint32_t pane_id;
	uint32_t generation;
	uint32_t columns;
	uint32_t total_rows;
	uint32_t start_row;
	uint32_t row_count;
	uint32_t cell_count;
} __attribute__((packed));

/* All integer fields are encoded in network byte order. */
struct engine_mux_frame_header {
	uint32_t magic;
	uint16_t version;
	uint16_t type;
	uint64_t request_id;
	uint64_t state_revision;
	uint32_t payload_length;
	uint32_t flags;
};

#endif
