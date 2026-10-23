import Foundation

/// Wine for macOS is an Intel program, so it needs Rosetta 2.
public enum Rosetta {
    /// Present once Rosetta is installed. Checking a file is instant, unlike running an Intel binary to see.
    static let runtimeFile = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    public static func isInstalled(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> Bool {
        fileExists(runtimeFile)
    }

    /// Installs Rosetta through Software Update, accepting Apple's license on the user's behalf.
    /// Call it only after the user agreed to that license in EscApp's own dialog.
    public static func installAcceptingLicense() async throws {
        try await ProcessRunner.check("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
    }
}
