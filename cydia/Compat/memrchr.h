#pragma once

/*
 * Darwin/iOS does not expose the GNU memrchr() extension used by the
 * historical APT string_view implementation bundled with Cydia's apt64.
 * Keep the APT source itself untouched and provide the same reverse-byte
 * search semantics locally for the on-device build.
 */
#include <stddef.h>

static inline const void *cydia_memrchr(const void *memory, int value, size_t size) {
    const unsigned char *bytes = (const unsigned char *) memory;
    const unsigned char needle = (unsigned char) value;

    while (size != 0) {
        --size;
        if (bytes[size] == needle)
            return bytes + size;
    }

    return NULL;
}

#ifndef memrchr
#define memrchr cydia_memrchr
#endif
