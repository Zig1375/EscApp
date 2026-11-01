import Foundation
import PlavioxCLI

// The command runs while the main run loop does: ScreenCaptureKit (the first-launch look at a Chromium
// window) answers through it and never returns without one.
let command = PlavioxCommand(progress: { line in FileHandle.standardError.write(Data((line + "\n").utf8)) })
Task { @MainActor in
    let output = await command.run(Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(Data(output.stdout.utf8))
    FileHandle.standardError.write(Data(output.stderr.utf8))
    exit(output.status)
}
RunLoop.main.run()
