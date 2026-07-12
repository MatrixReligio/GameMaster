// Minimal no-op replacement for Steam's 32-bit steamservice.exe.
// Steam's real service null-derefs under Wine's new WoW64, which pops a
// "Steam Service Error" dialog. Steam only needs the service for elevated
// installs, not for login/downloads. This stub registers a do-nothing service
// so SCM start succeeds, and exits 0 for any install/uninstall invocation.
#include <windows.h>

static SERVICE_STATUS_HANDLE g_ssh;
static SERVICE_STATUS g_status;

static void WINAPI handler(DWORD ctrl) {
    if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) {
        g_status.dwCurrentState = SERVICE_STOPPED;
        SetServiceStatus(g_ssh, &g_status);
    }
}

static void WINAPI svc_main(DWORD argc, LPSTR *argv) {
    (void)argc; (void)argv;
    g_ssh = RegisterServiceCtrlHandlerA("Steam Client Service", handler);
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = SERVICE_RUNNING;
    g_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    SetServiceStatus(g_ssh, &g_status);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    // If launched by the SCM (no console args of interest), serve; the dispatcher
    // returns immediately when not started as a service, so we just exit 0.
    SERVICE_TABLE_ENTRYA table[] = {
        { (LPSTR)"Steam Client Service", svc_main },
        { NULL, NULL }
    };
    StartServiceCtrlDispatcherA(table);
    return 0;
}
