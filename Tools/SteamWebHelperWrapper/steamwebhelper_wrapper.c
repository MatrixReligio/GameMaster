// steamwebhelper wrapper for Wine / Game Porting Toolkit.
//
// Steam's CEF-based web helper (steamwebhelper.exe) hangs under Wine because
// its GPU compositor never completes, so Steam's watchdog declares it "not
// responding" and restarts it every ~10 seconds forever. Steam already passes
// --no-sandbox --in-process-gpu --disable-gpu, but NOT --disable-gpu-compositing,
// which is the flag that stops the compositor hang.
//
// Those flags cannot be injected from steam.exe's own command line — Steam
// controls how it spawns the helper. So GameMaster renames the real helper to
// steamwebhelper_real.exe and drops this wrapper in its place. The wrapper
// forwards every original argument plus the compatibility flags to the real
// helper and mirrors its exit code.
//
// Approach adapted from the open-source Vineport project (MIT); reimplemented
// here. See NOTICE.

#include <windows.h>
#include <stdio.h>
#include <string.h>

// A single guard flag we can test for to detect our own re-invocation:
// CEF relaunches the helper for child processes, and we must not append the
// flags twice (or nest them across the process tree).
#define GUARD_FLAG "--disable-gpu-compositing"
#define EXTRA_FLAGS " --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing"
#define REAL_HELPER "steamwebhelper_real.exe"

static void quote_append(char *buffer, size_t size, int *offset, const char *arg) {
    int written;
    if (strchr(arg, ' ') != NULL) {
        written = snprintf(buffer + *offset, size - (size_t)*offset, " \"%s\"", arg);
    } else {
        written = snprintf(buffer + *offset, size - (size_t)*offset, " %s", arg);
    }
    if (written < 0 || (size_t)(*offset + written) >= size) {
        *offset = -1; // signal overflow
        return;
    }
    *offset += written;
}

int main(int argc, char *argv[]) {
    char exeDir[MAX_PATH];
    if (GetModuleFileNameA(NULL, exeDir, MAX_PATH) == 0) {
        return 1;
    }
    char *lastSlash = strrchr(exeDir, '\\');
    if (lastSlash != NULL) {
        *(lastSlash + 1) = '\0';
    }

    static char cmdline[32768];
    int offset = snprintf(cmdline, sizeof(cmdline), "\"%s%s\"", exeDir, REAL_HELPER);
    if (offset < 0 || (size_t)offset >= sizeof(cmdline)) {
        return 1;
    }

    int alreadyPatched = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], GUARD_FLAG) == 0) {
            alreadyPatched = 1;
        }
        quote_append(cmdline, sizeof(cmdline), &offset, argv[i]);
        if (offset < 0) {
            return 1;
        }
    }

    if (!alreadyPatched) {
        int written = snprintf(cmdline + offset, sizeof(cmdline) - (size_t)offset, "%s", EXTRA_FLAGS);
        if (written < 0 || (size_t)(offset + written) >= sizeof(cmdline)) {
            return 1;
        }
    }

    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD exitCode = 0;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)exitCode;
}
