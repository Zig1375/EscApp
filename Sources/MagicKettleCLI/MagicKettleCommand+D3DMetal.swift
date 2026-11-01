import Foundation
import MagicKettleKit

/// `kettle d3dmetal status|import|remove`: what the app's DirectX 12 setup does.
extension MagicKettleCommand {
    func d3dmetal(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        guard let action = options.positional() else { return failure("d3dmetal needs status, import or remove") }
        let image = action == "import" ? options.positional() : nil
        let accept = options.flag("--accept-apple-license")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }
        switch action {
        case "status":
            guard let installed = D3DMetal.installed(paths: paths) else {
                return success("D3DMetal: not added. Download Apple's \"Evaluation environment for Windows games\" "
                    + "and run: kettle d3dmetal import <dmg>")
            }
            return success("D3DMetal \(installed.info.version) from \(installed.info.source): "
                + installed.folder.path(percentEncoded: false))
        case "import":
            guard let image else { return failure("d3dmetal import needs the disk image from Apple") }
            return await d3dmetalImport(URL(filePath: image), accept: accept)
        case "remove":
            do { try D3DMetal.remove(paths: paths) } catch { return failure("\(error)") }
            return success("D3DMetal removed.")
        default:
            return failure("Unknown d3dmetal action: \(action). Use status, import or remove.")
        }
    }

    private func d3dmetalImport(_ image: URL, accept: Bool) async -> Output {
        progress("Checking \(image.lastPathComponent)…")
        let candidate: D3DMetalCandidate
        do { candidate = try await D3DMetal.prepare(image: image, paths: paths) } catch { return failure("\(error)") }
        guard accept else {
            D3DMetal.discard(candidate)
            return failure("""
                D3DMetal \(candidate.version) is in this image and signed by Apple. It is Apple's software under \
                Apple's license (License.rtf in the image). Run again with --accept-apple-license to add it.
                """)
        }
        do { try D3DMetal.install(candidate, paths: paths) } catch {
            D3DMetal.discard(candidate)
            return failure("\(error)")
        }
        return success("D3DMetal \(candidate.version) added.")
    }
}
