#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "engineos-mux-client.h"

int main(int argc, char **argv) {
	if (argc != 4) {
		fprintf(stderr, "usage: %s SOCKET READY GO\n", argv[0]);
		return 2;
	}
	char error[256] = {0};
	struct engineos_mux_client client = {.fd = -1};
	if (!engineos_mux_client_connect(&client, argv[1], error, sizeof(error))) {
		fprintf(stderr, "connect failed: %s\n", error);
		return 1;
	}
	FILE *ready = fopen(argv[2], "w");
	if (ready == NULL) {
		fprintf(stderr, "ready marker: %s\n", strerror(errno));
		engineos_mux_client_destroy(&client);
		return 1;
	}
	fprintf(ready, "%%%u\n", client.pane_id);
	fclose(ready);
	struct stat status;
	struct timespec pause = {.tv_nsec = 1000000};
	for (unsigned int attempt = 0; attempt < 5000; attempt++) {
		if (stat(argv[3], &status) == 0)
			break;
		if (errno != ENOENT) {
			fprintf(stderr, "go marker: %s\n", strerror(errno));
			engineos_mux_client_destroy(&client);
			return 1;
		}
		nanosleep(&pause, NULL);
	}
	if (stat(argv[3], &status) != 0) {
		fprintf(stderr, "timed out waiting for go marker\n");
		engineos_mux_client_destroy(&client);
		return 1;
	}
	bool grid_changed = false;
	if (!engineos_mux_client_register_view(&client, 1, "startup-race",
			120, 40, 1920, 1080, 1000, true, &grid_changed,
			error, sizeof(error))) {
		fprintf(stderr, "view registration failed: %s\n", error);
		engineos_mux_client_destroy(&client);
		return 1;
	}
	printf("pane-race-recovered pane=%%%u revision=%llu\n", client.pane_id,
		(unsigned long long)client.revision);
	engineos_mux_client_destroy(&client);
	return 0;
}
