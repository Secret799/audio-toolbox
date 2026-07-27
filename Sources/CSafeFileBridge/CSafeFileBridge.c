#include "CSafeFileBridge.h"

#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

struct ATSFCancellationFlag {
    atomic_bool cancelled;
    atomic_uint callback_delay_microseconds;
    atomic_int quarantine_synchronization_error_for_testing;
};

typedef struct {
    uint8_t *bytes;
    size_t size;
    size_t capacity;
} ATSFBuffer;

static int ATSFBufferReserve(ATSFBuffer *buffer, size_t additional) {
    if(additional > SIZE_MAX - buffer->size) {
        errno = EOVERFLOW;
        return -1;
    }
    size_t required = buffer->size + additional;
    if(required <= buffer->capacity) {
        return 0;
    }
    size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
    while(capacity < required) {
        if(capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }
    uint8_t *bytes = realloc(buffer->bytes, capacity);
    if(bytes == NULL) {
        return -1;
    }
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return 0;
}

static int ATSFBufferAppend(ATSFBuffer *buffer, const void *bytes, size_t size) {
    if(ATSFBufferReserve(buffer, size) != 0) {
        return -1;
    }
    if(size > 0) {
        memcpy(buffer->bytes + buffer->size, bytes, size);
    }
    buffer->size += size;
    return 0;
}

static int ATSFBufferAppendUInt64(ATSFBuffer *buffer, uint64_t value) {
    uint8_t encoded[8];
    for(size_t index = 0; index < sizeof(encoded); ++index) {
        encoded[index] = (uint8_t)(value >> (index * 8));
    }
    return ATSFBufferAppend(buffer, encoded, sizeof(encoded));
}

static int ATSFCompareStrings(const void *left, const void *right) {
    const char *const *left_string = left;
    const char *const *right_string = right;
    return strcmp(*left_string, *right_string);
}

static int ATSFSynchronizeExtendedAttribute(
    int source_fd,
    int destination_fd,
    const char *name
) {
    ssize_t value_size = fgetxattr(source_fd, name, NULL, 0, 0, 0);
    if(value_size < 0) {
        if(errno != ENOATTR) {
            return errno;
        }
        if(fremovexattr(destination_fd, name, 0) == 0 || errno == ENOATTR) {
            return 0;
        }
        return errno;
    }

    void *value = value_size == 0 ? NULL : malloc((size_t)value_size);
    if(value_size > 0 && value == NULL) {
        return ENOMEM;
    }
    if(value_size > 0
        && fgetxattr(
            source_fd,
            name,
            value,
            (size_t)value_size,
            0,
            0
        ) != value_size) {
        int error_code = errno == 0 ? EIO : errno;
        free(value);
        return error_code;
    }

    int set_result = fsetxattr(
        destination_fd,
        name,
        value,
        (size_t)value_size,
        0,
        0
    );
    int error_code = set_result == 0 ? 0 : (errno == 0 ? EIO : errno);
    free(value);
    return error_code;
}

static int ATSFCopyStatusCallback(
    int what,
    int stage,
    copyfile_state_t state,
    const char *source,
    const char *destination,
    void *context
) {
    (void)what;
    (void)stage;
    (void)state;
    (void)source;
    (void)destination;

    ATSFCancellationFlag *flag = context;
    if(flag == NULL) {
        return COPYFILE_CONTINUE;
    }
    if(atomic_load_explicit(&flag->cancelled, memory_order_acquire)) {
        errno = ECANCELED;
        return COPYFILE_QUIT;
    }
    uint32_t delay = atomic_load_explicit(
        &flag->callback_delay_microseconds,
        memory_order_relaxed
    );
    if(delay > 0) {
        usleep(delay);
    }
    if(atomic_load_explicit(&flag->cancelled, memory_order_acquire)) {
        errno = ECANCELED;
        return COPYFILE_QUIT;
    }
    return COPYFILE_CONTINUE;
}

ATSFCancellationFlag *ATSFCancellationFlagCreate(void) {
    ATSFCancellationFlag *flag = malloc(sizeof(*flag));
    if(flag == NULL) {
        return NULL;
    }
    atomic_init(&flag->cancelled, false);
    atomic_init(&flag->callback_delay_microseconds, 0);
    atomic_init(&flag->quarantine_synchronization_error_for_testing, 0);
    return flag;
}

void ATSFCancellationFlagCancel(ATSFCancellationFlag *flag) {
    if(flag != NULL) {
        atomic_store_explicit(&flag->cancelled, true, memory_order_release);
    }
}

bool ATSFCancellationFlagIsCancelled(const ATSFCancellationFlag *flag) {
    return flag != NULL
        && atomic_load_explicit(&flag->cancelled, memory_order_acquire);
}

void ATSFCancellationFlagSetCallbackDelayForTesting(
    ATSFCancellationFlag *flag,
    uint32_t microseconds
) {
    if(flag != NULL) {
        atomic_store_explicit(
            &flag->callback_delay_microseconds,
            microseconds,
            memory_order_relaxed
        );
    }
}

void ATSFCancellationFlagSetQuarantineSynchronizationErrorForTesting(
    ATSFCancellationFlag *flag,
    int32_t error_code
) {
    if(flag != NULL) {
        atomic_store_explicit(
            &flag->quarantine_synchronization_error_for_testing,
            error_code,
            memory_order_relaxed
        );
    }
}

void ATSFCancellationFlagRelease(ATSFCancellationFlag *flag) {
    free(flag);
}

int32_t ATSFFullSyncFD(int32_t fd) {
    if(fd < 0) {
        return EBADF;
    }

    if(fcntl(fd, F_FULLFSYNC) == 0) {
        return 0;
    }

    int full_sync_error = errno;
    if(full_sync_error != EINVAL
        && full_sync_error != ENOTSUP
        && full_sync_error != ENOTTY) {
        return full_sync_error;
    }

    int result;
    do {
        result = fsync(fd);
    } while(result != 0 && errno == EINTR);
    return result == 0 ? 0 : errno;
}

int32_t ATSFPathForFD(int32_t fd, char *buffer, size_t buffer_size) {
    if(fd < 0 || buffer == NULL || buffer_size < MAXPATHLEN) {
        return EINVAL;
    }
    return fcntl(fd, F_GETPATH, buffer) == 0 ? 0 : errno;
}

static ATSFCopyResult ATSFCopyOpenFileToDirectory(
    int source_fd,
    int32_t destination_directory_fd,
    const char *destination_name,
    ATSFCancellationFlag *cancellation_flag
) {
    ATSFCopyResult result = {-1, EINVAL, -1};
    if(source_fd < 0 || destination_name == NULL || destination_directory_fd < 0) {
        return result;
    }
    if(ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        result.error_code = ECANCELED;
        return result;
    }

    int destination_fd = openat(
        destination_directory_fd,
        destination_name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0600
    );
    if(destination_fd < 0) {
        result.error_code = errno;
        return result;
    }

    copyfile_state_t state = copyfile_state_alloc();
    if(state == NULL) {
        result.error_code = ENOMEM;
        result.destination_fd = fcntl(destination_fd, F_DUPFD_CLOEXEC, 0);
        close(destination_fd);
        return result;
    }

    if(copyfile_state_set(
            state,
            COPYFILE_STATE_STATUS_CB,
            (const void *)ATSFCopyStatusCallback
        ) != 0
        || copyfile_state_set(
            state,
            COPYFILE_STATE_STATUS_CTX,
            cancellation_flag
        ) != 0) {
        result.error_code = errno == 0 ? EIO : errno;
        result.destination_fd = fcntl(destination_fd, F_DUPFD_CLOEXEC, 0);
        copyfile_state_free(state);
        close(destination_fd);
        return result;
    }

    int copy_result = fcopyfile(source_fd, destination_fd, state, COPYFILE_ALL);
    int copy_error = copy_result == 0 ? 0 : errno;
    if(copy_result == 0 && !ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        int forced_error = cancellation_flag == NULL
            ? 0
            : atomic_load_explicit(
                &cancellation_flag->quarantine_synchronization_error_for_testing,
                memory_order_relaxed
            );
        copy_error = forced_error != 0
            ? forced_error
            : ATSFSynchronizeExtendedAttribute(
                source_fd,
                destination_fd,
                "com.apple.quarantine"
            );
        if(copy_error == EACCES || copy_error == EPERM) {
            // App Sandbox may preserve quarantine semantics while rewriting its
            // timestamp and adding the system-managed 0x0200 flag. Swift snapshot
            // validation permits only those changes and rejects every other one.
            copy_error = 0;
        } else if(copy_error != 0) {
            copy_result = -1;
        }
    }
    result.destination_fd = destination_fd < 0
        ? -1
        : fcntl(destination_fd, F_DUPFD_CLOEXEC, 0);
    copyfile_state_free(state);
    if(destination_fd >= 0) {
        close(destination_fd);
    }

    if(ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        result.error_code = ECANCELED;
        return result;
    }
    if(copy_result != 0) {
        result.error_code = copy_error == 0 ? EIO : copy_error;
        return result;
    }
    if(result.destination_fd < 0) {
        result.error_code = errno == 0 ? EIO : errno;
        return result;
    }

    result.status = 0;
    result.error_code = 0;
    return result;
}

ATSFCopyResult ATSFCopyFileToDirectory(
    const char *source_path,
    int32_t directory_fd,
    const char *destination_name,
    ATSFCancellationFlag *cancellation_flag
) {
    ATSFCopyResult result = {-1, EINVAL, -1};
    if(source_path == NULL || destination_name == NULL || directory_fd < 0) {
        return result;
    }
    if(ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        result.error_code = ECANCELED;
        return result;
    }
    int source_fd = open(source_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if(source_fd < 0) {
        result.error_code = errno;
        return result;
    }
    result = ATSFCopyOpenFileToDirectory(
        source_fd,
        directory_fd,
        destination_name,
        cancellation_flag
    );
    close(source_fd);
    return result;
}

ATSFCopyResult ATSFCopyFileBetweenDirectories(
    int32_t source_directory_fd,
    const char *source_name,
    int32_t destination_directory_fd,
    const char *destination_name,
    ATSFCancellationFlag *cancellation_flag
) {
    ATSFCopyResult result = {-1, EINVAL, -1};
    if(source_directory_fd < 0
        || source_name == NULL
        || destination_directory_fd < 0
        || destination_name == NULL) {
        return result;
    }
    if(ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        result.error_code = ECANCELED;
        return result;
    }
    int source_fd = openat(
        source_directory_fd,
        source_name,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    );
    if(source_fd < 0) {
        result.error_code = errno;
        return result;
    }
    result = ATSFCopyOpenFileToDirectory(
        source_fd,
        destination_directory_fd,
        destination_name,
        cancellation_flag
    );
    close(source_fd);
    return result;
}

ATSFMetadataBlob ATSFMetadataSnapshotForFD(int32_t fd) {
    ATSFMetadataBlob result = {-1, EINVAL, NULL, 0};
    if(fd < 0) {
        return result;
    }

    ATSFBuffer buffer = {NULL, 0, 0};
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if(acl == NULL) {
        if(errno != ENOENT && errno != EINVAL) {
            result.error_code = errno;
            return result;
        }
        if(ATSFBufferAppendUInt64(&buffer, 0) != 0) {
            result.error_code = errno == 0 ? ENOMEM : errno;
            free(buffer.bytes);
            return result;
        }
    } else {
        ssize_t acl_length = 0;
        char *acl_text = acl_to_text(acl, &acl_length);
        acl_free(acl);
        if(acl_text == NULL || acl_length < 0) {
            result.error_code = errno == 0 ? EIO : errno;
            acl_free(acl_text);
            free(buffer.bytes);
            return result;
        }
        int append_result = ATSFBufferAppendUInt64(
            &buffer,
            (uint64_t)acl_length
        );
        if(append_result == 0) {
            append_result = ATSFBufferAppend(
                &buffer,
                acl_text,
                (size_t)acl_length
            );
        }
        acl_free(acl_text);
        if(append_result != 0) {
            result.error_code = errno == 0 ? ENOMEM : errno;
            free(buffer.bytes);
            return result;
        }
    }

    ssize_t names_size = flistxattr(fd, NULL, 0, 0);
    if(names_size < 0) {
        result.error_code = errno;
        free(buffer.bytes);
        return result;
    }
    char *names = names_size == 0 ? NULL : malloc((size_t)names_size);
    if(names_size > 0 && names == NULL) {
        result.error_code = ENOMEM;
        free(buffer.bytes);
        return result;
    }
    if(names_size > 0 && flistxattr(fd, names, (size_t)names_size, 0) != names_size) {
        result.error_code = errno == 0 ? EIO : errno;
        free(names);
        free(buffer.bytes);
        return result;
    }

    size_t name_count = 0;
    for(ssize_t offset = 0; offset < names_size;) {
        size_t length = strlen(names + offset);
        ++name_count;
        offset += (ssize_t)length + 1;
    }
    char **sorted_names = name_count == 0
        ? NULL
        : malloc(name_count * sizeof(*sorted_names));
    if(name_count > 0 && sorted_names == NULL) {
        result.error_code = ENOMEM;
        free(names);
        free(buffer.bytes);
        return result;
    }
    size_t name_index = 0;
    for(ssize_t offset = 0; offset < names_size;) {
        sorted_names[name_index++] = names + offset;
        offset += (ssize_t)strlen(names + offset) + 1;
    }
    qsort(sorted_names, name_count, sizeof(*sorted_names), ATSFCompareStrings);

    if(ATSFBufferAppendUInt64(&buffer, (uint64_t)name_count) != 0) {
        result.error_code = errno == 0 ? ENOMEM : errno;
        free(sorted_names);
        free(names);
        free(buffer.bytes);
        return result;
    }

    for(size_t index = 0; index < name_count; ++index) {
        const char *name = sorted_names[index];
        size_t name_length = strlen(name);
        ssize_t value_size = fgetxattr(fd, name, NULL, 0, 0, 0);
        if(value_size < 0) {
            result.error_code = errno;
            free(sorted_names);
            free(names);
            free(buffer.bytes);
            return result;
        }
        uint8_t *value = value_size == 0 ? NULL : malloc((size_t)value_size);
        if(value_size > 0 && value == NULL) {
            result.error_code = ENOMEM;
            free(sorted_names);
            free(names);
            free(buffer.bytes);
            return result;
        }
        if(value_size > 0
            && fgetxattr(fd, name, value, (size_t)value_size, 0, 0) != value_size) {
            result.error_code = errno == 0 ? EIO : errno;
            free(value);
            free(sorted_names);
            free(names);
            free(buffer.bytes);
            return result;
        }

        int append_result = ATSFBufferAppendUInt64(
            &buffer,
            (uint64_t)name_length
        );
        if(append_result == 0) {
            append_result = ATSFBufferAppend(&buffer, name, name_length);
        }
        if(append_result == 0) {
            append_result = ATSFBufferAppendUInt64(
                &buffer,
                (uint64_t)value_size
            );
        }
        if(append_result == 0) {
            append_result = ATSFBufferAppend(
                &buffer,
                value,
                (size_t)value_size
            );
        }
        free(value);
        if(append_result != 0) {
            result.error_code = errno == 0 ? ENOMEM : errno;
            free(sorted_names);
            free(names);
            free(buffer.bytes);
            return result;
        }
    }

    free(sorted_names);
    free(names);
    result.status = 0;
    result.error_code = 0;
    result.bytes = buffer.bytes;
    result.size = buffer.size;
    return result;
}

void ATSFMetadataBlobRelease(ATSFMetadataBlob *blob) {
    if(blob == NULL) {
        return;
    }
    free(blob->bytes);
    blob->bytes = NULL;
    blob->size = 0;
    blob->status = 0;
    blob->error_code = 0;
}
