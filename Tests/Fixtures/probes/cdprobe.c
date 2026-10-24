/* An old game that checks for its CD: it looks for a CD-ROM drive labelled PROBEGAME holding GAME\probegame.exe.
 * Without it, it asks for the disc in a message box and quits once the box is closed (by itself after 10 s, so
 * tests don't wait for a click: Wine ignores MessageBoxTimeout's timeout); with it, it shows a window for a few
 * seconds. EscApp's tests use it for "the game asks for its disc". */
#include <windows.h>
#include <stdio.h>

static DWORD WINAPI close_box(void *unused) {
    Sleep(10000);
    HWND box = FindWindowA("#32770", "Probe Game");
    if (box) PostMessageA(box, WM_COMMAND, IDOK, 0);
    return 0;
}

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM a, LPARAM b) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(w, m, a, b);
}

int main(void) {
    char root[] = "A:\\", label[64], file[MAX_PATH];
    for (char letter = 'C'; letter <= 'Z'; letter++) {
        root[0] = letter;
        if (GetDriveTypeA(root) != DRIVE_CDROM) continue;
        if (!GetVolumeInformationA(root, label, sizeof label, NULL, NULL, NULL, NULL, 0)) continue;
        snprintf(file, sizeof file, "%sGAME\\probegame.exe", root);
        printf("cd drive %c: label %s\n", letter, label);
        if (strcmp(label, "PROBEGAME") || GetFileAttributesA(file) == INVALID_FILE_ATTRIBUTES) continue;
        printf("disc found in %c:\n", letter);
        fflush(stdout);
        WNDCLASSA wc = {0};
        wc.lpfnWndProc = proc;
        wc.hInstance = GetModuleHandleA(NULL);
        wc.lpszClassName = "EscAppCdProbe";
        RegisterClassA(&wc);
        CreateWindowA("EscAppCdProbe", "EscApp CD probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480,
                      NULL, NULL, wc.hInstance, NULL);
        for (int i = 0; i < 200; i++) {
            MSG msg;
            while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
            Sleep(15);
        }
        return 0;
    }
    printf("no disc\n");
    fflush(stdout);
    CloseHandle(CreateThread(NULL, 0, close_box, NULL, 0, NULL));
    MessageBoxA(NULL, "Please insert the Probe Game CD into your CD-ROM drive.", "Probe Game", MB_OK | MB_ICONERROR);
    return 1;
}
