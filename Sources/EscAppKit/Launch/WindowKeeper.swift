import Foundation

/// Remembers where the player put a game's window and how large they made it, and puts it back there next time
/// (`tools/window-keeper`). Wine creates a game's windows where the game asks, and most games don't remember,
/// so a window the player had moved and resized came back at its old place every launch. The keeper runs inside
/// the game's bottle as a Windows program, so moving the window needs no permission on the Mac.
///
/// What it keeps lives in the bottle (`C:\windows\escapp-window.txt`); a reset of the game's Windows forgets it.
/// It ends with the game's process; full-screen games are left alone.
enum WindowKeeper {
    static let stateFile = #"C:\windows\escapp-window.txt"#

    static var program: URL? { Bundle.module.url(forResource: "window-keeper", withExtension: "exe") }

    /// Starts the keeper beside a game that was just started with `prepared`. Not for a store game: its window
    /// is the store's.
    static func start(for prepared: GameLauncher.Prepared) {
        guard prepared.gameFolder == nil, let program else { return }
        let keeper = Process()
        keeper.executableURL = prepared.wine.wine
        keeper.arguments = [program.path(percentEncoded: false), stateFile,
                            URL(filePath: prepared.game.executable).lastPathComponent]
        keeper.environment = prepared.environment
        keeper.standardInput = FileHandle.nullDevice
        keeper.standardOutput = FileHandle.nullDevice
        keeper.standardError = FileHandle.nullDevice
        try? keeper.run()
    }
}
