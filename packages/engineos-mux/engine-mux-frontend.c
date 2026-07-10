#include "tmux.h"

#include "engine-mux-frontend.h"
#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct engine_mux_client {
	int fd;
	struct event event;
	TAILQ_ENTRY(engine_mux_client) entry;
};

static TAILQ_HEAD(, engine_mux_client) engine_mux_clients =
	TAILQ_HEAD_INITIALIZER(engine_mux_clients);
static struct event engine_mux_accept_event;
static int engine_mux_listener = -1;
static char *engine_mux_socket_path;
static char *engine_mux_snapshot;
static size_t engine_mux_snapshot_size;
static uint64_t engine_mux_revision;
static uint64_t engine_mux_snapshot_hash;

static uint64_t
engine_mux_host_to_be64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	return ((uint64_t)htonl((uint32_t)(value >> 32))) |
	    ((uint64_t)htonl((uint32_t)value) << 32);
#else
	return (value);
#endif
}

static uint64_t
engine_mux_be64_to_host(uint64_t value)
{
	return (engine_mux_host_to_be64(value));
}

static void
engine_mux_hash_bytes(uint64_t *hash, const void *data, size_t size)
{
	const u_char *bytes = data;
	size_t i;

	for (i = 0; i < size; i++) {
		*hash ^= bytes[i];
		*hash *= UINT64_C(1099511628211);
	}
}

static void
engine_mux_hash_string(uint64_t *hash, const char *value)
{
	if (value != NULL)
		engine_mux_hash_bytes(hash, value, strlen(value));
	engine_mux_hash_bytes(hash, "\0", 1);
}

static void
engine_mux_json_string(struct evbuffer *buffer, const char *value)
{
	const u_char *cursor;

	evbuffer_add(buffer, "\"", 1);
	if (value != NULL) {
		for (cursor = (const u_char *)value; *cursor != '\0'; cursor++) {
			switch (*cursor) {
			case '\\':
				evbuffer_add(buffer, "\\\\", 2);
				break;
			case '\"':
				evbuffer_add(buffer, "\\\"", 2);
				break;
			case '\b':
				evbuffer_add(buffer, "\\b", 2);
				break;
			case '\f':
				evbuffer_add(buffer, "\\f", 2);
				break;
			case '\n':
				evbuffer_add(buffer, "\\n", 2);
				break;
			case '\r':
				evbuffer_add(buffer, "\\r", 2);
				break;
			case '\t':
				evbuffer_add(buffer, "\\t", 2);
				break;
			default:
				if (*cursor < 0x20)
					evbuffer_add_printf(buffer, "\\u%04x", *cursor);
				else
					evbuffer_add(buffer, cursor, 1);
				break;
			}
		}
	}
	evbuffer_add(buffer, "\"", 1);
}

static char *
engine_mux_current_command(struct window_pane *wp)
{
	char *command, *name;

	command = osdep_get_name(wp->fd, wp->tty);
	if (command == NULL || *command == '\0') {
		free(command);
		command = cmd_stringify_argv(wp->argc, wp->argv);
		if (command == NULL || *command == '\0') {
			free(command);
			command = xstrdup(wp->shell == NULL ? "" : wp->shell);
		}
	}
	name = parse_window_name(command);
	free(command);
	return (name);
}

static char *
engine_mux_build_snapshot(uint64_t revision, uint64_t *content_hash,
    size_t *size)
{
	struct evbuffer *buffer;
	struct session *session;
	struct winlink *winlink;
	struct window *window;
	struct window_pane *pane;
	char *layout, *command;
	char *result;
	int first = 1, pane_active, window_active;
	uint64_t hash = UINT64_C(1469598103934665603);

	buffer = evbuffer_new();
	if (buffer == NULL)
		fatalx("engine mux snapshot allocation failed");
	evbuffer_add_printf(buffer,
	    "{\"schema\":\"engine-mux/snapshot-v1\",\"revision\":%llu,\"panes\":[",
	    (unsigned long long)revision);

	RB_FOREACH(session, sessions, &sessions) {
		RB_FOREACH(winlink, winlinks, &session->windows) {
			window = winlink->window;
			window_active = session->curw == winlink;
			layout = layout_dump(window->layout_root);
			TAILQ_FOREACH(pane, &window->panes, entry) {
				pane_active = window->active == pane;
				command = engine_mux_current_command(pane);
				if (!first)
					evbuffer_add(buffer, ",", 1);
				first = 0;
				evbuffer_add_printf(buffer,
				    "{\"session_id\":\"$%u\",\"session_name\":",
				    session->id);
				engine_mux_json_string(buffer, session->name);
				evbuffer_add_printf(buffer,
				    ",\"window_id\":\"@%u\",\"window_index\":%d,\"window_active\":%s,\"window_layout\":",
				    window->id, winlink->idx,
				    window_active ? "true" : "false");
				engine_mux_json_string(buffer, layout);
				evbuffer_add_printf(buffer,
				    ",\"pane_id\":\"%%%u\",\"generation\":1,\"pid\":%lld,\"tty\":",
				    pane->id, (long long)pane->pid);
				engine_mux_json_string(buffer, pane->tty);
				evbuffer_add_printf(buffer,
				    ",\"columns\":%u,\"rows\":%u,\"active\":%s,\"command\":",
				    pane->sx, pane->sy,
				    pane_active ? "true" : "false");
				engine_mux_json_string(buffer, command);
				evbuffer_add(buffer, ",\"title\":", 9);
				engine_mux_json_string(buffer, pane->base.title);
				evbuffer_add_printf(buffer,
				    ",\"presentation\":\"terminal\",\"view_mode\":\"presentation\"}");

				engine_mux_hash_bytes(&hash, &session->id,
				    sizeof session->id);
				engine_mux_hash_string(&hash, session->name);
				engine_mux_hash_bytes(&hash, &window->id,
				    sizeof window->id);
				engine_mux_hash_bytes(&hash, &winlink->idx,
				    sizeof winlink->idx);
				engine_mux_hash_bytes(&hash, &window_active,
				    sizeof window_active);
				engine_mux_hash_string(&hash, layout);
				engine_mux_hash_bytes(&hash, &pane->id,
				    sizeof pane->id);
				engine_mux_hash_bytes(&hash, &pane->pid,
				    sizeof pane->pid);
				engine_mux_hash_string(&hash, pane->tty);
				engine_mux_hash_bytes(&hash, &pane->sx,
				    sizeof pane->sx);
				engine_mux_hash_bytes(&hash, &pane->sy,
				    sizeof pane->sy);
				engine_mux_hash_bytes(&hash, &pane_active,
				    sizeof pane_active);
				engine_mux_hash_string(&hash, command);
				engine_mux_hash_string(&hash, pane->base.title);
				free(command);
			}
			free(layout);
		}
	}
	evbuffer_add(buffer, "]}", 2);
	*size = EVBUFFER_LENGTH(buffer);
	result = xmalloc(*size + 1);
	memcpy(result, EVBUFFER_DATA(buffer), *size);
	result[*size] = '\0';
	evbuffer_free(buffer);
	*content_hash = hash;
	return (result);
}

void
engine_mux_frontend_sync(void)
{
	char *candidate;
	size_t candidate_size;
	uint64_t content_hash;

	if (engine_mux_listener == -1)
		return;

	candidate = engine_mux_build_snapshot(engine_mux_revision,
	    &content_hash, &candidate_size);
	if (engine_mux_snapshot != NULL &&
	    content_hash == engine_mux_snapshot_hash) {
		free(candidate);
		return;
	}
	if (engine_mux_revision == 0)
		engine_mux_revision = 1;
	else
		engine_mux_revision++;
	free(candidate);
	candidate = engine_mux_build_snapshot(engine_mux_revision,
	    &content_hash, &candidate_size);
	free(engine_mux_snapshot);
	engine_mux_snapshot = candidate;
	engine_mux_snapshot_size = candidate_size;
	engine_mux_snapshot_hash = content_hash;
}

static int
engine_mux_send_frame(int fd, uint16_t type, uint64_t request_id,
    uint64_t revision, const char *payload, size_t payload_size)
{
	struct engine_mux_frame_header header;
	struct iovec parts[2];
	struct msghdr message;

	if (payload_size > ENGINE_MUX_MAX_PAYLOAD) {
		errno = EMSGSIZE;
		return (-1);
	}
	memset(&header, 0, sizeof header);
	header.magic = htonl(ENGINE_MUX_MAGIC);
	header.version = htons(ENGINE_MUX_PROTOCOL_VERSION);
	header.type = htons(type);
	header.request_id = engine_mux_host_to_be64(request_id);
	header.state_revision = engine_mux_host_to_be64(revision);
	header.payload_length = htonl((uint32_t)payload_size);
	parts[0].iov_base = &header;
	parts[0].iov_len = sizeof header;
	parts[1].iov_base = (void *)payload;
	parts[1].iov_len = payload_size;
	memset(&message, 0, sizeof message);
	message.msg_iov = parts;
	message.msg_iovlen = payload_size == 0 ? 1 : 2;
	if (sendmsg(fd, &message, MSG_NOSIGNAL) == -1)
		return (-1);
	return (0);
}

static int
engine_mux_send_error(int fd, uint64_t request_id, const char *code,
    const char *message)
{
	struct evbuffer *buffer;
	const char *payload;
	size_t payload_size;
	int result;

	buffer = evbuffer_new();
	if (buffer == NULL)
		return (-1);
	evbuffer_add(buffer, "{\"code\":", 8);
	engine_mux_json_string(buffer, code);
	evbuffer_add(buffer, ",\"message\":", 11);
	engine_mux_json_string(buffer, message);
	evbuffer_add(buffer, "}", 1);
	payload = (const char *)EVBUFFER_DATA(buffer);
	payload_size = EVBUFFER_LENGTH(buffer);
	result = engine_mux_send_frame(fd, ENGINE_MUX_ERROR, request_id,
	    engine_mux_revision, payload, payload_size);
	evbuffer_free(buffer);
	return (result);
}

static void
engine_mux_client_free(struct engine_mux_client *client)
{
	event_del(&client->event);
	TAILQ_REMOVE(&engine_mux_clients, client, entry);
	close(client->fd);
	free(client);
}

static void
engine_mux_client_event(__unused int fd, __unused short events, void *data)
{
	struct engine_mux_client *client = data;
	struct engine_mux_frame_header header;
	u_char *packet;
	ssize_t received;
	size_t packet_size;
	uint32_t payload_size;
	uint16_t type;
	uint64_t request_id, request_revision;
	const char *hello =
	    "{\"schema\":\"engine-mux/hello-v1\",\"server\":\"engine-mux\","
	    "\"tmux_baseline\":\"3.6b\",\"capabilities\":[\"layout-snapshot\"]}";

	packet_size = sizeof header + ENGINE_MUX_MAX_PAYLOAD;
	packet = xmalloc(packet_size);
	received = recv(client->fd, packet, packet_size, 0);
	if (received <= 0) {
		free(packet);
		engine_mux_client_free(client);
		return;
	}
	if ((size_t)received < sizeof header) {
		free(packet);
		if (engine_mux_send_error(client->fd, 0, "malformed-frame",
		    "frame header is truncated") != 0)
			engine_mux_client_free(client);
		return;
	}
	memcpy(&header, packet, sizeof header);
	request_id = engine_mux_be64_to_host(header.request_id);
	payload_size = ntohl(header.payload_length);
	if (ntohl(header.magic) != ENGINE_MUX_MAGIC) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id, "bad-magic",
		    "frame magic is invalid") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id,
		    "version-mismatch", "protocol version is unsupported") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (payload_size > ENGINE_MUX_MAX_PAYLOAD ||
	    sizeof header + payload_size != (size_t)received) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id,
		    "malformed-frame", "payload length does not match packet") != 0)
			engine_mux_client_free(client);
		return;
	}
	free(packet);
	type = ntohs(header.type);
	request_revision = engine_mux_be64_to_host(header.state_revision);
	if (type == ENGINE_MUX_CLIENT_HELLO) {
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SERVER_HELLO,
		    request_id, engine_mux_revision, hello, strlen(hello)) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_SNAPSHOT_REQUEST) {
		engine_mux_frontend_sync();
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SNAPSHOT,
		    request_id, engine_mux_revision, engine_mux_snapshot,
		    engine_mux_snapshot_size) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_COMMAND_REQUEST &&
	    request_revision != engine_mux_revision) {
		if (engine_mux_send_error(client->fd, request_id,
		    "stale-revision", "request revision is not current; request a complete snapshot") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (engine_mux_send_error(client->fd, request_id,
	    "unsupported-message", "message type is not implemented") != 0)
		engine_mux_client_free(client);
}

static void
engine_mux_accept(__unused int fd, __unused short events, __unused void *data)
{
	struct engine_mux_client *client;
	struct sockaddr_un address;
	socklen_t address_size, credentials_size;
	struct ucred credentials;
	int client_fd;

	address_size = sizeof address;
	client_fd = accept4(engine_mux_listener, (struct sockaddr *)&address,
	    &address_size, SOCK_NONBLOCK|SOCK_CLOEXEC);
	if (client_fd == -1)
		return;
	credentials_size = sizeof credentials;
	if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &credentials,
	    &credentials_size) == -1 || credentials.uid != getuid()) {
		engine_mux_send_error(client_fd, 0, "peer-rejected",
		    "frontend peer uid does not own the mux server");
		close(client_fd);
		return;
	}
	client = xcalloc(1, sizeof *client);
	client->fd = client_fd;
	TAILQ_INSERT_TAIL(&engine_mux_clients, client, entry);
	event_set(&client->event, client_fd, EV_READ|EV_PERSIST,
	    engine_mux_client_event, client);
	event_add(&client->event, NULL);
}

int
engine_mux_frontend_init(void)
{
	const char *runtime_dir, *socket_name;
	char *state_dir;
	struct sockaddr_un address;
	mode_t old_mask;

	socket_name = strrchr(socket_path, '/');
	if (socket_name == NULL)
		socket_name = socket_path;
	else
		socket_name++;
	if (strcmp(socket_name, "engine-mux") != 0)
		return (0);
	runtime_dir = getenv("XDG_RUNTIME_DIR");
	if (runtime_dir == NULL || *runtime_dir == '\0')
		xasprintf(&state_dir, "/run/user/%lu/engineos",
		    (unsigned long)getuid());
	else
		xasprintf(&state_dir, "%s/engineos", runtime_dir);
	if (mkdir(state_dir, 0700) == -1 && errno != EEXIST) {
		free(state_dir);
		return (-1);
	}
	if (chmod(state_dir, 0700) == -1) {
		free(state_dir);
		return (-1);
	}
	xasprintf(&engine_mux_socket_path, "%s/mux.sock", state_dir);
	free(state_dir);
	if (strlen(engine_mux_socket_path) >= sizeof address.sun_path) {
		errno = ENAMETOOLONG;
		return (-1);
	}
	engine_mux_listener = socket(AF_UNIX,
	    SOCK_SEQPACKET|SOCK_NONBLOCK|SOCK_CLOEXEC, 0);
	if (engine_mux_listener == -1)
		return (-1);
	memset(&address, 0, sizeof address);
	address.sun_family = AF_UNIX;
	strlcpy(address.sun_path, engine_mux_socket_path,
	    sizeof address.sun_path);
	unlink(engine_mux_socket_path);
	old_mask = umask(0077);
	if (bind(engine_mux_listener, (struct sockaddr *)&address,
	    sizeof address) == -1 || listen(engine_mux_listener, 16) == -1) {
		umask(old_mask);
		engine_mux_frontend_free();
		return (-1);
	}
	umask(old_mask);
	engine_mux_frontend_sync();
	event_set(&engine_mux_accept_event, engine_mux_listener,
	    EV_READ|EV_PERSIST, engine_mux_accept, NULL);
	event_add(&engine_mux_accept_event, NULL);
	log_debug("engine mux frontend listening on %s", engine_mux_socket_path);
	return (0);
}

void
engine_mux_frontend_free(void)
{
	struct engine_mux_client *client, *next;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next)
		engine_mux_client_free(client);
	if (engine_mux_listener != -1) {
		event_del(&engine_mux_accept_event);
		close(engine_mux_listener);
		engine_mux_listener = -1;
	}
	if (engine_mux_socket_path != NULL) {
		unlink(engine_mux_socket_path);
		free(engine_mux_socket_path);
		engine_mux_socket_path = NULL;
	}
	free(engine_mux_snapshot);
	engine_mux_snapshot = NULL;
	engine_mux_snapshot_size = 0;
}
