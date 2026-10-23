/* Opens a window and a Direct3D 11 device, then crashes after a second: a game that fails on every backend.
   ExePort should try each one and then give up. */
#include <d3d11.h>
#include "common.h"

int main(void) {
    probe_window(L"ExePort crash probe");
    ID3D11Device *device = NULL;
    D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, NULL, NULL);
    DWORD until = GetTickCount() + 1000;
    while (GetTickCount() < until && probe_pump()) Sleep(10);
    PROBE_REPORT("PROBE crash now");
    *(volatile int *)0 = 1;
    return 0;
}
