import Foundation
import RumCLI

let command = RumCommand(progress: { line in FileHandle.standardError.write(Data((line + "\n").utf8)) })
let output = await command.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.status)
