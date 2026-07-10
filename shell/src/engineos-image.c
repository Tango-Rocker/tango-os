#include "engineos-image.h"

#include <drm_fourcc.h>
#include <errno.h>
#include <stdio.h>
#include <jpeglib.h>
#include <limits.h>
#include <png.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-util.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>

struct engineos_pixel_buffer {
	struct wlr_buffer base;
	unsigned char *data;
	size_t stride;
	uint32_t format;
};

static void pixel_buffer_destroy(struct wlr_buffer *wlr_buffer) {
	struct engineos_pixel_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	free(buffer->data);
	wlr_buffer_finish(&buffer->base);
	free(buffer);
}

static bool pixel_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
		uint32_t flags, void **data, uint32_t *format, size_t *stride) {
	struct engineos_pixel_buffer *buffer =
		wl_container_of(wlr_buffer, buffer, base);
	if ((flags & WLR_BUFFER_DATA_PTR_ACCESS_READ) == 0) {
		return false;
	}
	*data = buffer->data;
	*format = buffer->format;
	*stride = buffer->stride;
	return true;
}

static void pixel_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer) {
	(void)wlr_buffer;
}

static const struct wlr_buffer_impl pixel_buffer_impl = {
	.destroy = pixel_buffer_destroy,
	.begin_data_ptr_access = pixel_buffer_begin_data_ptr_access,
	.end_data_ptr_access = pixel_buffer_end_data_ptr_access,
};

struct wlr_buffer *engineos_pixel_buffer_create(uint8_t *pixels,
		int width, int height) {
	struct engineos_pixel_buffer *buffer = calloc(1, sizeof(*buffer));
	if (buffer == NULL) {
		return NULL;
	}
	buffer->format = DRM_FORMAT_ABGR8888;
	buffer->stride = (size_t)width * 4;
	buffer->data = pixels;
	wlr_buffer_init(&buffer->base, &pixel_buffer_impl, width, height);
	return &buffer->base;
}

static bool image_dimensions_allowed(int width, int height,
		char *error, size_t error_size) {
	if (width <= 0 || height <= 0) {
		snprintf(error, error_size, "image dimensions are invalid");
		return false;
	}
	if (width > 4096 || height > 4096 ||
			(int64_t)width * (int64_t)height > 16777216) {
		snprintf(error, error_size, "image dimensions too large: %dx%d",
			width, height);
		return false;
	}
	return true;
}

static struct wlr_buffer *decode_png(const char *path, int *image_width,
		int *image_height, char *error, size_t error_size) {
	png_image image = {.version = PNG_IMAGE_VERSION};
	if (!png_image_begin_read_from_file(&image, path)) {
		snprintf(error, error_size, "PNG decode failed: %s", image.message);
		return NULL;
	}
	if (image.width > INT_MAX || image.height > INT_MAX ||
			!image_dimensions_allowed((int)image.width, (int)image.height,
				error, error_size)) {
		png_image_free(&image);
		return NULL;
	}
	image.format = PNG_FORMAT_RGBA;
	unsigned char *pixels = malloc(PNG_IMAGE_SIZE(image));
	if (pixels == NULL) {
		png_image_free(&image);
		snprintf(error, error_size, "failed to allocate PNG pixels");
		return NULL;
	}
	if (!png_image_finish_read(&image, NULL, pixels, 0, NULL)) {
		snprintf(error, error_size, "PNG decode failed: %s", image.message);
		free(pixels);
		png_image_free(&image);
		return NULL;
	}
	int width = (int)image.width;
	int height = (int)image.height;
	png_image_free(&image);
	struct wlr_buffer *buffer = engineos_pixel_buffer_create(pixels, width, height);
	if (buffer == NULL) {
		free(pixels);
		snprintf(error, error_size, "failed to allocate image buffer");
		return NULL;
	}
	*image_width = width;
	*image_height = height;
	return buffer;
}

struct engineos_jpeg_error {
	struct jpeg_error_mgr pub;
	jmp_buf jump;
};

static void jpeg_error_exit(j_common_ptr cinfo) {
	struct engineos_jpeg_error *error =
		(struct engineos_jpeg_error *)cinfo->err;
	longjmp(error->jump, 1);
}

static struct wlr_buffer *decode_jpeg(const char *path, int *image_width,
		int *image_height, char *error, size_t error_size) {
	FILE *file = fopen(path, "rb");
	if (file == NULL) {
		snprintf(error, error_size, "failed to open image: %s", strerror(errno));
		return NULL;
	}
	struct jpeg_decompress_struct cinfo = {0};
	struct engineos_jpeg_error jpeg_error = {0};
	unsigned char *volatile pixels = NULL;
	cinfo.err = jpeg_std_error(&jpeg_error.pub);
	jpeg_error.pub.error_exit = jpeg_error_exit;
	if (setjmp(jpeg_error.jump)) {
		free((void *)pixels);
		jpeg_destroy_decompress(&cinfo);
		fclose(file);
		snprintf(error, error_size, "JPEG decode failed");
		return NULL;
	}

	jpeg_create_decompress(&cinfo);
	jpeg_stdio_src(&cinfo, file);
	jpeg_read_header(&cinfo, TRUE);
	cinfo.out_color_space = JCS_RGB;
	jpeg_start_decompress(&cinfo);
	if (cinfo.output_width > INT_MAX || cinfo.output_height > INT_MAX ||
			!image_dimensions_allowed((int)cinfo.output_width,
				(int)cinfo.output_height, error, error_size)) {
		jpeg_destroy_decompress(&cinfo);
		fclose(file);
		return NULL;
	}

	int width = (int)cinfo.output_width;
	int height = (int)cinfo.output_height;
	size_t stride = (size_t)width * 4;
	pixels = malloc(stride * (size_t)height);
	if (pixels == NULL) {
		jpeg_destroy_decompress(&cinfo);
		fclose(file);
		snprintf(error, error_size, "failed to allocate JPEG pixels");
		return NULL;
	}
	JSAMPARRAY scanline = (*cinfo.mem->alloc_sarray)((j_common_ptr)&cinfo,
		JPOOL_IMAGE, (JDIMENSION)width * 3, 1);
	while (cinfo.output_scanline < cinfo.output_height) {
		JDIMENSION y = cinfo.output_scanline;
		jpeg_read_scanlines(&cinfo, scanline, 1);
		unsigned char *dst = (unsigned char *)pixels + (size_t)y * stride;
		for (int x = 0; x < width; x++) {
			dst[(size_t)x * 4 + 0] = scanline[0][(size_t)x * 3 + 0];
			dst[(size_t)x * 4 + 1] = scanline[0][(size_t)x * 3 + 1];
			dst[(size_t)x * 4 + 2] = scanline[0][(size_t)x * 3 + 2];
			dst[(size_t)x * 4 + 3] = 255;
		}
	}
	jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);
	fclose(file);

	struct wlr_buffer *buffer =
		engineos_pixel_buffer_create((unsigned char *)pixels, width, height);
	if (buffer == NULL) {
		free((void *)pixels);
		snprintf(error, error_size, "failed to allocate image buffer");
		return NULL;
	}
	*image_width = width;
	*image_height = height;
	return buffer;
}

struct wlr_buffer *engineos_image_decode(const char *path,
		int *image_width, int *image_height, char *error, size_t error_size) {
	FILE *file = fopen(path, "rb");
	if (file == NULL) {
		snprintf(error, error_size, "failed to open image: %s", strerror(errno));
		return NULL;
	}
	unsigned char signature[8] = {0};
	bool has_signature =
		fread(signature, 1, sizeof(signature), file) == sizeof(signature);
	fclose(file);
	if (!has_signature) {
		snprintf(error, error_size, "image file is too short");
		return NULL;
	}
	if (png_sig_cmp(signature, 0, sizeof(signature)) == 0) {
		return decode_png(path, image_width, image_height, error, error_size);
	}
	if (signature[0] == 0xff && signature[1] == 0xd8 &&
			signature[2] == 0xff) {
		return decode_jpeg(path, image_width, image_height, error, error_size);
	}
	snprintf(error, error_size, "unsupported image type");
	return NULL;
}
