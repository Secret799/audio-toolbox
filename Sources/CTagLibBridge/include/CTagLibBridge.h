#pragma once

#include <stdbool.h>
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

/// Result returned by ATWriteMetadata.
///
/// A non-null error message is owned by this result and must be released
/// exactly once by passing the result to ATFreeWriteResult.
typedef struct {
    int32_t status;
    char * _Nullable error_message;
} ATWriteResult;

/// Reads metadata from path. A zero status indicates success.
ATReadResult ATReadMetadata(const char * _Nullable path);

/// Releases all strings owned by result and resets its fields to zero/null.
/// Passing null is allowed.
void ATFreeReadResult(ATReadResult * _Nullable result);

/// Returns whether path is a writable, valid TagLib file with an accessible tag.
/// This probe never saves or changes the file.
bool ATCanWriteMetadata(const char * _Nullable path);

/// Writes only the fields whose pointers are non-null. A zero status indicates
/// that TagLib saved the file successfully.
ATWriteResult ATWriteMetadata(
    const char * _Nullable path,
    const char * _Nullable artist_or_null,
    const char * _Nullable album_or_null
);

/// Releases all strings owned by result and resets its fields to zero/null.
/// Passing null is allowed.
void ATFreeWriteResult(ATWriteResult * _Nullable result);

#ifdef __cplusplus
}
#endif
