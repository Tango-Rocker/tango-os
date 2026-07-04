# Midnight Commander Local Patch Notes

This directory tracks local MC patch material that is not yet wired into a
repo-owned package build.

- `patches/engineos-quick-view-preview.patch` is deployed on bare-metal
  EngineDev as `mc 4.8.33-2`. It makes MC Quick View selection changes invoke
  `engine-image-preview --quick-view FILE --panel right` for PNG/JPEG files and
  `engine-image-preview --hide` for other selections while leaving MC's normal
  internal quick-view loading intact.
