/* Shared by the probes: a plain window to render into, and a frame budget from the command line. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK probe_proc(HWND w, UINT m, WPARAM a, LPARAM b) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(w, m, a, b);
}

static HWND probe_window(const wchar_t *title) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = probe_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ExePortProbe";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    HWND w = CreateWindowW(L"ExePortProbe", title, WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT,
                           640, 480, NULL, NULL, wc.hInstance, NULL);
    return w;
}

/* Pumps messages; returns 0 once the window was closed. */
static int probe_pump(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 1;
}

/* `probe.exe 90` renders 90 frames; default 120 (about two seconds). */
static int probe_frames(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 120;
    return n > 0 ? n : 120;
}

#define PROBE_REPORT(...) do { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
