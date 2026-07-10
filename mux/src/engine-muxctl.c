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

static void usage(FILE *stream, const char *program) {
	fprintf(stream, "Usage: %s [--socket PATH] hello|snapshot|stale-command\n", program);
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
	if (optind + 1 != argc) {
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
	const char *command = argv[optind];
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
