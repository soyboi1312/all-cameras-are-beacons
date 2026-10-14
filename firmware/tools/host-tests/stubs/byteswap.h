#pragma once
// <byteswap.h> is a glibc header. The vendored opendroneid/wifi.c includes it on every
// little-endian build that is not ESP-IDF, and macOS has no such header, so test_drone.cpp could
// not compile the real wifi.c (and tested a hand copy of odid_message_process_pack instead). The
// three macros wifi.c uses map onto the compiler builtins, which both clang and g++ provide.
#define bswap_16(x) __builtin_bswap16(x)
#define bswap_32(x) __builtin_bswap32(x)
#define bswap_64(x) __builtin_bswap64(x)
