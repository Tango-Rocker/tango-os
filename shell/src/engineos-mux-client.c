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
	uint32_t nonblank = 0;
	for (uint32_t index = 0; index < cell_count; index++) {
		if ((cells[index].flags & ENGINE_MUX_GRID_CELL_PADDING) == 0 &&
				cells[index].text_length != 0 &&
				!(cells[index].text_length == 1 &&
				  (cells[index].text[0] == 0 || cells[index].text[0] == ' '))) {
			nonblank++;
		}
	}
	free(client->grid_cells);
	client->grid_cells = cells;
	client->grid_revision = be64_to_host(header.grid_revision);
	client->grid_columns = columns;
	client->grid_rows = rows;
	client->grid_cursor_x = ntohl(header.cursor_x);
	client->grid_cursor_y = ntohl(header.cursor_y);
	client->grid_nonblank_cells = nonblank;
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
	struct json_object *pane_id = NULL, *generation = NULL;
	if (selected == NULL || !json_object_object_get_ex(selected, "pane_id", &pane_id) ||
			!json_object_object_get_ex(selected, "generation", &generation)) {
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
	json_object_put(snapshot);
	if (!request_grid(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	client->ready = true;
	return true;
}

void engineos_mux_client_destroy(struct engineos_mux_client *client) {
	if (client->fd >= 0) {
		close(client->fd);
	}
	client->fd = -1;
	free(client->socket_path);
	free(client->grid_cells);
	client->grid_cells = NULL;
	client->socket_path = NULL;
	client->ready = false;
}
