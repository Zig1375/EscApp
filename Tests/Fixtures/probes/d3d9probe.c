/* Creates a Direct3D 9 device, renders frames, and reports what it got.
   Prints "PROBE d3d9 OK ..." and exits 0, or "PROBE d3d9 FAIL ..." and exits 2. */
#define COBJMACROS
#include <d3d9.h>
#include "common.h"

int main(int argc, char **argv) {
    HWND window = probe_window(L"Plaviox D3D9 probe");
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { PROBE_REPORT("PROBE d3d9 FAIL Direct3DCreate9"); return 2; }

    D3DADAPTER_IDENTIFIER9 id;
    char adapter[128] = "?";
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        snprintf(adapter, sizeof adapter, "%s", id.Description);
    }

    D3DPRESENT_PARAMETERS params = {0};
    params.Windowed = TRUE;
    params.SwapEffect = D3DSWAPEFFECT_DISCARD;
    params.BackBufferFormat = D3DFMT_UNKNOWN;
    params.hDeviceWindow = window;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &params, &device);
    if (FAILED(hr)) { PROBE_REPORT("PROBE d3d9 FAIL create 0x%08lx", (unsigned long)hr); return 2; }

    int frames = probe_frames(argc, argv), drawn = 0;
    for (; drawn < frames && probe_pump(); drawn++) {
        IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(168, 75 + drawn % 60, 7), 1.0f, 0);
        IDirect3DDevice9_BeginScene(device);
        IDirect3DDevice9_EndScene(device);
        hr = IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { PROBE_REPORT("PROBE d3d9 FAIL present 0x%08lx", (unsigned long)hr); return 2; }
    }
    PROBE_REPORT("PROBE d3d9 OK bits=%d frames=%d adapter=%s", (int)sizeof(void *) * 8, drawn, adapter);
    return 0;
}
