/// How a game's Direct3D calls reach Metal.
public enum GraphicsBackend: String, CaseIterable, Codable, Sendable {
    /// DXVK-macOS 1.10.3: Direct3D 10/11 → Vulkan → MoltenVK. Stays on 1.10.x because 2.x needs Vulkan 1.3.
    /// Its Direct3D 9 and DXGI don't work on macOS (Gcenx removed them from the repack), so Wine's own stay.
    /// How a backend reaches a game: see `BackendTree`.
    case dxvk
    /// DXMT: Direct3D 10/11 straight to Metal. The only option for 32-bit D3D11 games.
    case dxmt
    /// Wine's own Direct3D over OpenGL. Slowest, but it handles DirectDraw and Direct3D 1–8.
    case wined3d
    /// Apple's D3DMetal: Direct3D 12 to Metal, the only way Plaviox runs Direct3D 12 games. Never shipped with
    /// Plaviox: it comes from the player's own download from Apple (`D3DMetal`), and needs a Wine that can load it
    /// (`BackendTree.supportsD3DMetal`).
    case d3dmetal

    public var displayName: String {
        switch self {
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        case .wined3d: "WineD3D"
        case .d3dmetal: "D3DMetal"
        }
    }
}
