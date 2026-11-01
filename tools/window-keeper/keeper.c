/* Magic Kettle's window keeper: runs in a game's bottle beside the game, remembers where the player put the game's
 * window and how large they made it, and puts it back there at the next launch. Wine creates the game's windows
 * where the game asks, and games rarely remember; doing it from inside Wine needs no permission on the Mac.
 *
 * keeper.exe <state file> <game exe name>
 *
 * It waits for the game's process (by its file name), then follows the largest captioned window in the bottle
 * until that process ends. Full-screen, minimised and maximised windows are left alone. The state also holds the
 * screen size, so a saved place is only used on the same screen (a Retina switch changes it). */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

typedef struct { int x, y, w, h, screenW, screenH; } State;

static DWORD findProcess(const wchar_t *name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry = {sizeof entry};
    DWORD found = 0;
    for (BOOL more = Process32FirstW(snap, &entry); more; more = Process32NextW(snap, &entry)) {
        if (_wcsicmp(entry.szExeFile, name) == 0) { found = entry.th32ProcessID; break; }
    }
    CloseHandle(snap);
    return found;
}

typedef struct { HWND best; LONG area; DWORD self; } Search;

static BOOL CALLBACK consider(HWND window, LPARAM data) {
    Search *search = (Search *)data;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == search->self || !IsWindowVisible(window) || GetWindow(window, GW_OWNER)) return TRUE;
    LONG style = GetWindowLongW(window, GWL_STYLE);
    if ((style & WS_CAPTION) != WS_CAPTION) return TRUE;
    RECT rect;
    if (!GetWindowRect(window, &rect)) return TRUE;
    LONG area = (rect.right - rect.left) * (rect.bottom - rect.top);
    if (area > search->area && rect.right - rect.left >= 160 && rect.bottom - rect.top >= 120) {
        search->best = window;
        search->area = area;
    }
    return TRUE;
}

static HWND gameWindow(void) {
    Search search = {NULL, 0, GetCurrentProcessId()};
    EnumWindows(consider, (LPARAM)&search);
    return search.best;
}

static int load(const wchar_t *path, State *state) {
    FILE *file = _wfopen(path, L"r");
    if (!file) return 0;
    int read = fscanf(file, "%d %d %d %d %d %d", &state->x, &state->y, &state->w, &state->h, &state->screenW,
                      &state->screenH);
    fclose(file);
    return read == 6;
}

static void save(const wchar_t *path, const State *state) {
    wchar_t staging[MAX_PATH + 8];
    swprintf(staging, MAX_PATH + 8, L"%ls.new", path);
    FILE *file = _wfopen(staging, L"w");
    if (!file) return;
    fprintf(file, "%d %d %d %d %d %d\n", state->x, state->y, state->w, state->h, state->screenW, state->screenH);
    fclose(file);
    MoveFileExW(staging, path, MOVEFILE_REPLACE_EXISTING);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR commandLine, int show) {
    int count = 0;
    wchar_t **args = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!args || count < 3) return 1;
    const wchar_t *path = args[1], *exe = args[2];

    DWORD pid = 0;
    for (int tries = 0; tries < 120 && !(pid = findProcess(exe)); tries++) Sleep(500);
    HANDLE game = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : NULL;
    if (!game) return 0;

    State saved;
    int haveSaved = load(path, &saved);
    State last = {0};
    int restores = 0;
    DWORD restoredAt = 0;
    while (WaitForSingleObject(game, 500) == WAIT_TIMEOUT) {
        HWND window = gameWindow();
        if (!window || IsIconic(window) || IsZoomed(window)) continue;
        int screenW = GetSystemMetrics(SM_CXSCREEN), screenH = GetSystemMetrics(SM_CYSCREEN);
        RECT rect;
        if (!GetWindowRect(window, &rect)) continue;
        State now = {rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, screenW, screenH};
        if (now.w >= screenW && now.h >= screenH) continue;  /* full screen: the game's own */
        /* The place from last time, twice: games often centre their window just after creating it. */
        if (haveSaved && restores < 2 && saved.screenW == screenW && saved.screenH == screenH
            && (restores == 0 || GetTickCount() - restoredAt > 1200)) {
            SetWindowPos(window, NULL, saved.x, saved.y, saved.w, saved.h, SWP_NOZORDER | SWP_NOACTIVATE);
            restores++;
            restoredAt = GetTickCount();
            continue;
        }
        if (haveSaved && restores < 2 && saved.screenW == screenW && saved.screenH == screenH) continue;
        if (memcmp(&now, &last, sizeof now) != 0) {
            save(path, &now);
            last = now;
        }
    }
    return 0;
}
