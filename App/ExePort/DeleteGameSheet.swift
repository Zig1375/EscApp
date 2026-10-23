import ExePortKit
import SwiftUI

/// "Delete <game>?" from the design (Delete.dc.html): forget it in ExePort, or move its folder to the Trash.
/// Saves stay either way; deleting them too needs per-game save tracking, which comes later.
struct DeleteGameSheet: View {
    enum Choice { case appOnly, fromDisk }

    let game: GameRecord
    let folderSize: Int64?
    let library: LibraryModel
    let done: (_ removed: Bool) -> Void
    @State private var choice: Choice = .appOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \(game.name)?")
                .font(.system(size: 17, weight: .bold))
            Picker("How to delete", selection: $choice) {
                option(title: "Only from ExePort",
                       text: """
                           The game stays in \(folder). ExePort forgets it and deletes its Windows setup. \
                           Double-click the exe to bring it back.
                           """)
                    .tag(Choice.appOnly)
                option(title: "From disk",
                       text: """
                           The game folder\(sizeText) goes to the Trash. Until the Trash is emptied, \
                           the game can be restored.
                           """)
                    .tag(Choice.fromDisk)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Saves are kept either way.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.cancelAction)
                Button(choice == .appOnly ? "Remove from ExePort" : "Move to Trash") {
                    if choice == .appOnly { library.removeFromApp(game) } else { library.moveToTrash(game) }
                    done(true)
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var folder: String { (game.folder as NSString).abbreviatingWithTildeInPath }

    private var sizeText: String { folderSize.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? "" }

    private func option(title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
