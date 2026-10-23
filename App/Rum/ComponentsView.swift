import RumKit
import SwiftUI

/// Settings → Components: what's installed, what's new, and the update switch.
struct ComponentsView: View {
    @Bindable var model: ComponentsModel

    var body: some View {
        Form {
            Section { statusCard }

            if let current {
                Section("Installed") {
                    RosettaRow(installed: model.rosettaInstalled)
                    ForEach(current.components, id: \.kind) { component in
                        ComponentRow(component: component)
                    }
                    if let size = model.sizes[current.id] {
                        LabeledContent("Space used", value: size.formatted(.byteCount(style: .file)))
                    }
                }
            }

            if !older.isEmpty {
                Section {
                    ForEach(older, id: \.id) { runtime in
                        LabeledContent(runtime.components.first { $0.kind == .wine }.map { "Wine \($0.version)" }
                                       ?? runtime.id,
                                       value: model.sizes[runtime.id]?.formatted(.byteCount(style: .file)) ?? "…")
                    }
                } header: {
                    Text("Previous versions")
                } footer: {
                    Text("Kept until no game uses them any more.")
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $model.autoCheck)
                LabeledContent {
                    Button("Check Now") { Task { await model.checkNow() } }
                        .disabled(model.isChecking)
                } label: {
                    Text(lastCheckedText)
                    if let error = model.checkError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { model.reload() }
    }

    private var current: RuntimeManifest.Runtime? {
        switch model.catalog?.status {
        case let .upToDate(runtime)?, let .updateAvailable(runtime, _)?: runtime
        default: nil
        }
    }

    private var older: [RuntimeManifest.Runtime] {
        (model.catalog?.installed ?? []).filter { $0.id != current?.id }
    }

    private var lastCheckedText: String {
        if model.isChecking { return String(localized: "Checking…") }
        guard let date = model.lastChecked else { return String(localized: "Not checked yet") }
        return String(localized: "Last checked \(date.formatted(.relative(presentation: .named)))")
    }

    @ViewBuilder private var statusCard: some View {
        switch model.catalog?.status {
        case let .updateAvailable(current, newest)?:
            VStack(alignment: .leading, spacing: 12) {
                StatusHeader(symbol: "arrow.down.circle.fill", color: .rum, title: "An update is available",
                             subtitle: "Games keep their settings and saves.")
                ForEach(RuntimeCatalog.changes(from: current, to: newest), id: \.kind) { change in
                    ChangeRow(change: change)
                }
                if let progress = model.updating {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.label).font(.callout).foregroundStyle(.secondary)
                        ProgressView(value: progress.fraction).tint(.rum)
                    }
                } else {
                    Button("Update") { Task { await model.installUpdate() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.rum)
                }
                if let error = model.updateError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        case .upToDate?:
            StatusHeader(symbol: "checkmark.circle.fill", color: .green, title: "Everything is up to date",
                         subtitle: "Rum checks once a day and tells you when there's something new.")
        case .notInstalled?:
            StatusHeader(symbol: "exclamationmark.circle.fill", color: .orange, title: "Components aren't installed",
                         subtitle: "Rum installs them the first time it opens.")
        case .unavailable?, nil:
            StatusHeader(symbol: "xmark.circle.fill", color: .red, title: "No components for this Mac",
                         subtitle: "A newer version of Rum is needed.")
        }
    }
}

private struct StatusHeader: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: RuntimeCatalog.Change

    var body: some View {
        HStack(spacing: 6) {
            Text(change.kind.title).fontWeight(.medium)
            Spacer()
            if let old = change.oldVersion { Text(old).foregroundStyle(.secondary) }
            if change.oldVersion != nil, change.newVersion != nil {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            }
            if let new = change.newVersion { Text(new).fontWeight(.medium) } else { Text("removed") }
        }
        .font(.callout)
        .monospacedDigit()
    }
}

private struct ComponentRow: View {
    let component: RuntimeManifest.Component

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(component.version).monospacedDigit()
                Text(component.license).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Text(component.kind.title)
            Text(component.kind.role)
        }
    }
}

private struct RosettaRow: View {
    let installed: Bool

    var body: some View {
        LabeledContent {
            Text(installed ? "Installed" : "Not installed")
                .foregroundStyle(installed ? Color.secondary : Color.orange)
        } label: {
            Text("Rosetta 2")
            Text("Apple's translator for Intel apps")
        }
    }
}

struct SettingsView: View {
    let components: ComponentsModel

    var body: some View {
        TabView {
            Tab("Components", systemImage: "shippingbox") {
                ComponentsView(model: components)
            }
        }
        .frame(width: 560, height: 560)
    }
}
