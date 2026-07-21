#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int IsCameraProcess(const char *executable) {
    const char *name = strrchr(executable, '/');
    name = name ? name + 1 : executable;
    if (strcmp(name, "com.apple.WebKit.GPU") == 0) {
        return 1;
    }
    return strstr(executable, "/Containers/Bundle/Application/") != NULL;
}

static void LogFailure(const char *message) {
    if (getenv("SIMDECK_CAMERA_DEBUG") == NULL) {
        return;
    }
    dprintf(STDERR_FILENO, "SimDeck camera bootstrap: %s\n", message);
}

__attribute__((constructor)) static void InstallCameraInjector(void) {
    char executable[PATH_MAX];
    uint32_t executable_size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0 ||
        !IsCameraProcess(executable)) {
        return;
    }

    Dl_info bootstrap;
    if (dladdr((const void *)&InstallCameraInjector, &bootstrap) == 0 ||
        bootstrap.dli_fname == NULL) {
        LogFailure("could not resolve the bootstrap path");
        return;
    }

    const char *separator = strrchr(bootstrap.dli_fname, '/');
    if (separator == NULL) {
        LogFailure("bootstrap has no containing directory");
        return;
    }

    char injector[PATH_MAX];
    int directory_length = (int)(separator - bootstrap.dli_fname);
    int written = snprintf(injector, sizeof(injector),
                           "%.*s/libSimDeckCameraInjector.dylib",
                           directory_length, bootstrap.dli_fname);
    if (written < 0 || written >= (int)sizeof(injector)) {
        LogFailure("injector path is too long");
        return;
    }

    if (dlopen(injector, RTLD_NOW | RTLD_LOCAL) == NULL) {
        const char *error = dlerror();
        LogFailure(error ? error : "could not load the injector");
    }
}
