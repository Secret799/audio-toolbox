#pragma once

#include <stdbool.h>
#include <stddef.h>
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

typedef struct {
    int32_t status;
    int32_t error_code;
    uint8_t * _Nullable bytes;
    size_t size;
} ATSFMetadataBlob;

ATSFCancellationFlag * _Nullable ATSFCancellationFlagCreate(void);
void ATSFCancellationFlagCancel(ATSFCancellationFlag * _Nullable flag);
bool ATSFCancellationFlagIsCancelled(const ATSFCancellationFlag * _Nullable flag);
void ATSFCancellationFlagSetCallbackDelayForTesting(
    ATSFCancellationFlag * _Nullable flag,
    uint32_t microseconds
);
void ATSFCancellationFlagSetQuarantineSynchronizationErrorForTesting(
    ATSFCancellationFlag * _Nullable flag,
    int32_t error_code
);
void ATSFCancellationFlagRelease(ATSFCancellationFlag * _Nullable flag);

/// Uses F_FULLFSYNC when supported and falls back to fsync. Returns 0 or errno.
int32_t ATSFFullSyncFD(int32_t fd);
int32_t ATSFPathForFD(int32_t fd, char * _Nullable buffer, size_t buffer_size);

/// Opens source with O_NOFOLLOW, creates destination with openat(O_EXCL |
/// O_NOFOLLOW) relative to directory_fd, then copies all data and metadata with
/// fcopyfile(COPYFILE_ALL), then attempts to restore the exact source quarantine
/// xattr. App Sandbox may deny that restoration; Swift snapshot validation then
/// permits only the system-managed timestamp rewrite and 0x0200 flag addition.
/// The returned destination fd uses F_DUPFD_CLOEXEC and is owned by the caller,
/// including on partial-copy failure.
ATSFCopyResult ATSFCopyFileToDirectory(
    const char * _Nullable source_path,
    int32_t directory_fd,
    const char * _Nullable destination_name,
    ATSFCancellationFlag * _Nullable cancellation_flag
);

/// Opens both source and destination relative to owned directory descriptors.
/// Destination creation remains exclusive and never overwrites an existing entry.
ATSFCopyResult ATSFCopyFileBetweenDirectories(
    int32_t source_directory_fd,
    const char * _Nullable source_name,
    int32_t destination_directory_fd,
    const char * _Nullable destination_name,
    ATSFCancellationFlag * _Nullable cancellation_flag
);

/// Returns a canonical fd-based serialization of the extended ACL and every
/// extended attribute, including com.apple.ResourceFork when present.
ATSFMetadataBlob ATSFMetadataSnapshotForFD(int32_t fd);
void ATSFMetadataBlobRelease(ATSFMetadataBlob * _Nullable blob);

#ifdef __cplusplus
}
#endif
