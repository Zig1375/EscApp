@testable import PlavioxKit
import Testing

@Suite struct DirectX12NeedTests {
    private func traits(_ directX: Set<ExecutableTraits.DirectX>) -> ExecutableTraits {
        ExecutableTraits(architecture: .x64, directX: directX)
    }

    private func requiring(_ backend: GraphicsBackend) -> GameModules.Launch {
        var launch = GameModules.Launch()
        launch.requireBackend = backend
        return launch
    }

    @Test func aDirect3D12ExeNeedsIt() {
        #expect(DirectX12Need.of(traits: traits([.d3d11, .d3d12]), module: .init()) == .directX12)
    }

    @Test func otherGamesDoNot() {
        #expect(DirectX12Need.of(traits: traits([.d3d11]), module: .init()) == nil)
        #expect(DirectX12Need.of(traits: traits([]), module: .init()) == nil)
        #expect(DirectX12Need.of(traits: nil, module: .init()) == nil)
    }

    /// A launcher exe with no Direct3D imports, whose module knows the game itself is DirectX 12.
    @Test func aModuleRequiringD3DMetalNeedsIt() {
        #expect(DirectX12Need.of(traits: traits([]), module: requiring(.d3dmetal)) == .gameSettings)
        #expect(DirectX12Need.of(traits: nil, module: requiring(.d3dmetal)) == .gameSettings)
    }

    /// Only `require` makes it a need: a `prefer` falls back to the next backend when D3DMetal isn't there.
    @Test func aModulePreferringD3DMetalDoesNot() {
        var launch = GameModules.Launch()
        launch.preferBackends = [.d3dmetal, .dxvk]
        #expect(DirectX12Need.of(traits: traits([.d3d11]), module: launch) == nil)
        #expect(DirectX12Need.of(traits: traits([.d3d11]), module: requiring(.dxvk)) == nil)
    }

    /// The exe is the surer sign, so it names the reason when both say so.
    @Test func theExeComesFirst() {
        #expect(DirectX12Need.of(traits: traits([.d3d12]), module: requiring(.d3dmetal)) == .directX12)
    }
}
