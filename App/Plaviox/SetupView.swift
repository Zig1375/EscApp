import SwiftUI

/// First launch: everything Plaviox needs, checked and installed in one screen.
struct SetupView: View {
    let setup: RuntimeSetup

    var body: some View {
        ZStack {
            WarmBackground()
            content
        }
        .focusEffectDisabled()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                BrandHero(symbol: "arrow.down", size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Getting ready to play")
                        .font(.title.bold())
                    Text("Plaviox downloads what Windows games need. This happens once and takes a few minutes.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                ForEach(setup.items) { item in
                    SetupRow(item: item)
                    if item.id != setup.items.last?.id { Divider() }
                }
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6))
            }

            footer
        }
        .padding(32)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        switch setup.phase {
        case .needsRosettaConsent:
            VStack(alignment: .leading, spacing: 12) {
                Text("Windows games are built for Intel processors. Rosetta 2 from Apple lets this Mac run them.")
                Text("Installing Rosetta means you agree to [Apple's license](https://www.apple.com/legal/sla/).")
                    .foregroundStyle(.secondary)
                Button("Agree and Install") { setup.acceptRosettaLicense() }
                    .buttonStyle(.borderedProminent)
                    .tint(.brand)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Try Again") { setup.retry() }
            }
        case .checking, .working, .ready:
            EmptyView()
        }
    }
}

private struct SetupRow: View {
    let item: RuntimeSetup.Item

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium)
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                if case let .active(fraction?) = item.state {
                    ProgressView(value: fraction).tint(.brand).padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .active:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
