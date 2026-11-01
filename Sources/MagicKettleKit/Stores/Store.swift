import Foundation

/// A game store whose Windows client Magic Kettle can install (Stores.dc.html). Each lives in its own bottle, so a
/// store's client and its updates never touch other games. Its games run in that bottle too, started through the
/// client, which handles the account and DRM.
///
/// A store is its name in `Games.json`; what Magic Kettle knows about it is its `StoreModule`.
public struct Store: Hashable, Sendable, Identifiable, RawRepresentable, Codable {
    let module: any StoreModule

    /// Every store, in the order the app lists them.
    public static let allCases: [Store] = [.steam, .epic]

    init(_ module: any StoreModule) { self.module = module }

    public init?(rawValue: String) {
        guard let store = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = store
    }

    public var rawValue: String { module.id }
    public var id: Self { self }
    public var name: String { module.name }

    public static func == (lhs: Store, rhs: Store) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let store = Store(rawValue: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "No store named \(name)"))
        }
        self = store
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The store's bottle is named like a game's, so making it, moving it to a new runtime and resetting it
    /// work the same way. These ids are fixed and never made by `GameID.make()` (version 4 UUIDs are random).
    public var bottleID: GameID {
        // E5CA5704-0000-4000-8000-00000000000<n>
        GameID(uuid: UUID(uuid: (0xE5, 0xCA, 0x57, 0x04, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, module.bottleNumber)))
    }

    /// The store whose bottle this is, for a bottle's id.
    public static func owning(bottle id: GameID) -> Store? {
        allCases.first { $0.bottleID == id }
    }

    public var installerURL: URL { module.installer.url }

    /// The client in `bottle`, once installed.
    public func client(in bottle: URL) -> URL? {
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
        return module.clientPaths.map { drive.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The store whose client `program` is, when someone installed the store with its own installer and opened
    /// its client like a game: it then gets what Magic Kettle does for the store's client anywhere (`StoreClient`).
    public static func clientProgram(_ program: URL, in bottle: URL) -> Store? {
        let wanted = program.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
        return allCases.first { store in
            store.client(in: bottle).map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased() == wanted
            } ?? false
        }
    }

    var chromiumHelpers: [String] { module.chromiumHelpers }

    /// Whether the client is drawn at the screen's full resolution on a Retina display (`StoreClient.drawSharp`).
    var drawsAtScreenResolution: Bool { module.drawsAtScreenResolution }

    func clientArguments(clientReady: Bool) -> [String] { module.clientArguments(clientReady: clientReady) }

    /// `clientArguments` for the client in `bottle` as it is now.
    func clientArguments(in bottle: URL) -> [String] {
        module.clientArguments(clientReady: module.isReady(bottle: bottle))
    }

    public var launchesGames: Bool { module.launchesGames }

    func playArguments(storeID: String) -> [String] { module.playArguments(storeID: storeID) }

    func uninstallArguments(storeID: String) -> [String] { module.uninstallArguments(storeID: storeID) }

    var environment: [String: String] { module.environment }

    var clientFolders: [String] { module.clientFolders }
    var gameFolders: [String] { module.gameFolders }

    /// Whether `program` (a Windows path) is the client's, or Windows' own, rather than a game.
    /// Wine's own Mac programs in the bottle (`wineserver`) have a Mac path and aren't games either.
    func isClientProgram(_ program: String) -> Bool {
        guard program.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil else { return true }
        if WineProcesses.runs(program, from: #"C:\windows"#) { return true }
        if program.lowercased().hasSuffix(#"\store-windows.exe"#) { return true }
        if gameFolders.contains(where: { WineProcesses.runs(program, from: $0) }) { return false }
        return clientFolders.contains { WineProcesses.runs(program, from: $0) }
    }
}
