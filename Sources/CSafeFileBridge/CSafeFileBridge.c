#include "CSafeFileBridge.h"

#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

struct ATSFCancellationFlag {
    atomic_bool cancelled;
};

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
    if(flag != NULL && atomic_load_explicit(&flag->cancelled, memory_order_acquire)) {
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

void ATSFCancellationFlagRelease(ATSFCancellationFlag *flag) {
    free(flag);
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

    char directory_path[PATH_MAX];
    if(fcntl(directory_fd, F_GETPATH, directory_path) != 0) {
        result.error_code = errno;
        return result;
    }

    char destination_path[PATH_MAX];
    int path_length = snprintf(
        destination_path,
        sizeof(destination_path),
        "%s/%s",
        directory_path,
        destination_name
    );
    if(path_length < 0 || (size_t)path_length >= sizeof(destination_path)) {
        result.error_code = ENAMETOOLONG;
        return result;
    }

    copyfile_state_t state = copyfile_state_alloc();
    if(state == NULL) {
        result.error_code = ENOMEM;
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
        copyfile_state_free(state);
        return result;
    }

    copyfile_flags_t flags = COPYFILE_ALL
        | COPYFILE_EXCL
        | COPYFILE_NOFOLLOW_SRC
        | COPYFILE_NOFOLLOW_DST
        | COPYFILE_RECURSIVE;
    int copy_result = copyfile(source_path, destination_path, state, flags);
    int copy_error = copy_result == 0 ? 0 : errno;

    int destination_fd = -1;
    if(copyfile_state_get(state, COPYFILE_STATE_DST_FD, &destination_fd) == 0
        && destination_fd >= 0) {
        result.destination_fd = dup(destination_fd);
    }
    copyfile_state_free(state);

    if(copy_result != 0) {
        result.error_code = copy_error == 0 ? EIO : copy_error;
        return result;
    }
    if(ATSFCancellationFlagIsCancelled(cancellation_flag)) {
        result.error_code = ECANCELED;
        return result;
    }
    if(result.destination_fd < 0) {
        result.destination_fd = openat(
            directory_fd,
            destination_name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        );
        if(result.destination_fd < 0) {
            result.error_code = errno;
            return result;
        }
    }

    result.status = 0;
    result.error_code = 0;
    return result;
}
