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
void ATSFCancellationFlagRelease(ATSFCancellationFlag * _Nullable flag);

/// Uses F_FULLFSYNC when supported and falls back to fsync. Returns 0 or errno.
int32_t ATSFFullSyncFD(int32_t fd);

/// Opens source with O_NOFOLLOW, creates destination with openat(O_EXCL |
/// O_NOFOLLOW) relative to directory_fd, then copies all data and metadata with
/// fcopyfile(COPYFILE_ALL), then restores the exact source quarantine xattr
/// because macOS may rewrite it while copying. The returned destination fd uses
/// F_DUPFD_CLOEXEC and is owned by the caller, including on partial-copy failure.
ATSFCopyResult ATSFCopyFileToDirectory(
    const char * _Nullable source_path,
    int32_t directory_fd,
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
