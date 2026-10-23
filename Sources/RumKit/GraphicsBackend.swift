/// How a game's Direct3D calls reach Metal.
public enum GraphicsBackend: String, CaseIterable, Codable, Sendable {
    /// DXVK-macOS 1.10.3: Direct3D 9–11 → Vulkan → MoltenVK. Stays on 1.10.x because 2.x needs Vulkan 1.3.
    case dxvk
    /// DXMT: Direct3D 10/11 straight to Metal. The only option for 32-bit D3D11 games.
    case dxmt
    /// Wine's own Direct3D over OpenGL. Slowest, but it handles DirectDraw and Direct3D 1–8.
    case wined3d

    public var displayName: String {
        switch self {
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        case .wined3d: "WineD3D"
        }
    }

    /// The DLLs this backend replaces with its own copies in the bottle. Wine must load them as native first.
    public var nativeDLLs: [String] {
        switch self {
        case .dxvk: ["d3d9", "d3d10core", "d3d11", "dxgi"]
        case .dxmt: ["d3d10core", "d3d11", "dxgi", "winemetal"]
        case .wined3d: []
        }
    }
}
