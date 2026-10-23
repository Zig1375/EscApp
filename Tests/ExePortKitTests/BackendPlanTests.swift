import ExePortKit
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
        #expect(plan(.x86, [.d3d11]) == .attempts([.dxmt, .dxvk, .wined3d]))
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

    @Test func noStaticImportsFallsBackToDXVK() {
        #expect(plan(.x64, []) == .attempts([.dxvk, .wined3d]))
    }
}
