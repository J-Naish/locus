import SwiftUI

struct HomeView: View {
    @State private var runtimeStatus: RuntimeStatus = .checking

    private let coreBridge: CoreBridge

    init(coreBridge: CoreBridge = CoreBridge()) {
        self.coreBridge = coreBridge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeaderView()
            RuntimeStatusView(status: runtimeStatus)
            Spacer()
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 460)
        .task {
            await loadRuntimeStatus()
        }
    }

    @MainActor
    private func loadRuntimeStatus() async {
        do {
            runtimeStatus = .ready(try await coreBridge.runtimeSummary())
        } catch {
            runtimeStatus = .failed(error.localizedDescription)
        }
    }
}

private struct HeaderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Locus")
                .font(.title)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text("Local document workspace")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RuntimeStatusView: View {
    let status: RuntimeStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.symbolColor)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(status.message)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.message)
    }
}

private enum RuntimeStatus: Equatable, Sendable {
    case checking
    case ready(CoreRuntimeSummary)
    case failed(String)

    var symbolName: String {
        switch self {
        case .checking:
            return "circle.dotted"
        case .ready:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var symbolColor: Color {
        switch self {
        case .checking:
            return .secondary
        case .ready:
            return .green
        case .failed:
            return .orange
        }
    }

    var message: String {
        switch self {
        case .checking:
            return "Checking Rust core"
        case let .ready(summary):
            return "Rust core \(summary.coreVersion), ABI \(summary.abiVersion)"
        case let .failed(message):
            return message
        }
    }
}
