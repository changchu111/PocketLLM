import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: GenerationSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Generation") {
                    HStack {
                        Text("Max tokens")
                        Spacer()
                        Text("\(settings.maxNewTokens)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Stepper(value: Binding(get: {
                        Int(settings.maxNewTokens)
                    }, set: { newValue in
                        settings.maxNewTokens = Int32(newValue)
                    }), in: 16...4096, step: 16) {
                        Text("Adjust")
                    }

                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.2f", settings.temperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: {
                        Double(settings.temperature)
                    }, set: { newValue in
                        settings.temperature = Float(newValue)
                    }), in: 0.0...1.5)

                    HStack {
                        Text("Top-k")
                        Spacer()
                        Text("\(settings.topK)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Stepper(value: Binding(get: {
                        Int(settings.topK)
                    }, set: { newValue in
                        settings.topK = Int32(newValue)
                    }), in: 0...200, step: 1) {
                        Text("Adjust")
                    }

                    HStack {
                        Text("Top-p")
                        Spacer()
                        Text(String(format: "%.2f", settings.topP))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: {
                        Double(settings.topP)
                    }, set: { newValue in
                        settings.topP = Float(newValue)
                    }), in: 0.0...1.0)

                    HStack {
                        Text("Presence penalty")
                        Spacer()
                        Text(String(format: "%.2f", settings.presencePenalty))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: {
                        Double(settings.presencePenalty)
                    }, set: { newValue in
                        settings.presencePenalty = Float(newValue)
                    }), in: 0.0...2.0)

                    HStack {
                        Text("Frequency penalty")
                        Spacer()
                        Text(String(format: "%.2f", settings.frequencyPenalty))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: {
                        Double(settings.frequencyPenalty)
                    }, set: { newValue in
                        settings.frequencyPenalty = Float(newValue)
                    }), in: 0.0...2.0)

                    HStack {
                        Text("Seed")
                        Spacer()
                        Text("\(settings.seed)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Randomize Seed") {
                        settings.seed = UInt32.random(in: 1...UInt32.max)
                    }
                }

                Section("Context") {
                    HStack {
                        Text("Context length")
                        Spacer()
                        Text("\(settings.contextLength)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Stepper(value: Binding(get: {
                        Int(settings.contextLength)
                    }, set: { newValue in
                        settings.contextLength = Int32(newValue)
                    }), in: 512...16384, step: 512) {
                        Text("Adjust")
                    }
                    Text("Higher context uses much more memory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
