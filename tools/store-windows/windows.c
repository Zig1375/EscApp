/* EscApp's window check for a store's bottle: prints one line per top-level window Windows counts as shown,
 * minimised ones included, then exits.
 *
 * store-windows.exe
 *
 * A store's client hides its window when the player closes it and goes on running (Steam then opened a chat
 * window by itself when a message came). From the Mac a hidden window and a minimised one look the same: both
 * are off screen. Inside Wine they differ, so EscApp asks here before it quits the client.
 *
 * Each line is "<process id>\t<1 if minimised>\t<title>". */
#include <windows.h>
#include <stdio.h>

static BOOL CALLBACK print(HWND window, LPARAM data) {
    (void)data;
    if (!IsWindowVisible(window)) return TRUE;
    wchar_t title[256] = L"";
    GetWindowTextW(window, title, 256);
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    char utf8[1024] = "";
    WideCharToMultiByte(CP_UTF8, 0, title, -1, utf8, sizeof utf8, NULL, NULL);
    printf("%lu\t%d\t%s\n", (unsigned long)pid, IsIconic(window) ? 1 : 0, utf8);
    return TRUE;
}

int wmain(void) {
    EnumWindows(print, 0);
    return 0;
}
