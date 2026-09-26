import SwiftUI

/// Progress and result of a guest operation (network, file, IPA install).
struct GuestServicesView: View {
    @ObservedObject var services: GuestServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(services.progress.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                    if services.outcome == .running {
                        HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                    }
                }
                if let outcome = services.outcome {
                    Section("Result") {
                        switch outcome {
                        case .running:
                            Text("In progress").foregroundStyle(.secondary)
                        case .succeeded(let message):
                            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(services.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
