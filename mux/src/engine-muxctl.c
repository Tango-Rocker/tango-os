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
	ssize_t count = recv(fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(header)) {
		errno = EPROTO;
		return -1;
	}
	memcpy(&header, packet, sizeof(header));
	uint32_t length = ntohl(header.payload_length);
	if (ntohl(header.magic) != ENGINE_MUX_MAGIC ||
			ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD || sizeof(header) + length != (size_t)count) {
		errno = EPROTO;
		return -1;
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

static void usage(FILE *stream, const char *program) {
	fprintf(stream, "Usage: %s [--socket PATH] hello|snapshot|stale-command|grid PANE_ID|damage PANE_ID REVISION|stale-grid PANE_ID\n", program);
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
	if ((is_grid && optind + 2 != argc) ||
			(is_damage && optind + 3 != argc) ||
			(is_stale_grid && optind + 2 != argc) ||
			(!is_grid && !is_damage && !is_stale_grid && optind + 1 != argc)) {
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
	if (is_grid || is_damage || is_stale_grid) {
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
		int grid_result = is_grid ? request_grid(fd, (uint32_t)pane_id) :
			request_damage(fd, (uint32_t)pane_id, grid_revision, is_stale_grid);
		if (grid_result != 0) {
			fprintf(stderr, "engine-muxctl: grid request failed: %s\n", strerror(errno));
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
