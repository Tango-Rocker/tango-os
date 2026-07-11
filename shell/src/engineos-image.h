#ifndef ENGINEOS_IMAGE_H
#define ENGINEOS_IMAGE_H

#include <stddef.h>
#include <stdint.h>

struct wlr_buffer;

struct wlr_buffer *engineos_image_decode(const char *path,
	int *image_width, int *image_height, char *error, size_t error_size);
struct wlr_buffer *engineos_image_decode_memory(const uint8_t *data, size_t size,
	const char *mime, int *image_width, int *image_height,
	char *error, size_t error_size);
struct wlr_buffer *engineos_pixel_buffer_create(uint8_t *pixels,
	int width, int height);

#endif
