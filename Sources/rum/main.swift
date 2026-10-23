import Foundation
import RumCLI

let output = RumCommand().run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.status)
