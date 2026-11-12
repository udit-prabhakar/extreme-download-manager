/* Native-messaging launcher: preserve framed stdio, without invoking a shell. */
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX], resolved[PATH_MAX], application[PATH_MAX];
    uint32_t capacity = sizeof executable;
    if (argc > 8 || _NSGetExecutablePath(executable, &capacity) != 0 || !realpath(executable, resolved)) return 126;
    char *separator = strrchr(resolved, '/');
    if (!separator) return 126;
    *separator = '\0';
    int length = snprintf(application, sizeof application, "%s/ExtremeDownloadManager", resolved);
    if (length < 0 || (size_t)length >= sizeof application) return 126;
    char **arguments = calloc((size_t)argc + 2, sizeof(char *));
    if (!arguments) return 126;
    arguments[0] = application;
    arguments[1] = "--browser-native-host";
    for (int index = 1; index < argc; ++index) arguments[index + 1] = argv[index];
    execv(application, arguments);
    fputs("Extreme Download Manager could not start. Reinstall the complete app.\n", stderr);
    free(arguments);
    return 127;
}
