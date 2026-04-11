#include "czstd.h"
#include <zstd.h>

size_t czstd_decompress(void *dst, size_t dstCapacity, const void *src, size_t srcSize) {
    return ZSTD_decompress(dst, dstCapacity, src, srcSize);
}

int czstd_is_error(size_t code) {
    return ZSTD_isError(code) ? 1 : 0;
}
