/* A game with a fixed-size window (640x480 client): `probe gdi|d3d9|d3d11 [seconds] [script [width height]]`.
 * Draws a checkerboard and a white box under the mouse, and once a second prints what the game sees: its client
 * size, the screen size, WM_SIZE count, and where the mouse is in client coordinates. Used to check that stretching
 * the window on the Mac (Magic Kettle's Wine, StretchWindows) doesn't change anything the game sees, and that the mouse
 * still lands where it points. `script` runs the checks by itself: it resizes the window the way the Mac driver does
 * when the player drags its corner (width and height are the Mac display's pixels, 3456x2234 by default), then
 * changes its own size, goes full screen and back, and prints the scale after each step. A copy whose name contains
 * "aware" is per-monitor DPI aware, like Unity games. */
#define COBJMACROS
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <d3d9.h>
#include <d3d11_1.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* What the Mac driver does when the player resizes a window: NtUserSetRawWindowPos (win32u's
 * NtUserCallHwndParam code 29 in Wine 11.20), with a rect in raw (Mac) pixels. */
typedef ULONG_PTR (WINAPI *call_hwnd_param_fn)(HWND, ULONG_PTR, DWORD);
struct raw_pos { RECT rect; UINT flags; BOOL internal; };
static int physical_w = 3456, physical_h = 2234;

static RECT to_raw(RECT v) {
    double cw = GetSystemMetrics(SM_CXSCREEN), ch = GetSystemMetrics(SM_CYSCREEN), s;
    s = physical_w * ch <= physical_h * cw ? physical_w / cw : physical_h / ch;
    RECT r = {(LONG)((v.left - cw / 2) * s + physical_w / 2.0 + 0.5), (LONG)((v.top - ch / 2) * s + physical_h / 2.0 + 0.5),
              (LONG)((v.right - cw / 2) * s + physical_w / 2.0 + 0.5), (LONG)((v.bottom - ch / 2) * s + physical_h / 2.0 + 0.5)};
    return r;
}

static void player_resize(HWND w, double factor) {
    call_hwnd_param_fn call = (void *)GetProcAddress(GetModuleHandleA("win32u.dll"), "NtUserCallHwndParam");
    RECT v, r;
    GetWindowRect(w, &v);
    r = to_raw(v);
    struct raw_pos p = {{r.left, r.top, r.left + (LONG)((r.right - r.left) * factor), r.top + (LONG)((r.bottom - r.top) * factor)},
                        SWP_NOACTIVATE | SWP_NOZORDER, FALSE};
    printf("player resize x%.2f: raw %ldx%ld -> %ldx%ld\n", factor, r.right - r.left, r.bottom - r.top,
           p.rect.right - p.rect.left, p.rect.bottom - p.rect.top);
    call(w, (ULONG_PTR)&p, 29);
}

static void game_resize(HWND w, int cw, int ch) {
    RECT f = {0, 0, cw, ch};
    AdjustWindowRect(&f, GetWindowLongW(w, GWL_STYLE), FALSE);
    printf("game resize to client %dx%d\n", cw, ch);
    SetWindowPos(w, NULL, 0, 0, f.right - f.left, f.bottom - f.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

static void report(HWND w, const char *what) {
    RECT c, v, r;
    DEVMODEW m = {.dmSize = sizeof m};
    GetClientRect(w, &c);
    GetWindowRect(w, &v);
    r = to_raw(v);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &m);
    printf("  %s: client %ldx%ld, screen %dx%d (mode %lux%lu), window raw %ldx%ld at %ld,%ld, scale %.3f\n", what,
           c.right, c.bottom, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), m.dmPelsWidth,
           m.dmPelsHeight, r.right - r.left, r.bottom - r.top, r.left, r.top,
           (double)(r.right - r.left) / (v.right - v.left));
    fflush(stdout);
}

static int sizes, mouse_x = -1, mouse_y = -1;

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM a, LPARAM b) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    if (m == WM_SIZE) sizes++;
    if (m == WM_MOUSEMOVE) { mouse_x = (short)LOWORD(b); mouse_y = (short)HIWORD(b); }
    return DefWindowProcW(w, m, a, b);
}

int main(int argc, char **argv) {
    const char *kind = argc > 1 ? argv[1] : "gdi";
    /* `aware` in the name: per-monitor DPI aware, like Unity games */
    char self_name[MAX_PATH];
    GetModuleFileNameA(NULL, self_name, MAX_PATH);
    if (strstr(self_name, "aware")) SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    int seconds = argc > 2 ? atoi(argv[2]) : 120, width = 640, height = 480;

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"MagicKettleStretch";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    RECT frame = {0, 0, width, height};
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE;
    AdjustWindowRect(&frame, style, FALSE);
    HWND w = CreateWindowExW(0, L"MagicKettleStretch", L"Magic Kettle stretch probe", style, 100, 100,
                             frame.right - frame.left, frame.bottom - frame.top, NULL, NULL, wc.hInstance, NULL);

    IDirect3DDevice9 *d9 = NULL;
    ID3D11Device *d11 = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *chain = NULL;
    ID3D11RenderTargetView *view = NULL;
    ID3D11DeviceContext1 *ctx1 = NULL;
    if (!strcmp(kind, "d3d9")) {
        IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
        D3DPRESENT_PARAMETERS pp = {0};
        pp.Windowed = TRUE;
        pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
        pp.BackBufferWidth = width;
        pp.BackBufferHeight = height;
        pp.BackBufferFormat = D3DFMT_X8R8G8B8;
        pp.hDeviceWindow = w;
        if (!d3d || FAILED(IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, w,
                                                   D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &d9))) {
            printf("d3d9 device failed\n");
            return 2;
        }
    } else if (!strcmp(kind, "d3d11")) {
        DXGI_SWAP_CHAIN_DESC sd = {0};
        sd.BufferCount = 2;
        sd.BufferDesc.Width = width;
        sd.BufferDesc.Height = height;
        sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.OutputWindow = w;
        sd.SampleDesc.Count = 1;
        sd.Windowed = TRUE;
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
        if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                                 &sd, &chain, &d11, NULL, &ctx))) {
            printf("d3d11 device failed\n");
            return 2;
        }
        ID3D11Texture2D *back;
        IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&back);
        ID3D11Device_CreateRenderTargetView(d11, (ID3D11Resource *)back, NULL, &view);
        ID3D11Texture2D_Release(back);
        ID3D11DeviceContext_QueryInterface(ctx, &IID_ID3D11DeviceContext1, (void **)&ctx1);
    }

    int script = argc > 3 && !strcmp(argv[3], "script");
    if (argc > 5) { physical_w = atoi(argv[4]); physical_h = atoi(argv[5]); }
    printf("PROBE stretch %s start\n", kind);
    fflush(stdout);
    for (int frame = 0; frame < seconds * 60; frame++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) frame = seconds * 60;
            DispatchMessageW(&msg);
        }
        int bx = mouse_x - 10, by = mouse_y - 10;
        if (d9) {
            IDirect3DDevice9_Clear(d9, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(20, 20, 60), 1.0f, 0);
            for (int y = 0; y < height; y += 40)
                for (int x = (y / 40) % 2 * 40; x < width; x += 80) {
                    D3DRECT r = {x, y, x + 40, y + 40};
                    IDirect3DDevice9_Clear(d9, 1, &r, D3DCLEAR_TARGET, D3DCOLOR_XRGB(230, 120, 20), 1.0f, 0);
                }
            if (mouse_x >= 0) {
                D3DRECT r = {bx, by, bx + 20, by + 20};
                IDirect3DDevice9_Clear(d9, 1, &r, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 255, 255), 1.0f, 0);
            }
            IDirect3DDevice9_Present(d9, NULL, NULL, NULL, NULL);
        } else if (d11) {
            float dark[4] = {20 / 255.f, 20 / 255.f, 60 / 255.f, 1}, orange[4] = {230 / 255.f, 120 / 255.f, 20 / 255.f, 1};
            float white[4] = {1, 1, 1, 1};
            ID3D11DeviceContext_ClearRenderTargetView(ctx, view, dark);
            if (ctx1) {
                D3D11_RECT squares[16 * 12];
                int n = 0;
                for (int y = 0; y < height; y += 40)
                    for (int x = (y / 40) % 2 * 40; x < width; x += 80) {
                        D3D11_RECT r = {x, y, x + 40, y + 40};
                        squares[n++] = r;
                    }
                ID3D11DeviceContext1_ClearView(ctx1, (ID3D11View *)view, orange, squares, n);
                if (mouse_x >= 0) {
                    D3D11_RECT r = {bx, by, bx + 20, by + 20};
                    ID3D11DeviceContext1_ClearView(ctx1, (ID3D11View *)view, white, &r, 1);
                }
            }
            IDXGISwapChain_Present(chain, 1, 0);
        } else {
            HDC dc = GetDC(w);
            for (int y = 0; y < height; y += 40)
                for (int x = 0; x < width; x += 40) {
                    HBRUSH b = CreateSolidBrush((x + y) / 40 % 2 ? RGB(230, 120, 20) : RGB(20, 20, 60));
                    RECT r = {x, y, x + 40, y + 40};
                    FillRect(dc, &r, b);
                    DeleteObject(b);
                }
            if (mouse_x >= 0) {
                RECT r = {bx, by, bx + 20, by + 20};
                FillRect(dc, &r, GetStockObject(WHITE_BRUSH));
            }
            ReleaseDC(w, dc);
            Sleep(16);
        }
        if (script && frame % 120 == 60) {
            int step = frame / 120, before = sizes;
            switch (step) {
            case 0: report(w, "start"); break;
            case 1: player_resize(w, 2.0); report(w, "player x2"); printf("  WM_SIZE during player resize: %d\n", sizes - before); break;
            case 2: player_resize(w, 0.8); report(w, "player x0.8"); printf("  WM_SIZE during player resize: %d\n", sizes - before); break;
            case 3: player_resize(w, 1.0 / 0.8); report(w, "player back"); break;
            case 4: game_resize(w, 800, 600); report(w, "game 800x600"); break;
            case 5: game_resize(w, 1600, 1200); report(w, "game 1600x1200 (bigger than the box)"); break;
            case 6: game_resize(w, 1280, 720); report(w, "game 1280x720 (16:9)"); break;
            case 7: game_resize(w, 640, 480); report(w, "game 640x480 again"); break;
            case 8: player_resize(w, 10.0); report(w, "player x10 (beyond the screen)"); break;
            case 9: player_resize(w, 0.1); report(w, "player x0.1 (below game size)"); break;
            case 10: player_resize(w, 2.0); report(w, "player x2 again"); break;
            case 11: {
                DEVMODEW m = {.dmSize = sizeof m, .dmPelsWidth = 800, .dmPelsHeight = 600, .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT};
                LONG r = ChangeDisplaySettingsW(&m, CDS_FULLSCREEN);
                SetWindowLongW(w, GWL_STYLE, WS_POPUP | WS_VISIBLE);
                SetWindowPos(w, HWND_TOPMOST, 0, 0, 800, 600, SWP_FRAMECHANGED);
                printf("game fullscreen 800x600: %ld\n", r);
                report(w, "fullscreen");
                break;
            }
            case 12: {
                ChangeDisplaySettingsW(NULL, 0);
                SetWindowLongW(w, GWL_STYLE, style);
                RECT f = {0, 0, 640, 480};
                AdjustWindowRect(&f, style, FALSE);
                SetWindowPos(w, HWND_NOTOPMOST, 100, 100, f.right - f.left, f.bottom - f.top, SWP_FRAMECHANGED);
                printf("game back to a window\n");
                report(w, "windowed again");
                break;
            }
            case 13: frame = seconds * 60; break;
            }
            fflush(stdout);
        }
        if (!script && frame % 60 == 0) {
            RECT client;
            POINT cursor;
            GetClientRect(w, &client);
            GetCursorPos(&cursor);
            ScreenToClient(w, &cursor);
            printf("t=%d client %ldx%ld screen %dx%d sizes %d mousemove %d,%d cursor %ld,%ld\n", frame / 60,
                   client.right, client.bottom, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), sizes,
                   mouse_x, mouse_y, cursor.x, cursor.y);
            fflush(stdout);
        }
    }
    printf("PROBE stretch %s OK\n", kind);
    return 0;
}
