/// What EscApp knows about a game's executable before the first launch. Filled in by the exe analysis (M3); the
/// rules below only depend on these facts, so they are tested without real games.
public struct ExecutableTraits: Sendable, Equatable {
    public enum Architecture: String, Sendable, Equatable {
        case x86
        case x64
        /// A 16-bit (NE) executable. Wine on macOS can't run these.
        case win16
    }

    public enum DirectX: Int, Comparable, Sendable, Equatable {
        /// `ddraw.dll`, `d3d8.dll` and older.
        case legacy = 8
        case d3d9 = 9
        case d3d11 = 11
        case d3d12 = 12

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var architecture: Architecture
    /// Every Direct3D generation the exe imports. Empty means it imports none (a launcher, or a game that
    /// loads Direct3D at run time).
    public var directX: Set<DirectX>
    /// Chromium-based launchers (Steam, Epic) are known to run well on DXVK.
    public var isChromiumLauncher: Bool
    /// A game built on Chromium (NW.js, Electron, CEF): `ChromiumApp`.
    public var isChromium: Bool

    public init(architecture: Architecture, directX: Set<DirectX> = [], isChromiumLauncher: Bool = false,
                isChromium: Bool = false) {
        self.architecture = architecture
        self.directX = directX
        self.isChromiumLauncher = isChromiumLauncher
        self.isChromium = isChromium
    }
}

/// The order in which the first launch tries backends, when neither an earlier run nor the game database
/// says which one works.
public enum BackendPlan: Sendable, Equatable {
    case attempts([GraphicsBackend])
    case unsupported(Reason)

    public enum Reason: Sendable, Equatable {
        case sixteenBit
        /// Direct3D 12 needs D3DMetal, which the player hasn't added yet (or the runtime's Wine can't load it).
        case directX12
    }

    /// For a program on Chromium (`ExecutableTraits.isChromium`).
    static let chromiumAttempts: [GraphicsBackend] = [.wined3d, .dxmt, .dxvk]

    /// - Parameter d3dmetal: whether D3DMetal is installed and the runtime can load it; only Direct3D 12 games
    ///   use it.
    public static func forTraits(_ traits: ExecutableTraits, d3dmetal: Bool = false) -> BackendPlan {
        if traits.architecture == .win16 { return .unsupported(.sixteenBit) }
        if traits.isChromiumLauncher { return .attempts([.dxvk, .wined3d]) }
        // Chromium draws through ANGLE on Direct3D 11, which DXVK gets wrong two ways: RPG Maker MV (NW.js 0.29)
        // clears a scissored rectangle under each window and DXVK wipes the windows drawn before, so the crafting
        // menu of "My wife and I ~Shipwrecked on a Desert Island~" showed one empty frame; NW.js 0.92 (Chromium
        // 131, "The Taming Massage Parlor") crashed at start. Both draw right on WineD3D, MV also on DXMT.
        if traits.isChromium { return .attempts(chromiumAttempts) }
        // The newest Direct3D an exe imports decides: a game that imports both d3d9 and d3d11 renders with 11
        // and keeps 9 for a fallback path or its settings tool.
        switch traits.directX.max() {
        case .d3d12:
            return d3dmetal ? .attempts([.d3dmetal]) : .unsupported(.directX12)
        case .d3d11:
            // DXVK first for 32-bit games too. They once started with DXMT because DXVK-macOS created no 32-bit
            // D3D11 device on Gcenx 11.18; EscApp's Wine 11.20 creates it, and DXMT left a 32-bit GameMaker game
            // (Daughter for Dessert) a white window that DXVK draws.
            return .attempts([.dxvk, .dxmt, .wined3d])
        case .d3d9, .legacy:
            // DXVK-macOS has no working Direct3D 9, and DXMT is 10/11 only.
            return .attempts([.wined3d])
        case nil:
            // Nothing imported statically: the exe probably loads Direct3D itself. Modern games that do
            // this are mostly 10/11; WineD3D catches the rest. Unreal Engine games load Direct3D 12 this way too,
            // so with D3DMetal added it is tried when DXVK fails.
            return .attempts(d3dmetal ? [.dxvk, .d3dmetal, .wined3d] : [.dxvk, .wined3d])
        }
    }
}

extension BackendPlan {
    /// Which backends a launch tries, in order: the one that worked last time, then the game module's preference
    /// (`GameModules`), then the one the game's `.escapp` recommends (it worked on the Mac the folder came from),
    /// then the game database's choice, then the rules. A backend that crashed for this game is still tried again,
    /// just later.
    public static func order(_ plan: [GraphicsBackend], remembered: GraphicsBackend?,
                             preferred: [GraphicsBackend] = [], recommended: GraphicsBackend? = nil,
                             known: GraphicsBackend?) -> [GraphicsBackend] {
        var order: [GraphicsBackend] = []
        let first = [remembered].compactMap(\.self) + preferred + [recommended, known].compactMap(\.self)
        for backend in first + plan where !order.contains(backend) {
            order.append(backend)
        }
        return order
    }
}
