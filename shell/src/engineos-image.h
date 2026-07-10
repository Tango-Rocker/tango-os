#ifndef ENGINEOS_IMAGE_H
#define ENGINEOS_IMAGE_H

#include <stddef.h>

struct wlr_buffer;

struct wlr_buffer *engineos_image_decode(const char *path,
	int *image_width, int *image_height, char *error, size_t error_size);

#endif
