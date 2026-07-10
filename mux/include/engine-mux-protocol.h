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
	ENGINE_MUX_SERVER_HELLO = 0x8001,
	ENGINE_MUX_SNAPSHOT = 0x8002,
	ENGINE_MUX_ERROR = 0xffff,
};

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
