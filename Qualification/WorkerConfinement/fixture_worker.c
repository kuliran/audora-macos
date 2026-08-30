#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const char *const allowed_environment[] = {
    "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "HF_HOME",
    "HF_HUB_CACHE", "TRANSFORMERS_CACHE", "TORCH_HOME", "TMPDIR",
    "PATH", "LANG", "LC_ALL", "PYTHONNOUSERSITE", "PYTHONSAFEPATH",
    "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "TOKENIZERS_PARALLELISM",
};

static void emit_failure(const char *code) {
  printf("{\"v\":1,\"type\":\"failed\",\"error\":{\"code\":\"%s\",\"retryable\":false}}\n", code);
}

static bool environment_key_allowed(const char *entry) {
  const char *separator = strchr(entry, '=');
  if (separator == NULL) {
    return false;
  }
  size_t length = (size_t)(separator - entry);
  size_t count = sizeof(allowed_environment) / sizeof(allowed_environment[0]);
  for (size_t index = 0; index < count; index++) {
    if (strlen(allowed_environment[index]) == length &&
        strncmp(entry, allowed_environment[index], length) == 0) {
      return true;
    }
  }
  return false;
}

static bool environment_is_allowlisted(void) {
  size_t seen = 0;
  for (char **entry = environ; *entry != NULL; entry++) {
    if (!environment_key_allowed(*entry)) {
      return false;
    }
    seen++;
  }
  return seen == sizeof(allowed_environment) / sizeof(allowed_environment[0]) &&
         getenv("AUDORA_LEAK_SENTINEL") == NULL;
}

static bool directory_is_empty(const char *path) {
  DIR *directory = opendir(path);
  if (directory == NULL) {
    return false;
  }
  bool empty = true;
  struct dirent *entry = NULL;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
      empty = false;
      break;
    }
  }
  closedir(directory);
  return empty;
}

static bool working_directory_is_scoped(void) {
  char path[4096];
  if (getcwd(path, sizeof(path)) == NULL) {
    return false;
  }
  const char *basename = strrchr(path, '/');
  return basename != NULL && strcmp(basename + 1, "job") == 0;
}

static void emit_hello(bool mismatch) {
  printf("{\"v\":1,\"type\":\"hello\",\"protocolVersion\":1,"
         "\"runtimeVersion\":\"synthetic-runtime-v1\","
         "\"modelRevision\":\"synthetic-model-revision-v1\","
         "\"patchId\":\"%s\",\"environmentAllowlisted\":%s,"
         "\"homeEmpty\":%s,\"configEmpty\":%s,"
         "\"workingDirectoryScoped\":%s,\"ambientSentinelAbsent\":%s}\n",
         mismatch ? "wrong-patch" : "synthetic-progress-patch-v1",
         environment_is_allowlisted() ? "true" : "false",
         directory_is_empty(getenv("HOME")) ? "true" : "false",
         directory_is_empty(getenv("XDG_CONFIG_HOME")) ? "true" : "false",
         working_directory_is_scoped() ? "true" : "false",
         getenv("AUDORA_LEAK_SENTINEL") == NULL ? "true" : "false");
}

static bool network_is_denied(int port) {
  int descriptor = socket(AF_INET, SOCK_STREAM, 0);
  if (descriptor < 0) {
    return errno == EPERM || errno == EACCES;
  }
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int result = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
  int saved_errno = errno;
  close(descriptor);
  return result < 0 && (saved_errno == EPERM || saved_errno == EACCES);
}

static bool read_exact(const char *path, const char *expected) {
  FILE *stream = fopen(path, "rb");
  if (stream == NULL) {
    return false;
  }
  char buffer[128] = {0};
  size_t count = fread(buffer, 1, sizeof(buffer) - 1, stream);
  fclose(stream);
  return count == strlen(expected) && memcmp(buffer, expected, count) == 0;
}

static bool write_all(int descriptor, const char *value, size_t count) {
  while (count > 0) {
    ssize_t written = write(descriptor, value, count);
    if (written <= 0) {
      return false;
    }
    value += written;
    count -= (size_t)written;
  }
  return true;
}

static void cached_inference(const char *model_root, int port) {
  char model_path[4096];
  snprintf(model_path, sizeof(model_path), "%s/model-id.txt", model_root);
  if (!read_exact(model_path, "synthetic-model-revision-v1\n") ||
      !read_exact("input/audio.synthetic", "synthetic-audio-evidence\n")) {
    emit_failure("CACHED_INPUT_UNAVAILABLE");
    return;
  }
  if (!network_is_denied(port)) {
    emit_failure("NETWORK_AVAILABLE");
    return;
  }

  static const char result[] = "{\"schemaVersion\":1,\"synthetic\":true}\n";
  int descriptor = open("output/result.partial", O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (descriptor < 0 || !write_all(descriptor, result, sizeof(result) - 1) ||
      fsync(descriptor) != 0 || close(descriptor) != 0 ||
      rename("output/result.partial", "output/result.json") != 0) {
    if (descriptor >= 0) {
      close(descriptor);
    }
    emit_failure("STAGING_WRITE_FAILED");
    return;
  }
  puts("{\"v\":1,\"type\":\"candidate_ready\","
       "\"result\":\"output/result.json\","
       "\"sha256\":\"fc0599fc9d4390035bada17bcafee3fb7114954e97d89a21af0a4f923ac1d572\","
       "\"networkDenied\":true}");
}

static void denied_read(const char *path, const char *denied_code) {
  int descriptor = open(path, O_RDONLY);
  if (descriptor < 0 && (errno == EPERM || errno == EACCES)) {
    emit_failure(denied_code);
    return;
  }
  if (descriptor >= 0) {
    close(descriptor);
  }
  emit_failure("FORBIDDEN_READ_AVAILABLE");
}

static void denied_write(const char *path, const char *denied_code) {
  int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (descriptor < 0 && (errno == EPERM || errno == EACCES || errno == EROFS)) {
    emit_failure(denied_code);
    return;
  }
  if (descriptor >= 0) {
    close(descriptor);
  }
  emit_failure("FORBIDDEN_WRITE_AVAILABLE");
}

static void resource_open_files(void) {
  int descriptors[128];
  size_t count = 0;
  for (; count < sizeof(descriptors) / sizeof(descriptors[0]); count++) {
    char path[128];
    snprintf(path, sizeof(path), "output/resource-%zu", count);
    descriptors[count] = open(path, O_WRONLY | O_CREAT, 0600);
    if (descriptors[count] < 0) {
      break;
    }
  }
  int saved_errno = errno;
  for (size_t index = 0; index < count; index++) {
    close(descriptors[index]);
  }
  emit_failure(count < sizeof(descriptors) / sizeof(descriptors[0]) && saved_errno == EMFILE
                   ? "RESOURCE_LIMIT_REACHED"
                   : "RESOURCE_LIMIT_MISSING");
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  const char *mode = NULL;
  const char *model_root = NULL;
  const char *unrelated_root = NULL;
  int port = 9;
  for (int index = 1; index + 1 < argc; index += 2) {
    if (strcmp(argv[index], "--mode") == 0) {
      mode = argv[index + 1];
    } else if (strcmp(argv[index], "--model-root") == 0) {
      model_root = argv[index + 1];
    } else if (strcmp(argv[index], "--probe-port") == 0) {
      port = atoi(argv[index + 1]);
    } else if (strcmp(argv[index], "--unrelated-root") == 0) {
      unrelated_root = argv[index + 1];
    }
  }
  if (mode == NULL || model_root == NULL || unrelated_root == NULL) {
    return 64;
  }
  if (strcmp(mode, "no-hello") == 0) {
    for (;;) pause();
  }
  emit_hello(strcmp(mode, "bad-handshake") == 0);

  char request[1024];
  if (fgets(request, sizeof(request), stdin) == NULL ||
      strcmp(request, "{\"v\":1,\"type\":\"run\"}\n") != 0) {
    emit_failure("MALFORMED_REQUEST");
    return 2;
  }

  if (strcmp(mode, "cached-inference") == 0) {
    cached_inference(model_root, port);
  } else if (strcmp(mode, "read-unrelated") == 0) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/read.txt", unrelated_root);
    denied_read(path, "READ_DENIED");
  } else if (strcmp(mode, "traversal") == 0) {
    denied_read("input/../../unrelated/read.txt", "TRAVERSAL_DENIED");
  } else if (strcmp(mode, "symlink-read") == 0) {
    denied_read("input/unrelated-link", "SYMLINK_ESCAPE_DENIED");
  } else if (strcmp(mode, "write-unrelated") == 0) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/write.txt", unrelated_root);
    denied_write(path, "WRITE_DENIED");
  } else if (strcmp(mode, "write-runtime") == 0) {
    denied_write("../runtime/runtime-marker.txt", "RUNTIME_READ_ONLY");
  } else if (strcmp(mode, "write-model") == 0) {
    denied_write("../model/model-id.txt", "MODEL_READ_ONLY");
  } else if (strcmp(mode, "network") == 0) {
    emit_failure(network_is_denied(port) ? "NETWORK_DENIED" : "NETWORK_AVAILABLE");
  } else if (strcmp(mode, "process") == 0) {
    pid_t child = fork();
    if (child < 0 && (errno == EPERM || errno == EACCES)) {
      emit_failure("PROCESS_CREATION_DENIED");
    } else {
      if (child == 0) _exit(0);
      if (child > 0) waitpid(child, NULL, 0);
      emit_failure("PROCESS_CREATION_AVAILABLE");
    }
  } else if (strcmp(mode, "resource-open-files") == 0) {
    resource_open_files();
  } else if (strcmp(mode, "resource-output") == 0) {
    for (int index = 0; index < 16384; index++) fputc('X', stdout);
  } else if (strcmp(mode, "stderr-output") == 0) {
    for (int index = 0; index < 16384; index++) fputc('E', stderr);
  } else if (strcmp(mode, "bad-output") == 0) {
    puts("not-json");
  } else if (strcmp(mode, "crash") == 0) {
    abort();
  } else if (strcmp(mode, "hang") == 0) {
    for (;;) pause();
  } else {
    emit_failure("UNKNOWN_SYNTHETIC_MODE");
  }
  return 0;
}
