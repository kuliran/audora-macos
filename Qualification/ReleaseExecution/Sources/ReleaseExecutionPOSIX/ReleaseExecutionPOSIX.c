#include "ReleaseExecutionPOSIX.h"

#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

int audora_open_atomic_partial(const char *path) {
    return open(
        path,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    );
}

int audora_open_directory_for_sync(const char *path) {
    return open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
}

int audora_set_private_file_permissions(int descriptor) {
    return fchmod(descriptor, S_IRUSR | S_IWUSR);
}

ssize_t audora_write_bytes(int descriptor, const void *bytes, size_t count) {
    return write(descriptor, bytes, count);
}

int audora_sync_descriptor(int descriptor) {
    return fsync(descriptor);
}

int audora_close_descriptor(int descriptor) {
    return close(descriptor);
}

int audora_rename_atomic(const char *source, const char *destination) {
    return rename(source, destination);
}
