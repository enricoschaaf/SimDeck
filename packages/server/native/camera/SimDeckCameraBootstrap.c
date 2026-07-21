#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char *sandbox_extension_issue_generic(const char *, uint32_t);

static char *SimDeckSandboxExtensionIssueGeneric(const char *extension_class, uint32_t flags) {
    if (extension_class && strcmp(extension_class, "com.apple.webkit.camera") == 0) {
        return strdup("simdeck-camera-sandbox-extension");
    }

    // Calls from the interposing image bind to the replacee. Dynamic lookup
    // resolves this replacement instead and recursively crashes Safari.
    return sandbox_extension_issue_generic(extension_class, flags);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} SimDeckSandboxExtensionIssueGenericInterpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)SimDeckSandboxExtensionIssueGeneric,
    (const void *)sandbox_extension_issue_generic,
};

static int IsCameraProcess(const char *executable) {
    const char *name = strrchr(executable, '/');
    name = name ? name + 1 : executable;
    if (strcmp(name, "MobileSafari") == 0 ||
        strcmp(name, "SafariViewService") == 0 ||
        strcmp(name, "com.apple.WebKit.GPU") == 0) {
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
