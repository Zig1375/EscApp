/* An old game's full screen: switches the display to 640x480 (or `probe WxH`), covers it with a popup window and
 * draws a checkerboard with GDI for a few seconds, then reports what Windows told it. EscApp's tests use it to see
 * whether the Mac's own display changed and how large the game ends up on screen. `probe 640x480 d3d9` draws with
 * Direct3D 9 in exclusive full screen instead. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM a, LPARAM b) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(w, m, a, b);
}

static void paint(HWND w, int width, int height, int frame) {
    HDC dc = GetDC(w);
    for (int y = 0; y < height; y += 40)
        for (int x = 0; x < width; x += 40) {
            HBRUSH b = CreateSolidBrush(((x + y) / 40 + frame / 30) % 2 ? RGB(230, 120, 20) : RGB(20, 20, 60));
            RECT r = {x, y, x + 40, y + 40};
            FillRect(dc, &r, b);
            DeleteObject(b);
        }
    ReleaseDC(w, dc);
}

int main(int argc, char **argv) {
    int width = 640, height = 480;
    if (argc > 1) sscanf(argv[1], "%dx%d", &width, &height);
    /* `probe 640x480 window`: a fixed-size window instead of full screen, as many old games and their menus use. */
    char self[MAX_PATH];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    /* Or a copy named lowres-window.exe or lowres-d3d9.exe, for launchers that pass no arguments. */
    int windowed = (argc > 2 && !strcmp(argv[2], "window")) || strstr(self, "window") != NULL;
    int d3d = (argc > 2 && !strcmp(argv[2], "d3d9")) || strstr(self, "d3d9") != NULL;

    DEVMODEW mode = {0};
    mode.dmSize = sizeof mode;
    mode.dmPelsWidth = width;
    mode.dmPelsHeight = height;
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
    LONG change = d3d || windowed ? 0 : ChangeDisplaySettingsW(&mode, CDS_FULLSCREEN);

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"EscAppLowRes";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    HWND w;
    if (windowed) {
        RECT frame = {0, 0, width, height};
        DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE;
        AdjustWindowRect(&frame, style, FALSE);
        w = CreateWindowExW(0, L"EscAppLowRes", L"EscApp low-res probe", style, 100, 100, frame.right - frame.left,
                            frame.bottom - frame.top, NULL, NULL, wc.hInstance, NULL);
    } else {
        w = CreateWindowExW(WS_EX_TOPMOST, L"EscAppLowRes", L"EscApp low-res probe", WS_POPUP | WS_VISIBLE, 0, 0,
                            width, height, NULL, NULL, wc.hInstance, NULL);
    }

    IDirect3D9 *d3d9 = NULL;
    IDirect3DDevice9 *device = NULL;
    if (d3d) {
        d3d9 = Direct3DCreate9(D3D_SDK_VERSION);
        D3DPRESENT_PARAMETERS pp = {0};
        pp.Windowed = FALSE;
        pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
        pp.BackBufferWidth = width;
        pp.BackBufferHeight = height;
        pp.BackBufferFormat = D3DFMT_X8R8G8B8;
        pp.hDeviceWindow = w;
        if (FAILED(IDirect3D9_CreateDevice(d3d9, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, w,
                                           D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &device))) {
            printf("d3d9 device failed\n");
            return 2;
        }
    }

    DEVMODEW now = {0};
    now.dmSize = sizeof now;
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &now);
    RECT rect;
    GetWindowRect(w, &rect);
    printf("change %ld; display %lux%lu; window %ldx%ld at %ld,%ld; screen metrics %dx%d\n", change,
           now.dmPelsWidth, now.dmPelsHeight, rect.right - rect.left, rect.bottom - rect.top, rect.left, rect.top,
           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    fflush(stdout);

    for (int frame = 0; frame < 300; frame++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        if (device) {
            D3DCOLOR color = frame / 30 % 2 ? D3DCOLOR_XRGB(230, 120, 20) : D3DCOLOR_XRGB(20, 20, 60);
            IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, color, 1.0f, 0);
            D3DRECT box = {0, 0, width / 2, height / 2};
            IDirect3DDevice9_Clear(device, 1, &box, D3DCLEAR_TARGET, D3DCOLOR_XRGB(250, 250, 250), 1.0f, 0);
            IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        } else {
            paint(w, width, height, frame);
        }
        Sleep(16);
    }
    if (device) IDirect3DDevice9_Release(device);
    if (d3d9) IDirect3D9_Release(d3d9);
    ChangeDisplaySettingsW(NULL, 0);
    return 0;
}
