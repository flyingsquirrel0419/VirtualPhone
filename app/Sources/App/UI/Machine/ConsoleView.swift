import SwiftUI

/// The guest's serial console: what the kernel and the bootstrap print, and a
/// line to type into it.
struct ConsoleView: View {
    @ObservedObject var console: GuestConsole
    @State private var input = ""
    @State private var follow = true
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            phaseStrip
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(console.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .textSelection(.enabled)
                }
                .onChange(of: console.lines.count) { count in
                    if follow, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            if let sendError {
                Text(sendError).font(.caption2).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                TextField("Type into the guest console", text: $input)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(send)
                Toggle("Follow", isOn: $follow).toggleStyle(.button).font(.caption)
                ShareLink(item: console.exportText()) { Image(systemName: "square.and.arrow.up") }
            }
            .padding(8)
            .background(.ultraThinMaterial)
        }
        .background(Color.black)
    }

    private var phaseStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(console.transitions, id: \.phase) { t in
                    Text(t.elapsed > 0 ? String(format: "%@ %.0fs", t.phase.label, t.elapsed) : t.phase.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(t.phase.color.opacity(0.2), in: Capsule())
                }
                ForEach(console.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func color(for line: String) -> Color {
        if BootPhaseDetector.panicMarkers.contains(where: line.contains) { return .red }
        if BootPhaseDetector.warningMarkers.contains(where: line.contains) { return .orange }
        return .green
    }

    private func send() {
        let line = input
        input = ""
        console.send(line) { sendError = $0 }
    }
}

extension BootPhase {
    var color: Color {
        switch self {
        case .notStarted, .poweredOn: return .gray
        case .iboot: return .blue
        case .kernel: return .purple
        case .launchd: return .teal
        case .shell: return .green
        case .panicked: return .red
        }
    }
}
