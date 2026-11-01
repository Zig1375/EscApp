/* Creates a Direct3D 11 device and swap chain, renders frames, and reports what it got.
   Prints "PROBE d3d11 OK ..." and exits 0, or "PROBE d3d11 FAIL ..." and exits 2. */
#define COBJMACROS
#include <d3d11.h>
#include "common.h"

int main(int argc, char **argv) {
    HWND window = probe_window(L"Plaviox D3D11 probe");
    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferCount = 2;
    desc.BufferDesc.Width = 640;
    desc.BufferDesc.Height = 480;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = window;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *swap = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                               &desc, &swap, &device, &level, &context);
    if (FAILED(hr)) { PROBE_REPORT("PROBE d3d11 FAIL create 0x%08lx", (unsigned long)hr); return 2; }

    char adapter[128] = "?";
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *dxgiAdapter = NULL;
    DXGI_ADAPTER_DESC adapterDesc;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi))
        && SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &dxgiAdapter))
        && SUCCEEDED(IDXGIAdapter_GetDesc(dxgiAdapter, &adapterDesc))) {
        WideCharToMultiByte(CP_UTF8, 0, adapterDesc.Description, -1, adapter, sizeof adapter, NULL, NULL);
    }

    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *target = NULL;
    IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back);
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &target);
    if (FAILED(hr)) { PROBE_REPORT("PROBE d3d11 FAIL target 0x%08lx", (unsigned long)hr); return 2; }

    int frames = probe_frames(argc, argv), drawn = 0;
    for (; drawn < frames && probe_pump(); drawn++) {
        float colour[4] = {0.66f, 0.29f, 0.03f, 1.0f};
        colour[1] += (drawn % 60) / 600.0f;
        ID3D11DeviceContext_ClearRenderTargetView(context, target, colour);
        hr = IDXGISwapChain_Present(swap, 1, 0);
        if (FAILED(hr)) { PROBE_REPORT("PROBE d3d11 FAIL present 0x%08lx", (unsigned long)hr); return 2; }
    }
    PROBE_REPORT("PROBE d3d11 OK bits=%d level=0x%x frames=%d adapter=%s", (int)sizeof(void *) * 8, level, drawn,
                 adapter);
    return 0;
}
