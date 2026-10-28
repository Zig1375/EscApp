/* Creates a Direct3D 12 device, command queue and flip-model swap chain, clears and presents frames, then copies
   the last frame back and checks its colour, so a layer that accepts calls without rendering still fails.
   `d3d12-x64.exe offscreen` renders into a texture instead, with no window, for runs without a display.
   Prints "PROBE d3d12 OK ..." and exits 0, or "PROBE d3d12 FAIL ..." and exits 2. */
#define COBJMACROS
/* mingw only declares the struct-returning methods (GetCPUDescriptorHandleForHeapStart) as inline wrappers. */
#define WIDL_C_INLINE_WRAPPERS
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <string.h>
#include "common.h"

#define WIDTH 640
#define HEIGHT 480
#define BUFFERS 2
#define CHECK(step, expr) do { HRESULT hr_ = (expr); \
    if (FAILED(hr_)) { PROBE_REPORT("PROBE d3d12 FAIL %s 0x%08lx", step, (unsigned long)hr_); return 2; } } while (0)

static ID3D12Fence *fence;
static HANDLE fenceEvent;
static UINT64 fenceValue;

static int wait_for_gpu(ID3D12CommandQueue *queue) {
    fenceValue++;
    if (FAILED(ID3D12CommandQueue_Signal(queue, fence, fenceValue))) return 0;
    if (ID3D12Fence_GetCompletedValue(fence) < fenceValue) {
        ID3D12Fence_SetEventOnCompletion(fence, fenceValue, fenceEvent);
        if (WaitForSingleObject(fenceEvent, 5000) != WAIT_OBJECT_0) return 0;
    }
    return 1;
}

static void transition(ID3D12GraphicsCommandList *list, ID3D12Resource *resource, D3D12_RESOURCE_STATES from,
                       D3D12_RESOURCE_STATES to) {
    D3D12_RESOURCE_BARRIER barrier = {0};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = from;
    barrier.Transition.StateAfter = to;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
}

int main(int argc, char **argv) {
    int offscreen = argc > 1 && !strcmp(argv[1], "offscreen");
    HWND window = offscreen ? NULL : probe_window(L"EscApp D3D12 probe");

    IDXGIFactory4 *factory = NULL;
    CHECK("factory", CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&factory));
    ID3D12Device *device = NULL;
    CHECK("create", D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));

    char adapter[128] = "?";
    LUID luid = ID3D12Device_GetAdapterLuid(device);
    IDXGIAdapter1 *dxgiAdapter = NULL;
    DXGI_ADAPTER_DESC1 adapterDesc;
    if (SUCCEEDED(IDXGIFactory4_EnumAdapterByLuid(factory, luid, &IID_IDXGIAdapter1, (void **)&dxgiAdapter))
        && SUCCEEDED(IDXGIAdapter1_GetDesc1(dxgiAdapter, &adapterDesc))) {
        WideCharToMultiByte(CP_UTF8, 0, adapterDesc.Description, -1, adapter, sizeof adapter, NULL, NULL);
    }

    /* The highest feature level the device reports, for the log line. */
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_12_2, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0,
                                  D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D12_FEATURE_DATA_FEATURE_LEVELS featureLevels = {sizeof levels / sizeof *levels, levels, 0};
    ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &featureLevels, sizeof featureLevels);

    D3D12_COMMAND_QUEUE_DESC queueDesc = {0};
    queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *queue = NULL;
    CHECK("queue", ID3D12Device_CreateCommandQueue(device, &queueDesc, &IID_ID3D12CommandQueue, (void **)&queue));

    IDXGISwapChain3 *swap = NULL;
    ID3D12Resource *buffers[BUFFERS];
    if (offscreen) {
        D3D12_HEAP_PROPERTIES defaultHeap = {0};
        defaultHeap.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC textureDesc = {0};
        textureDesc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        textureDesc.Width = WIDTH;
        textureDesc.Height = HEIGHT;
        textureDesc.DepthOrArraySize = 1;
        textureDesc.MipLevels = 1;
        textureDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        textureDesc.SampleDesc.Count = 1;
        textureDesc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        for (UINT i = 0; i < BUFFERS; i++) {
            CHECK("texture", ID3D12Device_CreateCommittedResource(device, &defaultHeap, D3D12_HEAP_FLAG_NONE,
                                                                   &textureDesc, D3D12_RESOURCE_STATE_COMMON, NULL,
                                                                   &IID_ID3D12Resource, (void **)&buffers[i]));
        }
    } else {
        DXGI_SWAP_CHAIN_DESC1 swapDesc = {0};
        swapDesc.Width = WIDTH;
        swapDesc.Height = HEIGHT;
        swapDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        swapDesc.SampleDesc.Count = 1;
        swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swapDesc.BufferCount = BUFFERS;
        swapDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        IDXGISwapChain1 *swap1 = NULL;
        CHECK("swapchain", IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &swapDesc, NULL,
                                                                NULL, &swap1));
        CHECK("swapchain3", IDXGISwapChain1_QueryInterface(swap1, &IID_IDXGISwapChain3, (void **)&swap));
        for (UINT i = 0; i < BUFFERS; i++)
            CHECK("buffer", IDXGISwapChain3_GetBuffer(swap, i, &IID_ID3D12Resource, (void **)&buffers[i]));
    }

    D3D12_DESCRIPTOR_HEAP_DESC heapDesc = {0};
    heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heapDesc.NumDescriptors = BUFFERS;
    ID3D12DescriptorHeap *heap = NULL;
    CHECK("heap", ID3D12Device_CreateDescriptorHeap(device, &heapDesc, &IID_ID3D12DescriptorHeap, (void **)&heap));
    UINT stride = ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE heapStart = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    for (UINT i = 0; i < BUFFERS; i++) {
        D3D12_CPU_DESCRIPTOR_HANDLE rtv = {heapStart.ptr + i * stride};
        ID3D12Device_CreateRenderTargetView(device, buffers[i], NULL, rtv);
    }

    /* A buffer the last frame is copied into, with rows aligned as Direct3D 12 requires. */
    UINT rowPitch = (WIDTH * 4 + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) & ~(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1);
    D3D12_HEAP_PROPERTIES readbackHeap = {0};
    readbackHeap.Type = D3D12_HEAP_TYPE_READBACK;
    D3D12_RESOURCE_DESC readbackDesc = {0};
    readbackDesc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    readbackDesc.Width = (UINT64)rowPitch * HEIGHT;
    readbackDesc.Height = 1;
    readbackDesc.DepthOrArraySize = 1;
    readbackDesc.MipLevels = 1;
    readbackDesc.SampleDesc.Count = 1;
    readbackDesc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *readback = NULL;
    CHECK("readback", ID3D12Device_CreateCommittedResource(device, &readbackHeap, D3D12_HEAP_FLAG_NONE, &readbackDesc,
                                                            D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource,
                                                            (void **)&readback));

    ID3D12CommandAllocator *allocator = NULL;
    CHECK("allocator", ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                           &IID_ID3D12CommandAllocator, (void **)&allocator));
    ID3D12GraphicsCommandList *list = NULL;
    CHECK("list", ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                                 &IID_ID3D12GraphicsCommandList, (void **)&list));
    ID3D12GraphicsCommandList_Close(list);
    CHECK("fence", ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence));
    fenceEvent = CreateEventW(NULL, FALSE, FALSE, NULL);

    float colour[4] = {0.66f, 0.29f, 0.03f, 1.0f};
    int frames = offscreen ? 10 : probe_frames(argc, argv), drawn = 0;
    for (; drawn < frames && probe_pump(); drawn++) {
        int last = drawn == frames - 1;
        UINT index = swap ? IDXGISwapChain3_GetCurrentBackBufferIndex(swap) : drawn % BUFFERS;
        CHECK("reset", ID3D12CommandAllocator_Reset(allocator));
        CHECK("reset", ID3D12GraphicsCommandList_Reset(list, allocator, NULL));
        transition(list, buffers[index], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
        D3D12_CPU_DESCRIPTOR_HANDLE rtv = {heapStart.ptr + index * stride};
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, colour, 0, NULL);
        if (last) {
            transition(list, buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
            D3D12_TEXTURE_COPY_LOCATION dst = {0}, src = {0};
            dst.pResource = readback;
            dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            dst.PlacedFootprint.Footprint.Width = WIDTH;
            dst.PlacedFootprint.Footprint.Height = HEIGHT;
            dst.PlacedFootprint.Footprint.Depth = 1;
            dst.PlacedFootprint.Footprint.RowPitch = rowPitch;
            src.pResource = buffers[index];
            src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
            transition(list, buffers[index], D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
        } else {
            transition(list, buffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        }
        CHECK("close", ID3D12GraphicsCommandList_Close(list));
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, (ID3D12CommandList **)&list);
        if (swap) CHECK("present", IDXGISwapChain3_Present(swap, 1, 0));
        if (!wait_for_gpu(queue)) { PROBE_REPORT("PROBE d3d12 FAIL fence"); return 2; }
    }
    if (drawn < frames) { PROBE_REPORT("PROBE d3d12 FAIL closed after %d frames", drawn); return 2; }

    unsigned char *pixels = NULL;
    D3D12_RANGE range = {0, (SIZE_T)rowPitch * HEIGHT};
    CHECK("map", ID3D12Resource_Map(readback, 0, &range, (void **)&pixels));
    unsigned char *centre = pixels + (HEIGHT / 2) * rowPitch + (WIDTH / 2) * 4;
    int r = centre[0], g = centre[1], b = centre[2];
    ID3D12Resource_Unmap(readback, 0, NULL);
    /* 0.66, 0.29, 0.03 → 168, 74, 8; a little slack for rounding. */
    if (abs(r - 168) > 2 || abs(g - 74) > 2 || abs(b - 8) > 2) {
        PROBE_REPORT("PROBE d3d12 FAIL pixel %d,%d,%d", r, g, b);
        return 2;
    }
    PROBE_REPORT("PROBE d3d12 OK bits=%d level=0x%x frames=%d%s adapter=%s", (int)sizeof(void *) * 8,
                 featureLevels.MaxSupportedFeatureLevel, drawn, offscreen ? " offscreen" : "", adapter);
    return 0;
}
