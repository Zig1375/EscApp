@testable import EscAppKit
import Testing

@Suite struct BackendPlanTests {
    func plan(_ arch: ExecutableTraits.Architecture, _ dx: Set<ExecutableTraits.DirectX>,
              launcher: Bool = false) -> BackendPlan {
        BackendPlan.forTraits(ExecutableTraits(architecture: arch, directX: dx, isChromiumLauncher: launcher))
    }

    @Test func directDrawAndD3D8UseWineD3D() {
        #expect(plan(.x86, [.legacy]) == .attempts([.wined3d]))
    }

    @Test func d3d9UsesWineD3D() {
        // DXVK-macOS ships without a usable d3d9.
        #expect(plan(.x86, [.d3d9]) == .attempts([.wined3d]))
    }

    @Test func d3d11DependsOnBitness() {
        #expect(plan(.x64, [.d3d11]) == .attempts([.dxvk, .dxmt, .wined3d]))
        // DXVK-macOS creates no 32-bit D3D11 device on some Wine builds, so DXMT goes first.
        #expect(plan(.x86, [.d3d11]) == .attempts([.dxvk, .dxmt, .wined3d]))
    }

    @Test func newestImportedDirectXDecides() {
        #expect(plan(.x64, [.d3d9, .d3d11]) == .attempts([.dxvk, .dxmt, .wined3d]))
    }

    @Test func unsupportedCasesSayWhy() {
        #expect(plan(.x64, [.d3d11, .d3d12]) == .unsupported(.directX12))
        #expect(plan(.win16, []) == .unsupported(.sixteenBit))
    }

    @Test func launchersUseDXVK() {
        #expect(plan(.x64, [.d3d11], launcher: true) == .attempts([.dxvk, .wined3d]))
    }

    /// Unity's exe imports only UnityPlayer.dll, which loads Direct3D 11 itself.
    @Test func unityGamesAreDirectX11() {
        let info = ExecutableInfo(format: .pe64, imports: ["kernel32.dll", "unityplayer.dll"], productName: nil,
                                  icon: nil, dpiAware: false)
        #expect(info.directX == [.d3d11])
        #expect(BackendPlan.forTraits(info.traits) == .attempts([.dxvk, .dxmt, .wined3d]))
    }

    /// NW.js imports no Direct3D (ANGLE loads it), and DXVK draws RPG Maker MV's menus empty.
    @Test func chromiumGamesStartWithWineD3D() {
        var info = ExecutableInfo(format: .pe32, imports: ["kernel32.dll", "nw_elf.dll"], productName: nil,
                                  icon: nil, dpiAware: false)
        info.chromium = true
        #expect(BackendPlan.forTraits(info.traits) == .attempts([.wined3d, .dxmt, .dxvk]))
        #expect(plan(.x64, [.d3d11], launcher: true) == .attempts([.dxvk, .wined3d]))
    }

    @Test func noStaticImportsFallsBackToDXVK() {
        #expect(plan(.x64, []) == .attempts([.dxvk, .wined3d]))
    }
}
