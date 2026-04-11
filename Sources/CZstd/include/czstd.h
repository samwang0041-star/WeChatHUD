#ifndef CZSTD_H
#define CZSTD_H

#include <stddef.h>

/// Decompress a zstd-compressed buffer.
/// Returns the number of bytes written to dst, or an error code (check czstd_is_error).
size_t czstd_decompress(void *dst, size_t dstCapacity, const void *src, size_t srcSize);

/// Returns non-zero if the given return value from czstd_decompress is an error.
int czstd_is_error(size_t code);

#endif
