import SwiftUI

@MainActor
struct SystemRecordingView: View {
    let recorder: SystemAudioRecorder

    @State private var lastRecordingURL: URL?

    var body: some View {
        Section {
            if !recorder.isRecording {
                Toggle("Include Microphone", isOn: Binding(
                    get: { recorder.includeMicrophone },
                    set: { recorder.setIncludeMicrophone($0) }
                ))
                .disabled(recorder.isRecording)
            }
            
            HStack {
                if recorder.isRecording {
                    Button("Stop") {
                        recorder.stop()
                    }
                    .id("system-button")
                } else {
                    Button("Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .id("system-button")

                    if let lastRecordingURL {
                        FileProxyView(url: lastRecordingURL)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: lastRecordingURL)
            .onChange(of: recorder.isRecording) { _, newValue in
                if !newValue { lastRecordingURL = recorder.fileURL }
            }
            
            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                RecordingIndicator(appIcon: NSImage(systemSymbolName: recorder.includeMicrophone ? "mic.and.signal.meter" : "speaker.wave.3", accessibilityDescription: "System Audio")!, isRecording: recorder.isRecording)

                Text(recorder.isRecording ? 
                     (recorder.includeMicrophone ? "Recording System Audio + Microphone" : "Recording All System Audio") : 
                     (recorder.includeMicrophone ? "Ready to Record System Audio + Microphone" : "Ready to Record All System Audio"))
                    .font(.headline)
                    .contentTransition(.identity)
            }
        }
    }

    private func handlingErrors(perform block: () throws -> Void) {
        do {
            try block()
        } catch {
            /// "handling" in the function name might not be entirely true 😅
            NSAlert(error: error).runModal()
        }
    }
} 