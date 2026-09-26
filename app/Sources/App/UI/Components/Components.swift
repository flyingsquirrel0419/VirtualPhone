import SwiftUI

/// A small coloured capsule: "• Running", "JIT enabled".
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }
}

extension RuntimeState {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .paused: return .yellow
        case .failed: return .red
        case .idle, .stopped: return .gray
        }
    }
}

extension JITStatus {
    var color: Color {
        switch self {
        case .enabled: return .green
        case .requesting: return .orange
        case .unavailable: return .gray
        case .verificationFailed: return .red
        }
    }
}

/// Label / value row for settings and diagnostics.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}
