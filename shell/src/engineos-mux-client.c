#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "engineos-mux-client.h"
#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <json-c/json.h>
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

static void update_nonblank_count(struct engineos_mux_client *client) {
	uint32_t cell_count = client->grid_columns * client->grid_rows;
	uint32_t nonblank = 0;
	for (uint32_t index = 0; index < cell_count; index++) {
		const struct engine_mux_grid_cell *cell = &client->grid_cells[index];
		if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) == 0 &&
				cell->text_length != 0 &&
				!(cell->text_length == 1 &&
				  (cell->text[0] == 0 || cell->text[0] == ' '))) {
			nonblank++;
		}
	}
	client->grid_nonblank_cells = nonblank;
}

static bool exchange(int fd, uint16_t request_type, uint64_t request_id,
		uint16_t expected_type, uint64_t *revision, const char *payload,
		struct json_object **response, char *error, size_t error_size) {
	size_t payload_length = strlen(payload);
	struct engine_mux_frame_header header = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(request_type),
		.request_id = host_to_be64(request_id),
		.state_revision = host_to_be64(*revision),
		.payload_length = htonl((uint32_t)payload_length),
	};
	struct iovec parts[] = {
		{.iov_base = &header, .iov_len = sizeof(header)},
		{.iov_base = (char *)payload, .iov_len = payload_length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "send: %s", strerror(errno));
		return false;
	}
	unsigned char packet[sizeof(header) + ENGINE_MUX_MAX_PAYLOAD + 1];
	ssize_t count = recv(fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(header)) {
		snprintf(error, error_size, "truncated response");
		return false;
	}
	memcpy(&header, packet, sizeof(header));
	uint32_t length = ntohl(header.payload_length);
	uint16_t response_type = ntohs(header.type);
	if (ntohl(header.magic) != ENGINE_MUX_MAGIC ||
			ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD || sizeof(header) + length != (size_t)count) {
		snprintf(error, error_size, "invalid response frame");
		return false;
	}
	char *json_text = malloc((size_t)length + 1);
	if (json_text == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	memcpy(json_text, packet + sizeof(header), length);
	json_text[length] = '\0';
	struct json_object *root = json_tokener_parse(json_text);
	free(json_text);
	if (root == NULL) {
		snprintf(error, error_size, "response payload is not JSON");
		return false;
	}
	if (response_type == ENGINE_MUX_ERROR) {
		struct json_object *message_object = NULL;
		const char *server_message = "mux server rejected request";
		if (json_object_object_get_ex(root, "message", &message_object)) {
			server_message = json_object_get_string(message_object);
		}
		snprintf(error, error_size, "%s", server_message);
		json_object_put(root);
		return false;
	}
	if (response_type != expected_type) {
		snprintf(error, error_size, "unexpected response type %u", response_type);
		json_object_put(root);
		return false;
	}
	if (expected_type == ENGINE_MUX_SNAPSHOT) {
		struct json_object *schema = NULL;
		struct json_object *panes = NULL;
		if (!json_object_object_get_ex(root, "schema", &schema) ||
				strcmp(json_object_get_string(schema), "engine-mux/snapshot-v1") != 0 ||
				!json_object_object_get_ex(root, "panes", &panes) ||
				!json_object_is_type(panes, json_type_array)) {
			snprintf(error, error_size, "snapshot contract is invalid");
			json_object_put(root);
			return false;
		}
	}
	*revision = be64_to_host(header.state_revision);
	if (response != NULL) {
		*response = root;
	} else {
		json_object_put(root);
	}
	return true;
}

static bool request_grid(struct engineos_mux_client *client, char *error,
		size_t error_size) {
	struct engine_mux_grid_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_REQUEST),
		.request_id = host_to_be64(3),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid send: %s", strerror(errno));
		return false;
	}
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)(sizeof(frame) + sizeof(struct engine_mux_grid_header))) {
		free(packet);
		snprintf(error, error_size, "truncated terminal grid");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			ntohs(frame.type) != ENGINE_MUX_GRID_SNAPSHOT ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid terminal grid frame");
		return false;
	}
	struct engine_mux_grid_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.columns);
	uint32_t rows = ntohl(header.rows);
	uint32_t cell_count = ntohl(header.cell_count);
	if (ntohs(header.version) != ENGINE_MUX_GRID_VERSION ||
			ntohl(header.pane_id) != client->pane_id ||
			ntohl(header.generation) != client->pane_generation ||
			(columns != 0 && rows > UINT32_MAX / columns) ||
			cell_count != columns * rows ||
			payload_length != sizeof(header) +
				(size_t)cell_count * sizeof(struct engine_mux_grid_cell)) {
		free(packet);
		snprintf(error, error_size, "terminal grid contract is invalid");
		return false;
	}
	struct engine_mux_grid_cell *cells = malloc(
		(size_t)cell_count * sizeof(*cells));
	if (cells == NULL && cell_count != 0) {
		free(packet);
		snprintf(error, error_size, "out of memory");
		return false;
	}
	memcpy(cells, packet + sizeof(frame) + sizeof(header),
		(size_t)cell_count * sizeof(*cells));
	free(packet);
	free(client->grid_cells);
	client->grid_cells = cells;
	client->grid_revision = be64_to_host(header.grid_revision);
	client->grid_flags = ntohs(header.flags);
	client->grid_columns = columns;
	client->grid_rows = rows;
	client->grid_cursor_x = ntohl(header.cursor_x);
	client->grid_cursor_y = ntohl(header.cursor_y);
	free(client->grid_damage_cells);
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->grid_full_damage = true;
	update_nonblank_count(client);
	return true;
}

static bool subscribe_grid(struct engineos_mux_client *client, char *error,
		size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.grid_revision = host_to_be64(client->grid_revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_SUBSCRIBE_REQUEST),
		.request_id = host_to_be64(4),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid subscribe send: %s", strerror(errno));
		return false;
	}
	unsigned char packet[sizeof(frame) + 512];
	ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) {
		snprintf(error, error_size, "truncated grid subscription response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			ntohs(frame.type) != ENGINE_MUX_GRID_SUBSCRIBE_ACK ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid grid subscription response");
		return false;
	}
	return true;
}

static bool receive_grid_damage(struct engineos_mux_client *client,
		bool *grid_changed, char *error, size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.grid_revision = host_to_be64(client->grid_revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_DAMAGE_REQUEST),
		.request_id = host_to_be64(5),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid damage send: %s", strerror(errno));
		return false;
	}
receive_again:
	;
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet);
		snprintf(error, error_size, "truncated grid damage response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD || sizeof(frame) + length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid grid damage response");
		return false;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED) {
		if (length != sizeof(struct engine_mux_ui_invalidation)) {
			free(packet);
			snprintf(error, error_size,
				"invalid UI invalidation during grid damage");
			return false;
		}
		free(packet);
		goto receive_again;
	}
	if (type == ENGINE_MUX_ERROR) {
		free(packet);
		if (!request_grid(client, error, error_size)) return false;
		*grid_changed = true;
		return true;
	}
	if (type != ENGINE_MUX_GRID_DAMAGE ||
			length < sizeof(struct engine_mux_grid_damage_header)) {
		free(packet);
		snprintf(error, error_size, "unexpected grid damage response type %u",
			type);
		return false;
	}
	struct engine_mux_grid_damage_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.grid.columns), rows = ntohl(header.grid.rows);
	uint32_t damage_count = ntohl(header.damage_count);
	if (columns != client->grid_columns || rows != client->grid_rows ||
			length != sizeof(header) +
				(size_t)damage_count * sizeof(struct engine_mux_grid_damage_cell)) {
		free(packet);
		snprintf(error, error_size, "grid damage contract is invalid");
		return false;
	}
	const unsigned char *cursor = packet + sizeof(frame) + sizeof(header);
	struct engineos_mux_damage_cell *render_damage = NULL;
	if (damage_count != 0) {
		render_damage = realloc(client->grid_damage_cells,
			(client->grid_damage_count + damage_count) * sizeof(*render_damage));
		if (render_damage == NULL) {
			free(packet);
			snprintf(error, error_size, "out of memory");
			return false;
		}
		client->grid_damage_cells = render_damage;
	}
	for (uint32_t index = 0; index < damage_count; index++) {
		struct engine_mux_grid_damage_cell damage;
		memcpy(&damage, cursor, sizeof(damage));
		cursor += sizeof(damage);
		uint32_t x = ntohl(damage.x), y = ntohl(damage.y);
		if (x >= columns || y >= rows ||
				damage.cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
			free(packet);
			snprintf(error, error_size, "grid damage cell is invalid");
			return false;
		}
		client->grid_cells[(size_t)y * columns + x] = damage.cell;
		client->grid_damage_cells[client->grid_damage_count + index] =
			(struct engineos_mux_damage_cell){.x = x, .y = y};
	}
	client->grid_damage_count += damage_count;
	uint64_t old_revision = client->grid_revision;
	client->grid_revision = be64_to_host(header.grid.grid_revision);
	client->grid_flags = ntohs(header.grid.flags);
	client->grid_cursor_x = ntohl(header.grid.cursor_x);
	client->grid_cursor_y = ntohl(header.grid.cursor_y);
	client->revision = be64_to_host(frame.state_revision);
	update_nonblank_count(client);
	*grid_changed = damage_count != 0 || client->grid_revision != old_revision;
	free(packet);
	return true;
}

bool engineos_mux_client_connect(struct engineos_mux_client *client,
		const char *socket_path, char *error, size_t error_size) {
	client->fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (client->fd < 0) {
		snprintf(error, error_size, "socket: %s", strerror(errno));
		return false;
	}
	struct sockaddr_un address = {.sun_family = AF_UNIX};
	if (strlen(socket_path) >= sizeof(address.sun_path)) {
		snprintf(error, error_size, "socket path is too long");
		engineos_mux_client_destroy(client);
		return false;
	}
	strcpy(address.sun_path, socket_path);
	if (connect(client->fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		snprintf(error, error_size, "connect %s: %s", socket_path, strerror(errno));
		engineos_mux_client_destroy(client);
		return false;
	}
	client->socket_path = strdup(socket_path);
	if (client->socket_path == NULL) {
		snprintf(error, error_size, "out of memory");
		engineos_mux_client_destroy(client);
		return false;
	}
	if (!exchange(client->fd, ENGINE_MUX_CLIENT_HELLO, 1,
			ENGINE_MUX_SERVER_HELLO, &client->revision,
			"{\"client\":\"engineos-shell\"}", NULL, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	struct json_object *snapshot = NULL;
	if (!exchange(client->fd, ENGINE_MUX_SNAPSHOT_REQUEST, 2,
			ENGINE_MUX_SNAPSHOT, &client->revision, "{}", &snapshot,
			error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	struct json_object *panes = NULL;
	struct json_object *selected = NULL;
	json_object_object_get_ex(snapshot, "panes", &panes);
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *window_active = NULL, *active = NULL;
		json_object_object_get_ex(pane, "window_active", &window_active);
		json_object_object_get_ex(pane, "active", &active);
		if (json_object_get_boolean(window_active) &&
				json_object_get_boolean(active)) {
			selected = pane;
			break;
		}
	}
	if (selected == NULL && panes != NULL && json_object_array_length(panes) > 0) {
		selected = json_object_array_get_idx(panes, 0);
	}
	struct json_object *pane_id = NULL, *generation = NULL, *session_id = NULL;
	if (selected == NULL || !json_object_object_get_ex(selected, "pane_id", &pane_id) ||
			!json_object_object_get_ex(selected, "generation", &generation) ||
			!json_object_object_get_ex(selected, "session_id", &session_id)) {
		json_object_put(snapshot);
		snprintf(error, error_size, "snapshot has no selectable pane");
		engineos_mux_client_destroy(client);
		return false;
	}
	const char *pane_text = json_object_get_string(pane_id);
	if (pane_text[0] == '%') pane_text++;
	char *pane_end = NULL;
	unsigned long parsed_pane = strtoul(pane_text, &pane_end, 10);
	client->pane_generation = (uint32_t)json_object_get_int64(generation);
	if (*pane_text == '\0' || *pane_end != '\0' || parsed_pane > UINT32_MAX ||
			client->pane_generation == 0) {
		json_object_put(snapshot);
		snprintf(error, error_size, "snapshot pane identity is invalid");
		engineos_mux_client_destroy(client);
		return false;
	}
	client->pane_id = (uint32_t)parsed_pane;
	client->session_id = strdup(json_object_get_string(session_id));
	if (client->session_id == NULL) {
		json_object_put(snapshot);
		snprintf(error, error_size, "out of memory");
		engineos_mux_client_destroy(client);
		return false;
	}
	json_object_put(snapshot);
	if (!request_grid(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	if (!subscribe_grid(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	client->ready = true;
	return true;
}

bool engineos_mux_client_handle_event(struct engineos_mux_client *client,
		bool *grid_changed, char *error, size_t error_size) {
	*grid_changed = false;
	struct engine_mux_frame_header frame;
	unsigned char packet[sizeof(frame) + sizeof(struct engine_mux_grid_request)];
	ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) {
		snprintf(error, error_size, "mux connection closed: %s",
			count == 0 ? "end of stream" : strerror(errno));
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid mux invalidation frame");
		return false;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED) {
		struct engine_mux_ui_invalidation invalidated;
		if (length != sizeof(invalidated)) {
			snprintf(error, error_size, "invalid UI invalidation frame");
			return false;
		}
		memcpy(&invalidated, packet + sizeof(frame), sizeof(invalidated));
		uint32_t view_id = ntohl(invalidated.view_id);
		if (view_id != client->primary_view_id) return true;
		bool changed_during_request = false;
		if (!engineos_mux_client_request_ui(client, view_id,
				&changed_during_request, error, error_size)) return false;
		*grid_changed = true;
		return true;
	}
	if (type != ENGINE_MUX_GRID_INVALIDATED ||
			length != sizeof(struct engine_mux_grid_request)) {
		snprintf(error, error_size, "invalid grid invalidation size");
		return false;
	}
	struct engine_mux_grid_request invalidated;
	memcpy(&invalidated, packet + sizeof(frame), sizeof(invalidated));
	if (ntohl(invalidated.pane_id) != client->pane_id ||
			ntohl(invalidated.generation) != client->pane_generation) {
		snprintf(error, error_size, "invalid grid invalidation frame");
		return false;
	}
	return receive_grid_damage(client, grid_changed, error, error_size);
}

bool engineos_mux_client_send_input(struct engineos_mux_client *client,
		const void *bytes, size_t length, bool *grid_changed,
		char *error, size_t error_size) {
	*grid_changed = false;
	if (!client->ready || bytes == NULL || length == 0 ||
			length > ENGINE_MUX_INPUT_MAX) {
		snprintf(error, error_size, "invalid pane input request");
		return false;
	}
	struct engine_mux_input_header request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.byte_length = htons((uint16_t)length),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_INPUT_REQUEST),
		.request_id = host_to_be64(6),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl((uint32_t)(sizeof(request) + length)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
		{.iov_base = (void *)bytes, .iov_len = length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 3};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "pane input send: %s", strerror(errno));
		return false;
	}
	bool invalidated = false;
	for (;;) {
		unsigned char packet[sizeof(frame) + 512];
		ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
		if (count < (ssize_t)sizeof(frame)) {
			snprintf(error, error_size, "truncated pane input response");
			return false;
		}
		memcpy(&frame, packet, sizeof(frame));
		uint32_t payload_length = ntohl(frame.payload_length);
		uint16_t type = ntohs(frame.type);
		if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
				ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
				payload_length > sizeof(packet) - sizeof(frame) ||
				sizeof(frame) + payload_length != (size_t)count) {
			snprintf(error, error_size, "invalid pane input response");
			return false;
		}
		if (type == ENGINE_MUX_GRID_INVALIDATED && !invalidated) {
			struct engine_mux_grid_request notice;
			if (payload_length != sizeof(notice)) {
				snprintf(error, error_size, "invalid grid invalidation during input");
				return false;
			}
			memcpy(&notice, packet + sizeof(frame), sizeof(notice));
			if (ntohl(notice.pane_id) != client->pane_id ||
					ntohl(notice.generation) != client->pane_generation) {
				snprintf(error, error_size, "grid invalidation pane mismatch");
				return false;
			}
			invalidated = true;
			continue;
		}
		if (type == ENGINE_MUX_UI_INVALIDATED) {
			if (payload_length != sizeof(struct engine_mux_ui_invalidation)) {
				snprintf(error, error_size, "invalid UI invalidation during request");
				return false;
			}
			continue;
		}
		if (type == ENGINE_MUX_ERROR) {
			size_t copy_length = payload_length;
			if (copy_length >= error_size) copy_length = error_size - 1;
			memcpy(error, packet + sizeof(frame), copy_length);
			error[copy_length] = '\0';
			return false;
		}
		if (type != ENGINE_MUX_INPUT_ACK) {
			snprintf(error, error_size,
				"unexpected pane input response type %u", type);
			return false;
		}
		client->revision = be64_to_host(frame.state_revision);
		break;
	}
	if (invalidated && !receive_grid_damage(client, grid_changed,
			error, error_size)) {
		return false;
	}
	return true;
}

static void free_ui_rows(struct engineos_mux_ui_row *rows, size_t count) {
	for (size_t index = 0; index < count; index++) {
		free(rows[index].text);
		free(rows[index].spans);
	}
	free(rows);
}

static bool json_u32(struct json_object *parent, const char *name,
		uint32_t maximum, uint32_t *value) {
	struct json_object *object = NULL;
	if (!json_object_object_get_ex(parent, name, &object) ||
			!json_object_is_type(object, json_type_int)) return false;
	int64_t parsed = json_object_get_int64(object);
	if (parsed < 0 || (uint64_t)parsed > maximum) return false;
	*value = (uint32_t)parsed;
	return true;
}

static bool json_i32(struct json_object *parent, const char *name,
		int32_t minimum, int32_t maximum, int32_t *value) {
	struct json_object *object = NULL;
	if (!json_object_object_get_ex(parent, name, &object) ||
			!json_object_is_type(object, json_type_int)) return false;
	int64_t parsed = json_object_get_int64(object);
	if (parsed < minimum || parsed > maximum) return false;
	*value = (int32_t)parsed;
	return true;
}

static bool parse_ui_rows(struct json_object *array, uint32_t columns,
		struct engineos_mux_ui_row **parsed_rows, size_t *parsed_count,
		char *error, size_t error_size) {
	if (!json_object_is_type(array, json_type_array)) {
		snprintf(error, error_size, "UI rows are not an array");
		return false;
	}
	size_t count = json_object_array_length(array);
	struct engineos_mux_ui_row *rows = calloc(count, sizeof(*rows));
	if (rows == NULL && count != 0) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	for (size_t row_index = 0; row_index < count; row_index++) {
		struct json_object *row = json_object_array_get_idx(array, row_index);
		struct json_object *text = NULL, *spans = NULL;
		if (!json_object_is_type(row, json_type_object) ||
				!json_object_object_get_ex(row, "text", &text) ||
				!json_object_is_type(text, json_type_string) ||
				!json_object_object_get_ex(row, "spans", &spans) ||
				!json_object_is_type(spans, json_type_array)) {
			snprintf(error, error_size, "UI row contract is invalid");
			free_ui_rows(rows, count);
			return false;
		}
		rows[row_index].text = strdup(json_object_get_string(text));
		rows[row_index].span_count = json_object_array_length(spans);
		rows[row_index].spans = calloc(rows[row_index].span_count,
			sizeof(*rows[row_index].spans));
		if (rows[row_index].text == NULL ||
				(rows[row_index].spans == NULL && rows[row_index].span_count != 0)) {
			snprintf(error, error_size, "out of memory");
			free_ui_rows(rows, count);
			return false;
		}
		for (size_t span_index = 0;
				span_index < rows[row_index].span_count; span_index++) {
			struct json_object *span = json_object_array_get_idx(spans, span_index);
			struct engineos_mux_ui_span *destination =
				&rows[row_index].spans[span_index];
			uint32_t attributes, foreground, background;
			if (!json_object_is_type(span, json_type_object) ||
					!json_u32(span, "start", columns, &destination->start) ||
					!json_u32(span, "end", columns, &destination->end) ||
					destination->end < destination->start ||
					!json_u32(span, "attributes", UINT16_MAX, &attributes) ||
					!json_u32(span, "foreground", UINT32_MAX, &foreground) ||
					!json_u32(span, "background", UINT32_MAX, &background)) {
				snprintf(error, error_size, "UI style span contract is invalid");
				free_ui_rows(rows, count);
				return false;
			}
			destination->attributes = (uint16_t)attributes;
			destination->foreground = (int32_t)foreground;
			destination->background = (int32_t)background;
		}
	}
	*parsed_rows = rows;
	*parsed_count = count;
	return true;
}

static bool parse_ui_model(struct engineos_mux_client *client,
		struct json_object *root, char *error, size_t error_size) {
	struct json_object *status = NULL, *status_rows = NULL, *mode = NULL;
	struct json_object *prompt = NULL, *message = NULL, *menu = NULL;
	struct json_object *menu_rows = NULL, *active = NULL;
	uint32_t columns, rows, menu_x = 0, menu_y = 0;
	int32_t status_y;
	uint32_t menu_width = 0, menu_height = 0;
	struct engineos_mux_ui_row *new_status_rows = NULL, *new_menu_rows = NULL;
	size_t new_status_count = 0, new_menu_count = 0;
	if (!json_u32(root, "columns", 16384, &columns) || columns == 0 ||
			!json_u32(root, "rows", 16384, &rows) || rows == 0 ||
			!json_object_object_get_ex(root, "status", &status) ||
			!json_object_is_type(status, json_type_object) ||
			!json_object_object_get_ex(status, "mode", &mode) ||
			!json_object_is_type(mode, json_type_string) ||
			strlen(json_object_get_string(mode)) >= sizeof(client->ui_mode) ||
			!json_i32(status, "y", -1, (int32_t)rows, &status_y) ||
			!json_object_object_get_ex(status, "rows", &status_rows) ||
			!parse_ui_rows(status_rows, columns, &new_status_rows,
				&new_status_count, error, error_size) ||
			(status_y < 0 ? new_status_count != 0 :
				(uint64_t)status_y + new_status_count > rows)) {
		if (error[0] == '\0') snprintf(error, error_size, "UI status contract is invalid");
		free_ui_rows(new_status_rows, new_status_count);
		return false;
	}
	if (!json_object_object_get_ex(root, "prompt", &prompt) ||
			!json_object_object_get_ex(prompt, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool prompt_active = json_object_get_boolean(active);
	if (!json_object_object_get_ex(root, "message", &message) ||
			!json_object_object_get_ex(message, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool message_active = json_object_get_boolean(active);
	if (!json_object_object_get_ex(root, "menu", &menu) ||
			!json_object_object_get_ex(menu, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool menu_active = json_object_get_boolean(active);
	if (menu_active) {
		if (!json_u32(menu, "x", columns, &menu_x) ||
				!json_u32(menu, "y", rows, &menu_y) ||
				!json_u32(menu, "width", columns, &menu_width) ||
				!json_u32(menu, "height", rows, &menu_height) ||
				menu_width == 0 || menu_height == 0 ||
				menu_x + menu_width > columns || menu_y + menu_height > rows ||
				!json_object_object_get_ex(menu, "rows", &menu_rows) ||
				!parse_ui_rows(menu_rows, menu_width, &new_menu_rows,
					&new_menu_count, error, error_size) ||
				new_menu_count != menu_height) goto invalid;
	}
	free_ui_rows(client->ui_status_rows, client->ui_status_row_count);
	free_ui_rows(client->ui_menu_rows, client->ui_menu_row_count);
	client->ui_columns = columns;
	client->ui_rows = rows;
	client->ui_status_y = status_y;
	client->ui_status_rows = new_status_rows;
	client->ui_status_row_count = new_status_count;
	client->ui_menu_x = menu_x;
	client->ui_menu_y = menu_y;
	client->ui_menu_width = menu_width;
	client->ui_menu_height = menu_height;
	client->ui_menu_rows = new_menu_rows;
	client->ui_menu_row_count = new_menu_count;
	strcpy(client->ui_mode, json_object_get_string(mode));
	client->ui_prompt_active = prompt_active;
	client->ui_message_active = message_active;
	client->ui_menu_active = menu_active;
	client->ui_changed = true;
	return true;

invalid:
	snprintf(error, error_size, "UI model contract is invalid");
	free_ui_rows(new_status_rows, new_status_count);
	free_ui_rows(new_menu_rows, new_menu_count);
	return false;
}

static bool exchange_json_request(struct engineos_mux_client *client,
		uint16_t request_type, uint16_t expected_type, const char *payload,
		const char *expected_schema, struct json_object **response,
		bool *grid_changed,
		char *error, size_t error_size) {
	*grid_changed = false;
	size_t payload_length = strlen(payload);
	if (!client->ready || payload_length == 0 ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD) {
		snprintf(error, error_size, "invalid mux JSON request");
		return false;
	}
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(request_type),
		.request_id = host_to_be64(7),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl((uint32_t)payload_length),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = (char *)payload, .iov_len = payload_length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "mux JSON send: %s", strerror(errno));
		return false;
	}
	bool invalidated = false;
	for (;;) {
		size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
		unsigned char *packet = malloc(capacity);
		if (packet == NULL) {
			snprintf(error, error_size, "out of memory");
			return false;
		}
		ssize_t count = recv(client->fd, packet, capacity, 0);
		if (count < (ssize_t)sizeof(frame)) {
			free(packet);
			snprintf(error, error_size, "truncated mux JSON response");
			return false;
		}
		memcpy(&frame, packet, sizeof(frame));
		uint32_t length = ntohl(frame.payload_length);
		uint16_t type = ntohs(frame.type);
		if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
				ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
				length > ENGINE_MUX_MAX_PAYLOAD ||
				sizeof(frame) + length != (size_t)count) {
			free(packet);
			snprintf(error, error_size, "invalid mux JSON response");
			return false;
		}
		if (type == ENGINE_MUX_GRID_INVALIDATED && !invalidated) {
			struct engine_mux_grid_request notice;
			if (length != sizeof(notice)) {
				free(packet);
				snprintf(error, error_size, "invalid grid invalidation during request");
				return false;
			}
			memcpy(&notice, packet + sizeof(frame), sizeof(notice));
			free(packet);
			if (ntohl(notice.pane_id) != client->pane_id ||
					ntohl(notice.generation) != client->pane_generation) {
				snprintf(error, error_size, "grid invalidation pane mismatch");
				return false;
			}
			invalidated = true;
			continue;
		}
		if (type == ENGINE_MUX_UI_INVALIDATED) {
			if (length != sizeof(struct engine_mux_ui_invalidation)) {
				free(packet);
				snprintf(error, error_size,
					"invalid UI invalidation during request");
				return false;
			}
			free(packet);
			continue;
		}
		char *json_text = malloc((size_t)length + 1);
		if (json_text == NULL) {
			free(packet);
			snprintf(error, error_size, "out of memory");
			return false;
		}
		memcpy(json_text, packet + sizeof(frame), length);
		json_text[length] = '\0';
		free(packet);
		struct json_object *root = json_tokener_parse(json_text);
		free(json_text);
		if (root == NULL) {
			snprintf(error, error_size, "mux response payload is not JSON");
			return false;
		}
		if (type == ENGINE_MUX_ERROR) {
			struct json_object *message_object = NULL;
			const char *server_message = "mux server rejected request";
			if (json_object_object_get_ex(root, "message", &message_object))
				server_message = json_object_get_string(message_object);
			snprintf(error, error_size, "%s", server_message);
			json_object_put(root);
			return false;
		}
		struct json_object *schema = NULL;
		if (type != expected_type ||
				!json_object_object_get_ex(root, "schema", &schema) ||
				strcmp(json_object_get_string(schema), expected_schema) != 0) {
			snprintf(error, error_size, "unexpected mux JSON response type %u", type);
			json_object_put(root);
			return false;
		}
		if (response != NULL)
			*response = root;
		else
			json_object_put(root);
		client->revision = be64_to_host(frame.state_revision);
		break;
	}
	if (invalidated && !receive_grid_damage(client, grid_changed,
			error, error_size)) return false;
	return true;
}

bool engineos_mux_client_register_view(struct engineos_mux_client *client,
		uint32_t view_id, const char *output, uint32_t pixel_width,
		uint32_t pixel_height, uint32_t scale_milli, bool focused,
		bool *grid_changed, char *error, size_t error_size) {
	if (client->session_id == NULL || output == NULL || view_id == 0) {
		snprintf(error, error_size, "invalid graphical view registration");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-register-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "session_id",
		json_object_new_string(client->session_id));
	json_object_object_add(root, "output", json_object_new_string(output));
	json_object_object_add(root, "pixel_width", json_object_new_int64(pixel_width));
	json_object_object_add(root, "pixel_height", json_object_new_int64(pixel_height));
	json_object_object_add(root, "scale_milli", json_object_new_int64(scale_milli));
	json_object_object_add(root, "columns", json_object_new_int64(client->grid_columns));
	json_object_object_add(root, "rows", json_object_new_int64(client->grid_rows));
	json_object_object_add(root, "focused", json_object_new_boolean(focused));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_REGISTER_REQUEST, ENGINE_MUX_VIEW_REGISTER_ACK,
		payload, "engine-mux/view-register-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	if (result && focused) client->primary_view_id = view_id;
	return result;
}

bool engineos_mux_client_unregister_view(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-unregister-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_UNREGISTER_REQUEST, ENGINE_MUX_VIEW_UNREGISTER_ACK,
		payload, "engine-mux/view-unregister-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	if (result && client->primary_view_id == view_id)
		client->primary_view_id = 0;
	return result;
}

bool engineos_mux_client_focus_view(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	if (view_id == 0) {
		snprintf(error, error_size, "invalid graphical view focus request");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-focus-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_FOCUS_REQUEST, ENGINE_MUX_VIEW_FOCUS_ACK,
		payload, "engine-mux/view-focus-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	if (result) client->primary_view_id = view_id;
	return result;
}

bool engineos_mux_client_send_key(struct engineos_mux_client *client,
		uint32_t view_id, const char *key_name, bool *grid_changed,
		char *error, size_t error_size) {
	if (view_id == 0 || key_name == NULL || *key_name == '\0') {
		snprintf(error, error_size, "invalid graphical key request");
		return false;
	}
	char pane_id[32];
	snprintf(pane_id, sizeof(pane_id), "%%%u", client->pane_id);
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/key-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "pane_id", json_object_new_string(pane_id));
	json_object_object_add(root, "generation",
		json_object_new_int64(client->pane_generation));
	json_object_object_add(root, "key", json_object_new_string(key_name));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client, ENGINE_MUX_KEY_REQUEST,
		ENGINE_MUX_KEY_ACK, payload, "engine-mux/key-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	return result;
}

bool engineos_mux_client_send_mouse(struct engineos_mux_client *client,
		uint32_t view_id, uint32_t x, uint32_t y, const char *event,
		const char *button, uint32_t modifiers, bool *grid_changed,
		char *error, size_t error_size) {
	if (view_id == 0 || event == NULL || *event == '\0' ||
			button == NULL || *button == '\0' || modifiers > 7) {
		snprintf(error, error_size, "invalid graphical mouse request");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/mouse-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "x", json_object_new_int64(x));
	json_object_object_add(root, "y", json_object_new_int64(y));
	json_object_object_add(root, "event", json_object_new_string(event));
	json_object_object_add(root, "button", json_object_new_string(button));
	json_object_object_add(root, "modifiers",
		json_object_new_int64(modifiers));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client, ENGINE_MUX_MOUSE_REQUEST,
		ENGINE_MUX_MOUSE_ACK, payload, "engine-mux/mouse-v1", NULL,
		grid_changed, error, error_size);
	json_object_put(root);
	return result;
}

bool engineos_mux_client_request_ui(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	if (view_id == 0) {
		snprintf(error, error_size, "invalid UI model request");
		return false;
	}
	struct json_object *request = json_object_new_object();
	if (request == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/ui-request-v1"));
	json_object_object_add(request, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	struct json_object *response = NULL;
	bool result = exchange_json_request(client, ENGINE_MUX_UI_REQUEST,
		ENGINE_MUX_UI_MODEL, payload, "engine-mux/ui-model-v1", &response,
		grid_changed, error, error_size);
	json_object_put(request);
	if (!result) return false;
	result = parse_ui_model(client, response, error, error_size);
	json_object_put(response);
	return result;
}

void engineos_mux_client_clear_render_damage(struct engineos_mux_client *client) {
	free(client->grid_damage_cells);
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->grid_full_damage = false;
	client->ui_changed = false;
}

void engineos_mux_client_destroy(struct engineos_mux_client *client) {
	if (client->fd >= 0) {
		close(client->fd);
	}
	client->fd = -1;
	free(client->socket_path);
	free(client->session_id);
	free(client->grid_cells);
	free(client->grid_damage_cells);
	free_ui_rows(client->ui_status_rows, client->ui_status_row_count);
	free_ui_rows(client->ui_menu_rows, client->ui_menu_row_count);
	client->grid_cells = NULL;
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->ui_status_rows = NULL;
	client->ui_status_row_count = 0;
	client->ui_menu_rows = NULL;
	client->ui_menu_row_count = 0;
	client->socket_path = NULL;
	client->session_id = NULL;
	client->primary_view_id = 0;
	client->ready = false;
}
