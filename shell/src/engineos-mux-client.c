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
		char *error, size_t error_size) {
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
	json_object_put(root);
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
			"{\"client\":\"engineos-shell\"}", error, error_size) ||
			!exchange(client->fd, ENGINE_MUX_SNAPSHOT_REQUEST, 2,
			ENGINE_MUX_SNAPSHOT, &client->revision, "{}", error, error_size)) {
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
	client->socket_path = NULL;
	client->ready = false;
}
