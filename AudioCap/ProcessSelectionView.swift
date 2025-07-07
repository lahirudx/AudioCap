import SwiftUI

@MainActor
struct ProcessSelectionView: View {
    @State private var processController = AudioProcessController()
    @State private var tap: ProcessTap?
    @State private var recorder: ProcessTapRecorder?
    @State private var systemRecorder: SystemAudioRecorder?

    @State private var selectedProcess: AudioProcess?
    @State private var recordingMode: RecordingMode = .process

    enum RecordingMode: String, CaseIterable {
        case process = "Individual Process"
        case system = "All System Audio"
    }

    var body: some View {
        Section {
            Picker("Recording Mode", selection: $recordingMode) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isAnyRecording)
            .onChange(of: recordingMode) { _, _ in
                teardownAll()
            }
        } header: {
            Text("Source")
                .font(.headline)
        }

        switch recordingMode {
        case .process:
            processSelectionSection
        case .system:
            systemRecordingSection
        }
    }
    
    private var isAnyRecording: Bool {
        recorder?.isRecording == true || systemRecorder?.isRecording == true
    }

    @ViewBuilder
    private var processSelectionSection: some View {
        Section {
            Picker("Process", selection: $selectedProcess) {
                Text("Select…")
                    .tag(Optional<AudioProcess>.none)

                ForEach(processController.processGroups) { group in
                    Section {
                        ForEach(group.processes) { process in
                            HStack {
                                Image(nsImage: process.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)

                                Text(process.name)
                            }
                                .tag(Optional<AudioProcess>.some(process))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .disabled(isAnyRecording)
            .task { processController.activate() }
            .onChange(of: selectedProcess) { oldValue, newValue in
                guard newValue != oldValue else { return }

                if let newValue {
                    setupRecording(for: newValue)
                } else if oldValue == tap?.process {
                    teardownTap()
                }
            }
        }

        if let tap {
            if let errorMessage = tap.errorMessage {
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.red)
            } else if let recorder {
                RecordingView(recorder: recorder)
                    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
                        /// Each recorder instance can only record a single file, so we create a new file/recorder when recording stops.
                        if wasRecording, !isRecording {
                            createRecorder()
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var systemRecordingSection: some View {
        if let systemRecorder {
            SystemRecordingView(recorder: systemRecorder)
                .onChange(of: systemRecorder.isRecording) { wasRecording, isRecording in
                    /// Each recorder instance can only record a single file, so we create a new file/recorder when recording stops.
                    if wasRecording, !isRecording {
                        createSystemRecorder()
                    }
                }
        } else {
            Section {
                Button("Setup System Recording") {
                    createSystemRecorder()
                }
            }
        }
    }

    private func setupRecording(for process: AudioProcess) {
        let newTap = ProcessTap(process: process)
        self.tap = newTap
        newTap.activate()

        createRecorder()
    }

    private func createRecorder() {
        guard let tap else { return }

        let filename = "\(tap.process.name)-\(Int(Date.now.timeIntervalSinceReferenceDate))"
        let audioFileURL = URL.applicationSupport.appendingPathComponent(filename, conformingTo: .wav)

        let newRecorder = ProcessTapRecorder(fileURL: audioFileURL, tap: tap)
        self.recorder = newRecorder
    }

    private func teardownTap() {
        tap = nil
    }

    private func createSystemRecorder() {
        let filename = "SystemAudio-\(Int(Date.now.timeIntervalSinceReferenceDate))"
        let audioFileURL = URL.applicationSupport.appendingPathComponent(filename, conformingTo: .wav)
        
        let newRecorder = SystemAudioRecorder(fileURL: audioFileURL)
        self.systemRecorder = newRecorder
    }

    private func teardownAll() {
        teardownTap()
        systemRecorder = nil
        selectedProcess = nil
    }
}

extension URL {
    static var applicationSupport: URL {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let subdir = appSupport.appending(path: "AudioCap", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: subdir.path) {
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            }
            return subdir
        } catch {
            assertionFailure("Failed to get application support directory: \(error)")

            return FileManager.default.temporaryDirectory
        }
    }
}

