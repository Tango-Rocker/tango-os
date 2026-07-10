#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <json-c/json.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

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

static void stop_server(int signal_number) {
	(void)signal_number;
	running = 0;
}

static bool mkdir_parents(const char *path) {
	char *copy = strdup(path);
	if (copy == NULL) {
		return false;
	}
	for (char *cursor = copy + 1; *cursor != '\0'; cursor++) {
		if (*cursor != '/') {
			continue;
		}
		*cursor = '\0';
		if (mkdir(copy, 0700) < 0 && errno != EEXIST) {
			free(copy);
			return false;
		}
		*cursor = '/';
	}
	free(copy);
	return true;
}

static char *default_socket_path(void) {
	const char *runtime = getenv("XDG_RUNTIME_DIR");
	if (runtime == NULL || runtime[0] == '\0') {
		fprintf(stderr, "engine-muxd: XDG_RUNTIME_DIR is required\n");
		return NULL;
	}
	char *path = NULL;
	if (asprintf(&path, "%s/engineos/mux.sock", runtime) < 0) {
		return NULL;
	}
	return path;
}

static int run_capture(const char *program, char *const argv[], char **output) {
	int pipe_fds[2];
	if (pipe(pipe_fds) < 0) {
		return -1;
	}
	pid_t pid = fork();
	if (pid < 0) {
		close(pipe_fds[0]);
		close(pipe_fds[1]);
		return -1;
	}
	if (pid == 0) {
		close(pipe_fds[0]);
		dup2(pipe_fds[1], STDOUT_FILENO);
		dup2(pipe_fds[1], STDERR_FILENO);
		close(pipe_fds[1]);
		execvp(program, argv);
		_exit(127);
	}
	close(pipe_fds[1]);
	size_t used = 0;
	size_t capacity = 4096;
	char *buffer = malloc(capacity);
	if (buffer == NULL) {
		close(pipe_fds[0]);
		waitpid(pid, NULL, 0);
		return -1;
	}
	for (;;) {
		if (capacity - used < 2048) {
			if (capacity >= ENGINE_MUX_MAX_PAYLOAD) {
				free(buffer);
				close(pipe_fds[0]);
				waitpid(pid, NULL, 0);
				errno = EOVERFLOW;
				return -1;
			}
			capacity *= 2;
			char *grown = realloc(buffer, capacity);
			if (grown == NULL) {
				free(buffer);
				close(pipe_fds[0]);
				waitpid(pid, NULL, 0);
				return -1;
			}
			buffer = grown;
		}
		ssize_t count = read(pipe_fds[0], buffer + used, capacity - used - 1);
		if (count > 0) {
			used += (size_t)count;
			continue;
		}
		if (count < 0 && errno == EINTR) {
			continue;
		}
		if (count < 0) {
			free(buffer);
			close(pipe_fds[0]);
			waitpid(pid, NULL, 0);
			return -1;
		}
		break;
	}
	close(pipe_fds[0]);
	int status = 0;
	if (waitpid(pid, &status, 0) < 0) {
		free(buffer);
		return -1;
	}
	buffer[used] = '\0';
	*output = buffer;
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

static bool verify_tmux_version(const char *tmux_path) {
	char *const argv[] = {(char *)tmux_path, "-V", NULL};
	char *output = NULL;
	int status = run_capture(tmux_path, argv, &output);
	bool valid = status == 0 && output != NULL &&
		(strcmp(output, "tmux 3.6b\n") == 0 || strcmp(output, "tmux 3.6b") == 0);
	if (!valid) {
		fprintf(stderr, "engine-muxd: tmux baseline mismatch: expected tmux 3.6b, got %s",
			output != NULL ? output : "(unavailable)\n");
	}
	free(output);
	return valid;
}

static uint64_t snapshot_hash(const char *value) {
	uint64_t hash = UINT64_C(1469598103934665603);
	for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
		hash ^= *cursor;
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}

static void add_integer(struct json_object *object, const char *key, const char *value) {
	char *end = NULL;
	long long parsed = strtoll(value != NULL ? value : "", &end, 10);
	json_object_object_add(object, key,
		json_object_new_int64(end != NULL && *end == '\0' ? parsed : 0));
}

static const char *string_or_empty(const char *value) {
	return value != NULL ? value : "";
}

static struct json_object *build_snapshot(const char *tmux_path,
		const char *socket_name, uint64_t revision, uint64_t *content_hash) {
	static const char *format =
		"#{session_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_layout}\t"
		"#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{pane_width}\t#{pane_height}\t"
		"#{pane_active}\t#{pane_current_command}\t#{pane_title}";
	char *const argv[] = {(char *)tmux_path, "-L", (char *)socket_name,
		"list-panes", "-a", "-F", (char *)format, NULL};
	char *output = NULL;
	int status = run_capture(tmux_path, argv, &output);
	if (status != 0) {
		free(output);
		return NULL;
	}
	*content_hash = snapshot_hash(output);
	struct json_object *root = json_object_new_object();
	struct json_object *panes = json_object_new_array();
	json_object_object_add(root, "schema", json_object_new_string("engine-mux/snapshot-v1"));
	json_object_object_add(root, "revision", json_object_new_uint64(revision));
	json_object_object_add(root, "panes", panes);

	char *save_line = NULL;
	for (char *line = strtok_r(output, "\n", &save_line); line != NULL;
			line = strtok_r(NULL, "\n", &save_line)) {
		const char *values[13] = {0};
		char *cursor = line;
		for (size_t index = 0; index < 13; index++) {
			values[index] = cursor;
			char *tab = index < 12 ? strchr(cursor, '\t') : NULL;
			if (tab == NULL) {
				if (index < 12) {
					values[index + 1] = "";
				}
				break;
			}
			*tab = '\0';
			cursor = tab + 1;
		}
		struct json_object *pane = json_object_new_object();
		json_object_object_add(pane, "session_id", json_object_new_string(string_or_empty(values[0])));
		json_object_object_add(pane, "session_name", json_object_new_string(string_or_empty(values[1])));
		json_object_object_add(pane, "window_id", json_object_new_string(string_or_empty(values[2])));
		add_integer(pane, "window_index", values[3]);
		json_object_object_add(pane, "window_layout", json_object_new_string(string_or_empty(values[4])));
		json_object_object_add(pane, "pane_id", json_object_new_string(string_or_empty(values[5])));
		json_object_object_add(pane, "generation", json_object_new_int(1));
		add_integer(pane, "pid", values[6]);
		json_object_object_add(pane, "tty", json_object_new_string(string_or_empty(values[7])));
		add_integer(pane, "columns", values[8]);
		add_integer(pane, "rows", values[9]);
		json_object_object_add(pane, "active", json_object_new_boolean(values[10] && strcmp(values[10], "1") == 0));
		json_object_object_add(pane, "command", json_object_new_string(string_or_empty(values[11])));
		json_object_object_add(pane, "title", json_object_new_string(string_or_empty(values[12])));
		json_object_object_add(pane, "presentation", json_object_new_string("terminal"));
		json_object_object_add(pane, "view_mode", json_object_new_string("presentation"));
		json_object_array_add(panes, pane);
	}
	free(output);
	return root;
}

static int send_frame(int fd, uint16_t type, uint64_t request_id,
		uint64_t revision, const char *payload) {
	size_t length = payload != NULL ? strlen(payload) : 0;
	if (length > ENGINE_MUX_MAX_PAYLOAD) {
		errno = EMSGSIZE;
		return -1;
	}
	struct engine_mux_frame_header header = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(type),
		.request_id = host_to_be64(request_id),
		.state_revision = host_to_be64(revision),
		.payload_length = htonl((uint32_t)length),
		.flags = 0,
	};
	struct iovec parts[] = {
		{.iov_base = &header, .iov_len = sizeof(header)},
		{.iov_base = (char *)payload, .iov_len = length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = length > 0 ? 2 : 1};
	return sendmsg(fd, &message, MSG_NOSIGNAL) < 0 ? -1 : 0;
}

static void send_error(int fd, uint64_t request_id, uint64_t revision,
		const char *code, const char *message) {
	struct json_object *error = json_object_new_object();
	json_object_object_add(error, "code", json_object_new_string(code));
	json_object_object_add(error, "message", json_object_new_string(message));
	const char *payload = json_object_to_json_string_ext(error, JSON_C_TO_STRING_PLAIN);
	send_frame(fd, ENGINE_MUX_ERROR, request_id, revision, payload);
	json_object_put(error);
}

static bool serve_client_request(int fd, const char *tmux_path, const char *socket_name,
		uint64_t *revision, uint64_t *last_hash) {
	unsigned char packet[sizeof(struct engine_mux_frame_header) + ENGINE_MUX_MAX_PAYLOAD + 1];
	ssize_t count = recv(fd, packet, sizeof(packet), 0);
	if (count == 0) {
		return false;
	}
	if (count < 0) {
		return errno == EINTR;
	}
		if ((size_t)count < sizeof(struct engine_mux_frame_header)) {
			send_error(fd, 0, *revision, "malformed-frame", "frame header is truncated");
			return true;
		}
		struct engine_mux_frame_header raw;
		memcpy(&raw, packet, sizeof(raw));
		uint64_t request_id = be64_to_host(raw.request_id);
		uint32_t payload_length = ntohl(raw.payload_length);
		if (ntohl(raw.magic) != ENGINE_MUX_MAGIC) {
			send_error(fd, request_id, *revision, "bad-magic", "frame magic is invalid");
			return true;
		}
		if (ntohs(raw.version) != ENGINE_MUX_PROTOCOL_VERSION) {
			send_error(fd, request_id, *revision, "version-mismatch", "protocol version is unsupported");
			return true;
		}
		if (payload_length > ENGINE_MUX_MAX_PAYLOAD ||
				sizeof(raw) + payload_length != (size_t)count) {
			send_error(fd, request_id, *revision, "malformed-frame", "payload length does not match packet");
			return true;
		}
		uint16_t type = ntohs(raw.type);
		if (type == ENGINE_MUX_CLIENT_HELLO) {
			const char *hello = "{\"schema\":\"engine-mux/hello-v1\",\"server\":\"engine-muxd\",\"tmux_baseline\":\"3.6b\",\"capabilities\":[\"layout-snapshot\"]}";
			send_frame(fd, ENGINE_MUX_SERVER_HELLO, request_id, *revision, hello);
			return true;
		}
		if (type == ENGINE_MUX_SNAPSHOT_REQUEST) {
			uint64_t content_hash = 0;
			struct json_object *snapshot = build_snapshot(tmux_path, socket_name,
				*revision == 0 ? 1 : *revision, &content_hash);
			if (snapshot == NULL) {
				send_error(fd, request_id, *revision, "tmux-unavailable", "canonical tmux session has no readable panes");
				return true;
			}
			if (*revision == 0) {
				*revision = 1;
			} else if (*last_hash != 0 && *last_hash != content_hash) {
				(*revision)++;
				json_object_object_add(snapshot, "revision", json_object_new_uint64(*revision));
			}
			*last_hash = content_hash;
			const char *payload = json_object_to_json_string_ext(snapshot, JSON_C_TO_STRING_PLAIN);
			send_frame(fd, ENGINE_MUX_SNAPSHOT, request_id, *revision, payload);
			json_object_put(snapshot);
			return true;
		}
		if (type == ENGINE_MUX_COMMAND_REQUEST &&
				be64_to_host(raw.state_revision) != *revision) {
			send_error(fd, request_id, *revision, "stale-revision", "request revision is not current; request a complete snapshot");
			return true;
		}
		send_error(fd, request_id, *revision, "unsupported-message", "message type is not implemented by this migration stage");
	return true;
}

static void usage(FILE *stream, const char *program) {
	fprintf(stream, "Usage: %s [--socket PATH] [--tmux PATH] [--tmux-socket NAME]\n", program);
}

int main(int argc, char **argv) {
	char *owned_socket = NULL;
	const char *socket_path = NULL;
	const char *tmux_path = "engine-mux";
	const char *tmux_socket = "engine-mux";
	static const struct option options[] = {
		{"socket", required_argument, NULL, 's'},
		{"tmux", required_argument, NULL, 't'},
		{"tmux-socket", required_argument, NULL, 'L'},
		{"help", no_argument, NULL, 'h'},
		{0},
	};
	int option;
	while ((option = getopt_long(argc, argv, "s:t:L:h", options, NULL)) != -1) {
		switch (option) {
		case 's': socket_path = optarg; break;
		case 't': tmux_path = optarg; break;
		case 'L': tmux_socket = optarg; break;
		case 'h': usage(stdout, argv[0]); return 0;
		default: usage(stderr, argv[0]); return 2;
		}
	}
	if (optind != argc || !verify_tmux_version(tmux_path)) {
		return 2;
	}
	if (socket_path == NULL) {
		owned_socket = default_socket_path();
		socket_path = owned_socket;
	}
	if (socket_path == NULL || !mkdir_parents(socket_path)) {
		fprintf(stderr, "engine-muxd: cannot create socket parent: %s\n", strerror(errno));
		free(owned_socket);
		return 1;
	}
	int listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (listener < 0) {
		perror("engine-muxd: socket");
		free(owned_socket);
		return 1;
	}
	struct sockaddr_un address = {.sun_family = AF_UNIX};
	if (strlen(socket_path) >= sizeof(address.sun_path)) {
		fprintf(stderr, "engine-muxd: socket path is too long\n");
		close(listener);
		free(owned_socket);
		return 1;
	}
	strcpy(address.sun_path, socket_path);
	unlink(socket_path);
	mode_t mask = umask(0077);
	int bound = bind(listener, (struct sockaddr *)&address, sizeof(address));
	umask(mask);
	if (bound < 0 || listen(listener, 8) < 0) {
		perror("engine-muxd: bind/listen");
		close(listener);
		unlink(socket_path);
		free(owned_socket);
		return 1;
	}
	struct sigaction action = {0};
	action.sa_handler = stop_server;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);
	uint64_t revision = 0;
	uint64_t last_hash = 0;
	fprintf(stderr, "engine-muxd: listening socket=%s tmux_socket=%s baseline=3.6b\n",
		socket_path, tmux_socket);
	struct pollfd clients[33] = {{.fd = listener, .events = POLLIN}};
	for (size_t index = 1; index < 33; index++) {
		clients[index].fd = -1;
	}
	while (running) {
		int ready = poll(clients, 33, -1);
		if (ready < 0) {
			if (errno == EINTR) continue;
			perror("engine-muxd: poll");
			break;
		}
		if (clients[0].revents & POLLIN) {
			int client = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
			if (client >= 0) {
				struct ucred credentials;
				socklen_t credentials_length = sizeof(credentials);
				if (getsockopt(client, SOL_SOCKET, SO_PEERCRED, &credentials,
						&credentials_length) < 0 || credentials.uid != getuid()) {
					send_error(client, 0, revision, "peer-rejected", "frontend peer uid does not own the mux server");
					close(client);
				} else {
					size_t slot = 1;
					while (slot < 33 && clients[slot].fd >= 0) slot++;
					if (slot == 33) {
						send_error(client, 0, revision, "server-busy", "frontend client limit reached");
						close(client);
					} else {
						clients[slot].fd = client;
						clients[slot].events = POLLIN;
					}
				}
			}
		}
		for (size_t index = 1; index < 33; index++) {
			if (clients[index].fd < 0 || clients[index].revents == 0) continue;
			if ((clients[index].revents & (POLLERR | POLLHUP | POLLNVAL)) ||
					!serve_client_request(clients[index].fd, tmux_path, tmux_socket,
						&revision, &last_hash)) {
				close(clients[index].fd);
				clients[index].fd = -1;
			}
		}
	}
	for (size_t index = 1; index < 33; index++) {
		if (clients[index].fd >= 0) close(clients[index].fd);
	}
	close(listener);
	unlink(socket_path);
	free(owned_socket);
	return 0;
}
