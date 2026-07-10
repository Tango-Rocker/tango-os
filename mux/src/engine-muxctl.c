#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <json-c/json.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static uint64_t host_to_be64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	return ((uint64_t)htonl((uint32_t)(value >> 32))) |
		((uint64_t)htonl((uint32_t)value) << 32);
#else
	return value;
#endif
}

static uint64_t be64_to_host(uint64_t value) {
	return host_to_be64(value);
}

static char *default_socket_path(void) {
	const char *runtime = getenv("XDG_RUNTIME_DIR");
	if (runtime == NULL || runtime[0] == '\0') {
		return NULL;
	}
	char *path = NULL;
	if (asprintf(&path, "%s/engineos/mux.sock", runtime) < 0) {
		return NULL;
	}
	return path;
}

static int connect_socket(const char *path) {
	int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		return -1;
	}
	struct sockaddr_un address = {.sun_family = AF_UNIX};
	if (strlen(path) >= sizeof(address.sun_path)) {
		close(fd);
		errno = ENAMETOOLONG;
		return -1;
	}
	strcpy(address.sun_path, path);
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static int exchange(int fd, uint16_t type, uint64_t request_id,
		uint64_t revision, const char *payload, uint16_t *response_type,
		uint64_t *response_revision, char **response_payload) {
	size_t payload_length = payload != NULL ? strlen(payload) : 0;
	struct engine_mux_frame_header header = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(type),
		.request_id = host_to_be64(request_id),
		.state_revision = host_to_be64(revision),
		.payload_length = htonl((uint32_t)payload_length),
	};
	struct iovec parts[] = {
		{.iov_base = &header, .iov_len = sizeof(header)},
		{.iov_base = (char *)payload, .iov_len = payload_length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = payload_length > 0 ? 2 : 1};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) {
		return -1;
	}
	unsigned char packet[sizeof(header) + ENGINE_MUX_MAX_PAYLOAD + 1];
	uint32_t length;
	for (;;) {
		ssize_t count = recv(fd, packet, sizeof(packet), 0);
		if (count < (ssize_t)sizeof(header)) {
			errno = EPROTO;
			return -1;
		}
		memcpy(&header, packet, sizeof(header));
		length = ntohl(header.payload_length);
		if (ntohl(header.magic) != ENGINE_MUX_MAGIC ||
				ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION ||
				length > ENGINE_MUX_MAX_PAYLOAD ||
				sizeof(header) + length != (size_t)count) {
			errno = EPROTO;
			return -1;
		}
		if (ntohs(header.type) == ENGINE_MUX_STATE_INVALIDATED && length == 0)
			continue;
		break;
	}
	char *copy = malloc((size_t)length + 1);
	if (copy == NULL) {
		return -1;
	}
	memcpy(copy, packet + sizeof(header), length);
	copy[length] = '\0';
	*response_type = ntohs(header.type);
	*response_revision = be64_to_host(header.state_revision);
	*response_payload = copy;
	return 0;
}

static int request_grid(int fd, uint32_t pane_id) {
	struct engine_mux_grid_request request = {
		.pane_id = htonl(pane_id),
		.generation = htonl(1),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_REQUEST),
		.request_id = host_to_be64(3),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) {
		return -1;
	}
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		return -1;
	}
	ssize_t count = recv(fd, packet, capacity, 0);
	if (count < (ssize_t)(sizeof(frame) + sizeof(struct engine_mux_grid_header))) {
		free(packet);
		errno = EPROTO;
		return -1;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			ntohs(frame.type) != ENGINE_MUX_GRID_SNAPSHOT ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		errno = EPROTO;
		return -1;
	}
	struct engine_mux_grid_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.columns);
	uint32_t rows = ntohl(header.rows);
	uint32_t cell_count = ntohl(header.cell_count);
	if (ntohs(header.version) != ENGINE_MUX_GRID_VERSION ||
			(columns != 0 && rows > UINT32_MAX / columns) ||
			cell_count != columns * rows ||
			payload_length != sizeof(header) +
				(size_t)cell_count * sizeof(struct engine_mux_grid_cell)) {
		free(packet);
		errno = EPROTO;
		return -1;
	}
	const unsigned char *cell_bytes = packet + sizeof(frame) + sizeof(header);
	struct json_object *root = json_object_new_object();
	struct json_object *text_rows = json_object_new_array();
	json_object_object_add(root, "schema", json_object_new_string("engine-mux/grid-v1"));
	json_object_object_add(root, "pane_id", json_object_new_int64(ntohl(header.pane_id)));
	json_object_object_add(root, "generation", json_object_new_int64(ntohl(header.generation)));
	json_object_object_add(root, "grid_revision",
		json_object_new_int64((int64_t)be64_to_host(header.grid_revision)));
	json_object_object_add(root, "columns", json_object_new_int64(columns));
	json_object_object_add(root, "rows", json_object_new_int64(rows));
	json_object_object_add(root, "cursor_x", json_object_new_int64(ntohl(header.cursor_x)));
	json_object_object_add(root, "cursor_y", json_object_new_int64(ntohl(header.cursor_y)));
	json_object_object_add(root, "cursor_style", json_object_new_int(ntohs(header.cursor_style)));
	json_object_object_add(root, "flags", json_object_new_int(ntohs(header.flags)));
	json_object_object_add(root, "cell_count", json_object_new_int64(cell_count));
	uint32_t styled_cells = 0, coloured_cells = 0, wide_cells = 0;
	uint32_t hyperlink_cells = 0;
	for (uint32_t y = 0; y < rows; y++) {
		size_t row_capacity = (size_t)columns * ENGINE_MUX_GRID_CELL_TEXT_MAX + 1;
		char *row_text = malloc(row_capacity);
		if (row_text == NULL) {
			json_object_put(root);
			free(packet);
			return -1;
		}
		size_t used = 0;
		for (uint32_t x = 0; x < columns; x++) {
			struct engine_mux_grid_cell cell;
			memcpy(&cell, cell_bytes, sizeof(cell));
			cell_bytes += sizeof(cell);
			if (cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
				free(row_text);
				json_object_put(root);
				free(packet);
				errno = EPROTO;
				return -1;
			}
			if ((cell.flags & ENGINE_MUX_GRID_CELL_PADDING) == 0) {
				memcpy(row_text + used, cell.text, cell.text_length);
				used += cell.text_length;
			}
			if (ntohs(cell.attributes) != 0) styled_cells++;
			if ((int32_t)ntohl(cell.foreground) != 8 ||
					(int32_t)ntohl(cell.background) != 8) coloured_cells++;
			if (cell.width == 2) wide_cells++;
			if (ntohl(cell.hyperlink) != 0) hyperlink_cells++;
		}
		json_object_array_add(text_rows,
			json_object_new_string_len(row_text, (int)used));
		free(row_text);
	}
	json_object_object_add(root, "text_rows", text_rows);
	json_object_object_add(root, "styled_cells", json_object_new_int64(styled_cells));
	json_object_object_add(root, "coloured_cells", json_object_new_int64(coloured_cells));
	json_object_object_add(root, "wide_cells", json_object_new_int64(wide_cells));
	json_object_object_add(root, "hyperlink_cells", json_object_new_int64(hyperlink_cells));
	printf("%s\n", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY));
	json_object_put(root);
	free(packet);
	return 0;
}

static int request_damage(int fd, uint32_t pane_id, uint64_t grid_revision,
		bool expect_stale) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(pane_id),
		.generation = htonl(1),
		.grid_revision = host_to_be64(grid_revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_DAMAGE_REQUEST),
		.request_id = host_to_be64(4),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) return -1;
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) return -1;
	ssize_t count = recv(fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet); errno = EPROTO; return -1;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	uint16_t response_type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet); errno = EPROTO; return -1;
	}
	if (response_type == ENGINE_MUX_ERROR) {
		char *error_text = malloc((size_t)payload_length + 1);
		if (error_text == NULL) { free(packet); return -1; }
		memcpy(error_text, packet + sizeof(frame), payload_length);
		error_text[payload_length] = '\0';
		struct json_object *error = json_tokener_parse(error_text);
		free(error_text);
		free(packet);
		if (error == NULL) { errno = EPROTO; return -1; }
		struct json_object *code = NULL;
		bool stale = json_object_object_get_ex(error, "code", &code) &&
			strcmp(json_object_get_string(code), "grid-resync-required") == 0;
		printf("%s\n", json_object_to_json_string_ext(error, JSON_C_TO_STRING_PRETTY));
		json_object_put(error);
		if (expect_stale && stale) return 0;
		errno = ESTALE;
		return -1;
	}
	if (expect_stale || response_type != ENGINE_MUX_GRID_DAMAGE ||
			payload_length < sizeof(struct engine_mux_grid_damage_header)) {
		free(packet); errno = EPROTO; return -1;
	}
	struct engine_mux_grid_damage_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t damage_count = ntohl(header.damage_count);
	if (payload_length != sizeof(header) +
			(size_t)damage_count * sizeof(struct engine_mux_grid_damage_cell)) {
		free(packet); errno = EPROTO; return -1;
	}
	struct json_object *root = json_object_new_object();
	struct json_object *cells = json_object_new_array();
	json_object_object_add(root, "schema", json_object_new_string("engine-mux/grid-damage-v1"));
	json_object_object_add(root, "pane_id", json_object_new_int64(ntohl(header.grid.pane_id)));
	json_object_object_add(root, "generation", json_object_new_int64(ntohl(header.grid.generation)));
	json_object_object_add(root, "grid_revision", json_object_new_int64(
		(int64_t)be64_to_host(header.grid.grid_revision)));
	json_object_object_add(root, "columns", json_object_new_int64(ntohl(header.grid.columns)));
	json_object_object_add(root, "rows", json_object_new_int64(ntohl(header.grid.rows)));
	json_object_object_add(root, "cursor_x", json_object_new_int64(ntohl(header.grid.cursor_x)));
	json_object_object_add(root, "cursor_y", json_object_new_int64(ntohl(header.grid.cursor_y)));
	json_object_object_add(root, "damage_count", json_object_new_int64(damage_count));
	const unsigned char *damage_bytes = packet + sizeof(frame) + sizeof(header);
	for (uint32_t index = 0; index < damage_count; index++) {
		struct engine_mux_grid_damage_cell damage;
		memcpy(&damage, damage_bytes, sizeof(damage));
		damage_bytes += sizeof(damage);
		if (damage.cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
			json_object_put(root); free(packet); errno = EPROTO; return -1;
		}
		struct json_object *item = json_object_new_object();
		json_object_object_add(item, "x", json_object_new_int64(ntohl(damage.x)));
		json_object_object_add(item, "y", json_object_new_int64(ntohl(damage.y)));
		json_object_object_add(item, "text", json_object_new_string_len(
			(const char *)damage.cell.text, damage.cell.text_length));
		json_object_object_add(item, "attributes",
			json_object_new_int(ntohs(damage.cell.attributes)));
		json_object_object_add(item, "foreground",
			json_object_new_int64((int32_t)ntohl(damage.cell.foreground)));
		json_object_array_add(cells, item);
	}
	json_object_object_add(root, "cells", cells);
	printf("%s\n", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY));
	json_object_put(root);
	free(packet);
	return 0;
}

static int request_scrollback(int fd, uint32_t pane_id, uint32_t start,
		uint32_t rows) {
	struct engine_mux_scrollback_request request = {
		.pane_id = htonl(pane_id), .generation = htonl(1),
		.start_row = htonl(start), .row_count = htonl(rows),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_SCROLLBACK_REQUEST),
		.request_id = host_to_be64(5),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) return -1;
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) return -1;
	ssize_t count = recv(fd, packet, capacity, 0);
	if (count < (ssize_t)(sizeof(frame) + sizeof(struct engine_mux_scrollback_header))) {
		free(packet); errno = EPROTO; return -1;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			ntohs(frame.type) != ENGINE_MUX_SCROLLBACK ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet); errno = EPROTO; return -1;
	}
	struct engine_mux_scrollback_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.columns);
	uint32_t row_count = ntohl(header.row_count);
	uint32_t cell_count = ntohl(header.cell_count);
	if (ntohs(header.version) != ENGINE_MUX_GRID_VERSION ||
			(columns != 0 && row_count > UINT32_MAX / columns) ||
			cell_count != columns * row_count ||
			payload_length != sizeof(header) +
				(size_t)cell_count * sizeof(struct engine_mux_grid_cell)) {
		free(packet); errno = EPROTO; return -1;
	}
	struct json_object *root = json_object_new_object();
	struct json_object *text_rows = json_object_new_array();
	json_object_object_add(root, "schema", json_object_new_string("engine-mux/scrollback-v1"));
	json_object_object_add(root, "pane_id", json_object_new_int64(ntohl(header.pane_id)));
	json_object_object_add(root, "generation", json_object_new_int64(ntohl(header.generation)));
	json_object_object_add(root, "columns", json_object_new_int64(columns));
	json_object_object_add(root, "total_rows", json_object_new_int64(ntohl(header.total_rows)));
	json_object_object_add(root, "start_row", json_object_new_int64(ntohl(header.start_row)));
	json_object_object_add(root, "row_count", json_object_new_int64(row_count));
	const unsigned char *cell_bytes = packet + sizeof(frame) + sizeof(header);
	for (uint32_t y = 0; y < row_count; y++) {
		char *row_text = malloc((size_t)columns * ENGINE_MUX_GRID_CELL_TEXT_MAX + 1);
		if (row_text == NULL) { json_object_put(root); free(packet); return -1; }
		size_t used = 0;
		for (uint32_t x = 0; x < columns; x++) {
			struct engine_mux_grid_cell cell;
			memcpy(&cell, cell_bytes, sizeof(cell));
			cell_bytes += sizeof(cell);
			if (cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
				free(row_text); json_object_put(root); free(packet); errno = EPROTO; return -1;
			}
			if ((cell.flags & ENGINE_MUX_GRID_CELL_PADDING) == 0) {
				memcpy(row_text + used, cell.text, cell.text_length);
				used += cell.text_length;
			}
		}
		json_object_array_add(text_rows, json_object_new_string_len(row_text, (int)used));
		free(row_text);
	}
	json_object_object_add(root, "text_rows", text_rows);
	printf("%s\n", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY));
	json_object_put(root);
	free(packet);
	return 0;
}

static int send_input(int fd, uint32_t pane_id, const char *bytes) {
	size_t length = strlen(bytes);
	if (length == 0 || length > ENGINE_MUX_INPUT_MAX) {
		errno = EMSGSIZE;
		return -1;
	}
	struct engine_mux_input_header request = {
		.pane_id = htonl(pane_id),
		.generation = htonl(1),
		.byte_length = htons((uint16_t)length),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_INPUT_REQUEST),
		.request_id = host_to_be64(6),
		.payload_length = htonl((uint32_t)(sizeof(request) + length)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
		{.iov_base = (char *)bytes, .iov_len = length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 3};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) return -1;
	unsigned char packet[sizeof(frame) + 512];
	ssize_t count = recv(fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) { errno = EPROTO; return -1; }
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			payload_length > sizeof(packet) - sizeof(frame) ||
			sizeof(frame) + payload_length != (size_t)count) {
		errno = EPROTO;
		return -1;
	}
	char *text = malloc((size_t)payload_length + 1);
	if (text == NULL) return -1;
	memcpy(text, packet + sizeof(frame), payload_length);
	text[payload_length] = '\0';
	struct json_object *root = json_tokener_parse(text);
	free(text);
	if (root == NULL) { errno = EPROTO; return -1; }
	printf("%s\n", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY));
	json_object_put(root);
	if (type != ENGINE_MUX_INPUT_ACK) { errno = EPROTO; return -1; }
	return 0;
}

static int request_keys(int fd, uint32_t pane_id, char **keys,
		size_t key_count) {
	uint16_t response_type = 0;
	uint64_t response_revision = 0;
	char *response = NULL;
	if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 10, 0, "{}",
			&response_type, &response_revision, &response) != 0 ||
			response_type != ENGINE_MUX_SNAPSHOT) return -1;
	struct json_object *snapshot = json_tokener_parse(response);
	free(response);
	if (snapshot == NULL) { errno = EPROTO; return -1; }
	struct json_object *panes = NULL;
	json_object_object_get_ex(snapshot, "panes", &panes);
	const char *session_id = NULL;
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *id_object = NULL, *session_object = NULL;
		if (!json_object_object_get_ex(pane, "pane_id", &id_object) ||
				!json_object_object_get_ex(pane, "session_id", &session_object)) continue;
		const char *id_text = json_object_get_string(id_object);
		char expected[32];
		snprintf(expected, sizeof(expected), "%%%u", pane_id);
		if (strcmp(id_text, expected) == 0) {
			session_id = json_object_get_string(session_object);
			break;
		}
	}
	if (session_id == NULL) {
		json_object_put(snapshot);
		errno = ENOENT;
		return -1;
	}
	struct json_object *request = json_object_new_object();
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/view-register-v1"));
	json_object_object_add(request, "view_id", json_object_new_int(1));
	json_object_object_add(request, "session_id", json_object_new_string(session_id));
	json_object_object_add(request, "output", json_object_new_string("engine-muxctl"));
	json_object_object_add(request, "pixel_width", json_object_new_int(800));
	json_object_object_add(request, "pixel_height", json_object_new_int(480));
	json_object_object_add(request, "scale_milli", json_object_new_int(1000));
	json_object_object_add(request, "columns", json_object_new_int(80));
	json_object_object_add(request, "rows", json_object_new_int(24));
	json_object_object_add(request, "focused", json_object_new_boolean(true));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	if (exchange(fd, ENGINE_MUX_VIEW_REGISTER_REQUEST, 11,
			response_revision, payload, &response_type, &response_revision,
			&response) != 0 || response_type != ENGINE_MUX_VIEW_REGISTER_ACK) {
		json_object_put(request);
		json_object_put(snapshot);
		free(response);
		errno = EPROTO;
		return -1;
	}
	free(response);
	json_object_put(request);
	for (size_t index = 0; index < key_count; index++) {
		request = json_object_new_object();
		char pane_text[32];
		snprintf(pane_text, sizeof(pane_text), "%%%u", pane_id);
		json_object_object_add(request, "schema",
			json_object_new_string("engine-mux/key-v1"));
		json_object_object_add(request, "view_id", json_object_new_int(1));
		json_object_object_add(request, "pane_id", json_object_new_string(pane_text));
		json_object_object_add(request, "generation", json_object_new_int(1));
		json_object_object_add(request, "key", json_object_new_string(keys[index]));
		payload = json_object_to_json_string_ext(request, JSON_C_TO_STRING_PLAIN);
		if (exchange(fd, ENGINE_MUX_KEY_REQUEST, 12 + index,
				response_revision, payload, &response_type, &response_revision,
				&response) != 0 || response_type != ENGINE_MUX_KEY_ACK) {
			json_object_put(request);
			json_object_put(snapshot);
			free(response);
			errno = EPROTO;
			return -1;
		}
		free(response);
		json_object_put(request);
	}
	if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 100,
			response_revision, "{}", &response_type, &response_revision,
			&response) != 0 || response_type != ENGINE_MUX_SNAPSHOT) {
		json_object_put(snapshot);
		free(response);
		errno = EPROTO;
		return -1;
	}
	free(response);
	json_object_put(snapshot);
	struct json_object *result = json_object_new_object();
	json_object_object_add(result, "schema",
		json_object_new_string("engine-mux/keys-v1"));
	json_object_object_add(result, "queued", json_object_new_int64((int64_t)key_count));
	printf("%s\n", json_object_to_json_string_ext(result, JSON_C_TO_STRING_PRETTY));
	json_object_put(result);
	return 0;
}

static int focus_proof_session(int fd, uint32_t pane_id,
		uint64_t *revision, char **session_id) {
	uint16_t response_type = 0;
	char *response = NULL;
	*session_id = NULL;
	if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 200, 0, "{}",
			&response_type, revision, &response) != 0) return -1;
	if (response_type != ENGINE_MUX_SNAPSHOT) {
		free(response);
		errno = EPROTO;
		return -1;
	}
	struct json_object *snapshot = json_tokener_parse(response);
	free(response);
	if (snapshot == NULL) { errno = EPROTO; return -1; }
	struct json_object *panes = NULL;
	json_object_object_get_ex(snapshot, "panes", &panes);
	char expected[32];
	snprintf(expected, sizeof(expected), "%%%u", pane_id);
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *id_object = NULL, *session_object = NULL;
		if (!json_object_object_get_ex(pane, "pane_id", &id_object) ||
				!json_object_object_get_ex(pane, "session_id", &session_object)) continue;
		if (strcmp(json_object_get_string(id_object), expected) != 0) continue;
		*session_id = strdup(json_object_get_string(session_object));
		break;
	}
	json_object_put(snapshot);
	if (*session_id == NULL) { errno = ENOENT; return -1; }
	return 0;
}

static int focus_proof_register_view(int fd, uint32_t view_id,
		const char *session_id, uint32_t columns, uint32_t rows, bool focused,
		uint64_t request_id, uint64_t *revision) {
	struct json_object *request = json_object_new_object();
	if (request == NULL) return -1;
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/view-register-v1"));
	json_object_object_add(request, "view_id", json_object_new_int64(view_id));
	json_object_object_add(request, "session_id", json_object_new_string(session_id));
	json_object_object_add(request, "output", json_object_new_string("focus-proof"));
	json_object_object_add(request, "pixel_width",
		json_object_new_int64((int64_t)columns * 10));
	json_object_object_add(request, "pixel_height",
		json_object_new_int64((int64_t)rows * 20));
	json_object_object_add(request, "scale_milli", json_object_new_int(1000));
	json_object_object_add(request, "columns", json_object_new_int64(columns));
	json_object_object_add(request, "rows", json_object_new_int64(rows));
	json_object_object_add(request, "focused", json_object_new_boolean(focused));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	uint16_t response_type = 0;
	char *response = NULL;
	int result = exchange(fd, ENGINE_MUX_VIEW_REGISTER_REQUEST, request_id,
		*revision, payload, &response_type, revision, &response);
	json_object_put(request);
	free(response);
	if (result != 0 || response_type != ENGINE_MUX_VIEW_REGISTER_ACK) {
		errno = EPROTO;
		return -1;
	}
	return 0;
}

static int request_focus_proof(int fd, uint32_t pane_id) {
	uint64_t revision = 0;
	char *session_id = NULL;
	if (focus_proof_session(fd, pane_id, &revision, &session_id) != 0)
		return -1;
	if (focus_proof_register_view(fd, 1, session_id, 80, 24, true,
			201, &revision) != 0 ||
			focus_proof_register_view(fd, 2, session_id, 100, 30, false,
			202, &revision) != 0) {
		free(session_id);
		return -1;
	}
	free(session_id);
	struct json_object *request = json_object_new_object();
	if (request == NULL) return -1;
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/view-focus-v1"));
	json_object_object_add(request, "view_id", json_object_new_int(2));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	uint16_t response_type = 0;
	char *response = NULL;
	if (exchange(fd, ENGINE_MUX_VIEW_FOCUS_REQUEST, 203, revision, payload,
			&response_type, &revision, &response) != 0 ||
			response_type != ENGINE_MUX_VIEW_FOCUS_ACK) {
		json_object_put(request);
		free(response);
		errno = EPROTO;
		return -1;
	}
	json_object_put(request);
	free(response);
	if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 204, revision, "{}",
			&response_type, &revision, &response) != 0 ||
			response_type != ENGINE_MUX_SNAPSHOT) {
		free(response);
		errno = EPROTO;
		return -1;
	}
	struct json_object *snapshot = json_tokener_parse(response);
	free(response);
	if (snapshot == NULL) { errno = EPROTO; return -1; }
	struct json_object *panes = NULL;
	json_object_object_get_ex(snapshot, "panes", &panes);
	int64_t columns = -1, rows = -1;
	char expected[32];
	snprintf(expected, sizeof(expected), "%%%u", pane_id);
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *id_object = NULL, *columns_object = NULL;
		struct json_object *rows_object = NULL;
		if (!json_object_object_get_ex(pane, "pane_id", &id_object) ||
				strcmp(json_object_get_string(id_object), expected) != 0) continue;
		if (!json_object_object_get_ex(pane, "columns", &columns_object) ||
				!json_object_object_get_ex(pane, "rows", &rows_object)) continue;
		columns = json_object_get_int64(columns_object);
		rows = json_object_get_int64(rows_object);
		break;
	}
	json_object_put(snapshot);
	if (columns < 0 || rows < 0) { errno = EPROTO; return -1; }
	struct json_object *result = json_object_new_object();
	if (result == NULL) return -1;
	json_object_object_add(result, "schema",
		json_object_new_string("engine-mux/focus-proof-v1"));
	json_object_object_add(result, "focused_view_id", json_object_new_int(2));
	json_object_object_add(result, "columns", json_object_new_int64(columns));
	json_object_object_add(result, "rows", json_object_new_int64(rows));
	printf("%s\n", json_object_to_json_string_ext(result, JSON_C_TO_STRING_PRETTY));
	json_object_put(result);
	return 0;
}

static int parse_mouse_number(const char *text, uint32_t maximum,
		uint32_t *value) {
	char *end = NULL;
	unsigned long parsed = strtoul(text, &end, 10);
	if (*text == '\0' || *end != '\0' || parsed > maximum) return -1;
	*value = (uint32_t)parsed;
	return 0;
}

static int request_mouse_actions(int fd, uint32_t pane_id, char **actions,
		size_t action_count, bool return_ui) {
	if (action_count == 0 || action_count % 5 != 0) {
		errno = EINVAL;
		return -1;
	}
	uint64_t revision = 0;
	char *session_id = NULL;
	if (focus_proof_session(fd, pane_id, &revision, &session_id) != 0)
		return -1;
	if (focus_proof_register_view(fd, 1, session_id, 80, 24, true,
			400, &revision) != 0) {
		free(session_id);
		return -1;
	}
	free(session_id);
	uint16_t response_type = 0;
	char *response = NULL;
	struct json_object *last_ack = NULL;
	size_t queued = 0;
	for (size_t offset = 0; offset < action_count; offset += 5) {
		uint32_t x, y, modifiers;
		if (parse_mouse_number(actions[offset + 2], UINT32_MAX, &x) != 0 ||
				parse_mouse_number(actions[offset + 3], UINT32_MAX, &y) != 0 ||
				parse_mouse_number(actions[offset + 4], 7, &modifiers) != 0) {
			if (last_ack != NULL) json_object_put(last_ack);
			errno = EINVAL;
			return -1;
		}
		struct json_object *request = json_object_new_object();
		if (request == NULL) {
			if (last_ack != NULL) json_object_put(last_ack);
			return -1;
		}
		json_object_object_add(request, "schema",
			json_object_new_string("engine-mux/mouse-v1"));
		json_object_object_add(request, "view_id", json_object_new_int(1));
		json_object_object_add(request, "x", json_object_new_int64(x));
		json_object_object_add(request, "y", json_object_new_int64(y));
		json_object_object_add(request, "event",
			json_object_new_string(actions[offset]));
		json_object_object_add(request, "button",
			json_object_new_string(actions[offset + 1]));
		json_object_object_add(request, "modifiers",
			json_object_new_int64(modifiers));
		const char *payload = json_object_to_json_string_ext(request,
			JSON_C_TO_STRING_PLAIN);
		int result = exchange(fd, ENGINE_MUX_MOUSE_REQUEST, 401 + queued,
			revision, payload, &response_type, &revision, &response);
		json_object_put(request);
		if (result != 0 || response_type != ENGINE_MUX_MOUSE_ACK) {
			free(response);
			if (last_ack != NULL) json_object_put(last_ack);
			errno = EPROTO;
			return -1;
		}
		if (last_ack != NULL) json_object_put(last_ack);
		last_ack = json_tokener_parse(response);
		free(response);
		response = NULL;
		if (last_ack == NULL) { errno = EPROTO; return -1; }
		queued++;
		if (offset + 5 < action_count &&
				exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 450 + queued,
				revision, "{}", &response_type, &revision, &response) != 0) {
			json_object_put(last_ack);
			free(response);
			errno = EPROTO;
			return -1;
		}
		if (offset + 5 < action_count) {
			if (response_type != ENGINE_MUX_SNAPSHOT) {
				json_object_put(last_ack);
				free(response);
				errno = EPROTO;
				return -1;
			}
			free(response);
			response = NULL;
		}
	}
	if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 500 + queued, revision, "{}",
			&response_type, &revision, &response) != 0 ||
			response_type != ENGINE_MUX_SNAPSHOT) {
		json_object_put(last_ack);
		free(response);
		errno = EPROTO;
		return -1;
	}
	free(response);
	response = NULL;
	if (return_ui) {
		struct json_object *request = json_object_new_object();
		if (request == NULL) { json_object_put(last_ack); return -1; }
		json_object_object_add(request, "schema",
			json_object_new_string("engine-mux/ui-request-v1"));
		json_object_object_add(request, "view_id", json_object_new_int(1));
		const char *payload = json_object_to_json_string_ext(request,
			JSON_C_TO_STRING_PLAIN);
		int result = exchange(fd, ENGINE_MUX_UI_REQUEST, 600 + queued,
			revision, payload, &response_type, &revision, &response);
		json_object_put(request);
		json_object_put(last_ack);
		if (result != 0 || response_type != ENGINE_MUX_UI_MODEL) {
			free(response);
			errno = EPROTO;
			return -1;
		}
		struct json_object *model = json_tokener_parse(response);
		free(response);
		if (model == NULL) { errno = EPROTO; return -1; }
		printf("%s\n", json_object_to_json_string_ext(model,
			JSON_C_TO_STRING_PRETTY));
		json_object_put(model);
	} else if (queued == 1) {
		printf("%s\n", json_object_to_json_string_ext(last_ack,
			JSON_C_TO_STRING_PRETTY));
		json_object_put(last_ack);
	} else {
		json_object_put(last_ack);
		struct json_object *result = json_object_new_object();
		if (result == NULL) return -1;
		json_object_object_add(result, "schema",
			json_object_new_string("engine-mux/mouse-sequence-v1"));
		json_object_object_add(result, "queued",
			json_object_new_int64((int64_t)queued));
		printf("%s\n", json_object_to_json_string_ext(result,
			JSON_C_TO_STRING_PRETTY));
		json_object_put(result);
	}
	return 0;
}

static int request_ui(int fd, uint32_t pane_id, char **keys,
		size_t key_count) {
	uint64_t revision = 0;
	char *session_id = NULL;
	if (focus_proof_session(fd, pane_id, &revision, &session_id) != 0)
		return -1;
	if (focus_proof_register_view(fd, 1, session_id, 80, 24, true,
			300, &revision) != 0) {
		free(session_id);
		return -1;
	}
	free(session_id);
	uint16_t response_type = 0;
	char *response = NULL;
	for (size_t index = 0; index < key_count; index++) {
		struct json_object *request = json_object_new_object();
		if (request == NULL) return -1;
		char pane_text[32];
		snprintf(pane_text, sizeof(pane_text), "%%%u", pane_id);
		json_object_object_add(request, "schema",
			json_object_new_string("engine-mux/key-v1"));
		json_object_object_add(request, "view_id", json_object_new_int(1));
		json_object_object_add(request, "pane_id", json_object_new_string(pane_text));
		json_object_object_add(request, "generation", json_object_new_int(1));
		json_object_object_add(request, "key", json_object_new_string(keys[index]));
		const char *payload = json_object_to_json_string_ext(request,
			JSON_C_TO_STRING_PLAIN);
		int exchange_result = exchange(fd, ENGINE_MUX_KEY_REQUEST, 1000 + index,
			revision, payload, &response_type, &revision, &response);
		json_object_put(request);
		free(response);
		response = NULL;
		if (exchange_result != 0 || response_type != ENGINE_MUX_KEY_ACK) {
			errno = EPROTO;
			return -1;
		}
	}
	if (key_count != 0) {
		if (exchange(fd, ENGINE_MUX_SNAPSHOT_REQUEST, 2000 + key_count,
				revision, "{}",
				&response_type, &revision, &response) != 0 ||
				response_type != ENGINE_MUX_SNAPSHOT) {
			free(response);
			errno = EPROTO;
			return -1;
		}
		free(response);
		response = NULL;
	}
	struct json_object *request = json_object_new_object();
	if (request == NULL) return -1;
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/ui-request-v1"));
	json_object_object_add(request, "view_id", json_object_new_int(1));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	int exchange_result = exchange(fd, ENGINE_MUX_UI_REQUEST,
	    2001 + key_count, revision,
		payload, &response_type, &revision, &response);
	json_object_put(request);
	if (exchange_result != 0 || response_type != ENGINE_MUX_UI_MODEL) {
		free(response);
		errno = EPROTO;
		return -1;
	}
	struct json_object *model = json_tokener_parse(response);
	free(response);
	if (model == NULL) { errno = EPROTO; return -1; }
	printf("%s\n", json_object_to_json_string_ext(model, JSON_C_TO_STRING_PRETTY));
	json_object_put(model);
	return 0;
}

static int request_presentation_surface(int fd, bool map, uint32_t pane_id,
		uint32_t generation, pid_t pid, uint32_t surface_id,
		const char *role) {
	struct json_object *request = json_object_new_object();
	json_object_object_add(request, "schema", json_object_new_string(map ?
		"engine-mux/presentation-map-v1" :
		"engine-mux/presentation-unmap-v1"));
	char pane_name[32];
	snprintf(pane_name, sizeof(pane_name), "%%%u", pane_id);
	json_object_object_add(request, "pane_id", json_object_new_string(pane_name));
	json_object_object_add(request, "generation", json_object_new_int64(generation));
	json_object_object_add(request, "pid", json_object_new_int64(pid));
	json_object_object_add(request, "surface_id", json_object_new_int64(surface_id));
	if (map)
		json_object_object_add(request, "role", json_object_new_string(role));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	uint16_t response_type = 0;
	uint64_t response_revision = 0;
	char *response = NULL;
	int result = exchange(fd, map ? ENGINE_MUX_PRESENTATION_MAP_REQUEST :
		ENGINE_MUX_PRESENTATION_UNMAP_REQUEST, 3001, 0, payload,
		&response_type, &response_revision, &response);
	json_object_put(request);
	if (result != 0)
		return -1;
	struct json_object *parsed = json_tokener_parse(response);
	free(response);
	if (parsed == NULL) {
		errno = EPROTO;
		return -1;
	}
	printf("%s\n", json_object_to_json_string_ext(parsed,
		JSON_C_TO_STRING_PRETTY));
	json_object_put(parsed);
	uint16_t expected = map ? ENGINE_MUX_PRESENTATION_MAP_ACK :
		ENGINE_MUX_PRESENTATION_UNMAP_ACK;
	if (response_type != expected) {
		errno = EPERM;
		return -1;
	}
	return 0;
}

static int request_presentation_resolve(int fd, pid_t pid) {
	struct json_object *request = json_object_new_object();
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/presentation-resolve-v1"));
	json_object_object_add(request, "pid", json_object_new_int64(pid));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	uint16_t response_type = 0;
	uint64_t response_revision = 0;
	char *response = NULL;
	int result = exchange(fd, ENGINE_MUX_PRESENTATION_RESOLVE_REQUEST,
		3000, 0, payload, &response_type, &response_revision, &response);
	json_object_put(request);
	if (result != 0)
		return -1;
	struct json_object *parsed = json_tokener_parse(response);
	free(response);
	if (parsed == NULL) {
		errno = EPROTO;
		return -1;
	}
	printf("%s\n", json_object_to_json_string_ext(parsed,
		JSON_C_TO_STRING_PRETTY));
	json_object_put(parsed);
	if (response_type != ENGINE_MUX_PRESENTATION_RESOLVE) {
		errno = EPERM;
		return -1;
	}
	return 0;
}

static void usage(FILE *stream, const char *program) {
	fprintf(stream, "Usage: %s [--socket PATH] hello|snapshot|stale-command|grid PANE_ID|damage PANE_ID REVISION|stale-grid PANE_ID|scrollback PANE_ID START COUNT|input PANE_ID BYTES|keys PANE_ID KEY...|focus-proof PANE_ID|ui PANE_ID [KEY...]|mouse PANE_ID EVENT BUTTON X Y MODIFIERS|mouse-sequence PANE_ID (EVENT BUTTON X Y MODIFIERS)...|mouse-ui PANE_ID (EVENT BUTTON X Y MODIFIERS)...|presentation-resolve PID|presentation-map PANE_ID GENERATION PID SURFACE_ID ROLE|presentation-unmap PANE_ID GENERATION PID SURFACE_ID\n", program);
}

int main(int argc, char **argv) {
	char *owned_socket = NULL;
	const char *socket_path = NULL;
	static const struct option options[] = {
		{"socket", required_argument, NULL, 's'},
		{"help", no_argument, NULL, 'h'},
		{0},
	};
	int option;
	while ((option = getopt_long(argc, argv, "s:h", options, NULL)) != -1) {
		switch (option) {
		case 's': socket_path = optarg; break;
		case 'h': usage(stdout, argv[0]); return 0;
		default: usage(stderr, argv[0]); return 2;
		}
	}
	if (optind >= argc) {
		usage(stderr, argv[0]);
		return 2;
	}
	const char *command = argv[optind];
	bool is_grid = strcmp(command, "grid") == 0;
	bool is_damage = strcmp(command, "damage") == 0;
	bool is_stale_grid = strcmp(command, "stale-grid") == 0;
	bool is_scrollback = strcmp(command, "scrollback") == 0;
	bool is_input = strcmp(command, "input") == 0;
	bool is_keys = strcmp(command, "keys") == 0;
	bool is_focus_proof = strcmp(command, "focus-proof") == 0;
	bool is_ui = strcmp(command, "ui") == 0;
	bool is_mouse = strcmp(command, "mouse") == 0;
	bool is_mouse_sequence = strcmp(command, "mouse-sequence") == 0;
	bool is_mouse_ui = strcmp(command, "mouse-ui") == 0;
	bool is_presentation_map = strcmp(command, "presentation-map") == 0;
	bool is_presentation_unmap = strcmp(command, "presentation-unmap") == 0;
	bool is_presentation_resolve = strcmp(command, "presentation-resolve") == 0;
	size_t mouse_action_arguments = argc > optind + 2 ?
		(size_t)(argc - optind - 2) : 0;
	if ((is_grid && optind + 2 != argc) ||
			(is_damage && optind + 3 != argc) ||
			(is_stale_grid && optind + 2 != argc) ||
			(is_scrollback && optind + 4 != argc) ||
			(is_input && optind + 3 != argc) ||
			(is_keys && optind + 3 > argc) ||
			(is_focus_proof && optind + 2 != argc) ||
			(is_ui && optind + 2 > argc) ||
			(is_mouse && optind + 7 != argc) ||
			(is_presentation_map && optind + 6 != argc) ||
			(is_presentation_unmap && optind + 5 != argc) ||
			(is_presentation_resolve && optind + 2 != argc) ||
			((is_mouse_sequence || is_mouse_ui) &&
				(mouse_action_arguments == 0 || mouse_action_arguments % 5 != 0)) ||
			(!is_grid && !is_damage && !is_stale_grid && !is_scrollback && !is_input && !is_keys && !is_focus_proof && !is_ui && !is_mouse && !is_mouse_sequence && !is_mouse_ui && !is_presentation_map && !is_presentation_unmap && !is_presentation_resolve &&
			 optind + 1 != argc)) {
		usage(stderr, argv[0]);
		return 2;
	}
	if (socket_path == NULL) {
		owned_socket = default_socket_path();
		socket_path = owned_socket;
	}
	if (socket_path == NULL) {
		fprintf(stderr, "engine-muxctl: XDG_RUNTIME_DIR or --socket is required\n");
		return 2;
	}
	int fd = connect_socket(socket_path);
	if (fd < 0) {
		fprintf(stderr, "engine-muxctl: connect %s: %s\n", socket_path, strerror(errno));
		free(owned_socket);
		return 1;
	}
	if (is_presentation_resolve) {
		char *pid_end = NULL;
		long pid = strtol(argv[optind + 1], &pid_end, 10);
		if (*argv[optind + 1] == '\0' || *pid_end != '\0' ||
				pid <= 0 || pid > INT32_MAX) {
			close(fd); free(owned_socket); return 2;
		}
		int resolve_result = request_presentation_resolve(fd, (pid_t)pid);
		if (resolve_result != 0)
			fprintf(stderr, "engine-muxctl: request failed: %s\n", strerror(errno));
		close(fd);
		free(owned_socket);
		return resolve_result == 0 ? 0 : 1;
	}
	if (is_grid || is_damage || is_stale_grid || is_scrollback || is_input || is_keys || is_focus_proof || is_ui || is_mouse || is_mouse_sequence || is_mouse_ui || is_presentation_map || is_presentation_unmap) {
		const char *pane_text = argv[optind + 1];
		if (*pane_text == '%') pane_text++;
		char *end = NULL;
		unsigned long pane_id = strtoul(pane_text, &end, 10);
		uint64_t grid_revision = UINT64_MAX;
		if (is_damage) {
			char *revision_end = NULL;
			grid_revision = strtoull(argv[optind + 2], &revision_end, 10);
			if (*argv[optind + 2] == '\0' || *revision_end != '\0') {
				close(fd); free(owned_socket); return 2;
			}
		}
		if (*pane_text == '\0' || *end != '\0' || pane_id > UINT32_MAX) {
			close(fd);
			free(owned_socket);
			return 2;
		}
		int grid_result;
		if (is_presentation_map || is_presentation_unmap) {
			char *generation_end = NULL, *pid_end = NULL, *surface_end = NULL;
			unsigned long generation = strtoul(argv[optind + 2], &generation_end, 10);
			long pid = strtol(argv[optind + 3], &pid_end, 10);
			unsigned long surface_id = strtoul(argv[optind + 4], &surface_end, 10);
			if (*generation_end != '\0' || *pid_end != '\0' ||
					*surface_end != '\0' || generation == 0 ||
					generation > UINT32_MAX || pid <= 0 || pid > INT32_MAX ||
					surface_id == 0 || surface_id > UINT32_MAX) {
				close(fd); free(owned_socket); return 2;
			}
			grid_result = request_presentation_surface(fd,
				is_presentation_map, (uint32_t)pane_id,
				(uint32_t)generation, (pid_t)pid, (uint32_t)surface_id,
				is_presentation_map ? argv[optind + 5] : NULL);
		} else if (is_mouse || is_mouse_sequence || is_mouse_ui) {
			grid_result = request_mouse_actions(fd, (uint32_t)pane_id,
				&argv[optind + 2], mouse_action_arguments, is_mouse_ui);
		} else if (is_ui) {
			grid_result = request_ui(fd, (uint32_t)pane_id,
				&argv[optind + 2], (size_t)(argc - optind - 2));
		} else if (is_focus_proof) {
			grid_result = request_focus_proof(fd, (uint32_t)pane_id);
		} else if (is_keys) {
			grid_result = request_keys(fd, (uint32_t)pane_id,
				&argv[optind + 2], (size_t)(argc - optind - 2));
		} else if (is_input) {
			grid_result = send_input(fd, (uint32_t)pane_id,
				argv[optind + 2]);
		} else if (is_scrollback) {
			char *start_end = NULL, *count_end = NULL;
			unsigned long start = strtoul(argv[optind + 2], &start_end, 10);
			unsigned long rows = strtoul(argv[optind + 3], &count_end, 10);
			if (*start_end != '\0' || *count_end != '\0' ||
					start > UINT32_MAX || rows > UINT32_MAX) {
				close(fd); free(owned_socket); return 2;
			}
			grid_result = request_scrollback(fd, (uint32_t)pane_id,
				(uint32_t)start, (uint32_t)rows);
		} else if (is_grid) {
			grid_result = request_grid(fd, (uint32_t)pane_id);
		} else {
			grid_result = request_damage(fd, (uint32_t)pane_id,
				grid_revision, is_stale_grid);
		}
		if (grid_result != 0) {
			fprintf(stderr, "engine-muxctl: request failed: %s\n", strerror(errno));
			close(fd);
			free(owned_socket);
			return 1;
		}
		close(fd);
		free(owned_socket);
		return 0;
	}
	uint16_t request_type = ENGINE_MUX_CLIENT_HELLO;
	uint64_t request_revision = 0;
	const char *request_payload = "{\"client\":\"engine-muxctl\"}";
	if (strcmp(command, "snapshot") == 0) {
		request_type = ENGINE_MUX_SNAPSHOT_REQUEST;
		request_payload = "{}";
	} else if (strcmp(command, "stale-command") == 0) {
		request_type = ENGINE_MUX_COMMAND_REQUEST;
		request_revision = UINT64_MAX;
		request_payload = "{\"command\":\"display-message\"}";
	} else if (strcmp(command, "hello") != 0) {
		usage(stderr, argv[0]);
		close(fd);
		free(owned_socket);
		return 2;
	}
	uint16_t response_type = 0;
	uint64_t response_revision = 0;
	char *response = NULL;
	if (exchange(fd, request_type, 1, request_revision, request_payload,
			&response_type, &response_revision, &response) < 0) {
		fprintf(stderr, "engine-muxctl: protocol exchange failed: %s\n", strerror(errno));
		close(fd);
		free(owned_socket);
		return 1;
	}
	struct json_object *parsed = json_tokener_parse(response);
	if (parsed == NULL) {
		fprintf(stderr, "engine-muxctl: server returned invalid JSON\n");
		free(response);
		close(fd);
		free(owned_socket);
		return 1;
	}
	printf("%s\n", json_object_to_json_string_ext(parsed, JSON_C_TO_STRING_PRETTY));
	json_object_put(parsed);
	free(response);
	close(fd);
	free(owned_socket);
	if (response_type == ENGINE_MUX_ERROR) {
		return strcmp(command, "stale-command") == 0 ? 0 : 1;
	}
	if ((strcmp(command, "hello") == 0 && response_type != ENGINE_MUX_SERVER_HELLO) ||
			(strcmp(command, "snapshot") == 0 && response_type != ENGINE_MUX_SNAPSHOT)) {
		fprintf(stderr, "engine-muxctl: unexpected response type=%u revision=%llu\n",
			response_type, (unsigned long long)response_revision);
		return 1;
	}
	return 0;
}
