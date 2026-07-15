#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result returned by ATReadMetadata.
///
/// Every non-null string is owned by this result and must be released exactly
/// once by passing the result to ATFreeReadResult. Empty tags are represented
/// by null pointers.
typedef struct {
    int32_t status;
    char * _Nullable title;
    char * _Nullable artist;
    char * _Nullable album;
    double duration_seconds;
    char * _Nullable error_message;
} ATReadResult;

/// Reads metadata from path. A zero status indicates success.
ATReadResult ATReadMetadata(const char * _Nullable path);

/// Releases all strings owned by result and resets its fields to zero/null.
/// Passing null is allowed.
void ATFreeReadResult(ATReadResult * _Nullable result);

#ifdef __cplusplus
}
#endif
