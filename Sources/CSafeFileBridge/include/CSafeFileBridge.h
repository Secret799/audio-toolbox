#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ATSFCancellationFlag ATSFCancellationFlag;

typedef struct {
    int32_t status;
    int32_t error_code;
    int32_t destination_fd;
} ATSFCopyResult;

ATSFCancellationFlag * _Nullable ATSFCancellationFlagCreate(void);
void ATSFCancellationFlagCancel(ATSFCancellationFlag * _Nullable flag);
bool ATSFCancellationFlagIsCancelled(const ATSFCancellationFlag * _Nullable flag);
void ATSFCancellationFlagRelease(ATSFCancellationFlag * _Nullable flag);

/// Copies a regular file into an already-open private directory. Destination
/// path is derived from the open directory_fd, and copyfile uses COPYFILE_ALL,
/// COPYFILE_EXCL, and NOFOLLOW flags with a cancellation status callback. The returned destination
/// fd is owned by the caller and must be closed, including on failure.
ATSFCopyResult ATSFCopyFileToDirectory(
    const char * _Nullable source_path,
    int32_t directory_fd,
    const char * _Nullable destination_name,
    ATSFCancellationFlag * _Nullable cancellation_flag
);

#ifdef __cplusplus
}
#endif
