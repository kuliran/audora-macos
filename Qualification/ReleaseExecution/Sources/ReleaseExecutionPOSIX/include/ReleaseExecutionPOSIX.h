#ifndef RELEASE_EXECUTION_POSIX_H
#define RELEASE_EXECUTION_POSIX_H

#include <stddef.h>
#include <sys/types.h>

int audora_open_atomic_partial(const char *path);
int audora_open_directory_for_sync(const char *path);
int audora_set_private_file_permissions(int descriptor);
ssize_t audora_write_bytes(int descriptor, const void *bytes, size_t count);
int audora_sync_descriptor(int descriptor);
int audora_close_descriptor(int descriptor);
int audora_rename_atomic(const char *source, const char *destination);

#endif
