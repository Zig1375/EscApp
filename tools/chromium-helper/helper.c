// Stands in for a Chromium helper (Steam's steamwebhelper.exe) and starts the real one, renamed to
// <name>_real.exe, with Chromium's GPU work moved into the helper's own process.
//
// Out of process, Chromium's GPU process draws into a window that belongs to the browser process. Wine's Mac
// driver can't show that: Steam's sign-in window stays black. In-process, software-composited drawing shows.
//
// Build: scripts/build-chromium-helper.sh (needs `brew install mingw-w64`).
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

#define EXTRA_FLAGS L" --disable-gpu --disable-gpu-compositing --in-process-gpu"

// EscApp tells its wrapper from the vendor's helper by this text (`ChromiumHelper.marker`).
__attribute__((used)) static const char marker[] = "escapp-chromium-helper/1";

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    wchar_t real[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (length == 0 || length + 5 >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    wchar_t *dot = wcsrchr(real, L'.');
    if (!slash || !dot || dot < slash || _wcsicmp(dot, L".exe") != 0) return 1;
    wcscpy(dot, L"_real.exe");

    // The arguments as given, without the program's own name.
    const wchar_t *rest = GetCommandLineW();
    if (*rest == L'"') {
        rest++;
        while (*rest && *rest != L'"') rest++;
        if (*rest) rest++;
    } else {
        while (*rest && *rest != L' ') rest++;
    }

    size_t size = wcslen(real) + wcslen(rest) + wcslen(EXTRA_FLAGS) + 4;
    wchar_t *line = calloc(size, sizeof(wchar_t));
    if (!line) return 1;
    swprintf(line, size, L"\"%ls\"%ls%ls", real, rest, EXTRA_FLAGS);

    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process;
    if (!CreateProcessW(real, line, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) return 1;
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(process.hProcess, &code);
    return (int)code;
}
