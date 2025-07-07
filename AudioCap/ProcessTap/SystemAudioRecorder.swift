import SwiftUI
import AVFoundation
import AudioToolbox
import OSLog

@Observable
final class SystemAudioRecorder {
    
    let fileURL: URL
    private let logger: Logger
    
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    
    @ObservationIgnored
    private var systemTap: SystemAudioTap?
    @ObservationIgnored
    private var audioFile: AVAudioFile?
    
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.logger = Logger(subsystem: kAppSubsystem, category: "\(String(describing: SystemAudioRecorder.self))(\(fileURL.lastPathComponent))")
    }
    
    @MainActor
    func start() throws {
        logger.debug(#function)
        
        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }
        
        errorMessage = nil
        
        // Stop any existing recording
        stop()
        
        let tap = SystemAudioTap()
        systemTap = tap
        
        try tap.activate()
        
        guard let streamDescription = tap.streamDescription else {
            throw "Tap stream description not available."
        }
        
        var format = streamDescription
        guard let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw "Failed to create AVAudioFormat."
        }
        
        logger.info("Using audio format: \(avFormat, privacy: .public)")
        
        let settings: [String: Any] = [
            AVFormatIDKey: format.mFormatID,
            AVSampleRateKey: avFormat.sampleRate,
            AVNumberOfChannelsKey: avFormat.channelCount
        ]
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: avFormat.isInterleaved)
        self.audioFile = audioFile
        
        try tap.startRecording { [weak self] buffer, time in
            guard let self = self, let audioFile = self.audioFile else { return }
            do {
                try audioFile.write(from: buffer)
            } catch {
                DispatchQueue.main.async {
                    self.logger.error("Failed to write audio buffer: \(error, privacy: .public)")
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        
        isRecording = true
        logger.info("Started system audio recording")
    }
    
    @MainActor
    func stop() {
        logger.debug(#function)
        
        guard isRecording else { return }
        
        _stop()
    }
    
    private func _stop() {
        systemTap?.invalidate()
        systemTap = nil
        
        // Close the audio file
        audioFile = nil
        
        isRecording = false
        logger.info("Stopped system audio recording")
    }
    
    deinit {
        _stop()
    }
}

// MARK: - SystemAudioTap

private final class SystemAudioTap {
    
    private let logger = Logger(subsystem: kAppSubsystem, category: String(describing: SystemAudioTap.self))
    
    @ObservationIgnored
    private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored
    private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    
    private(set) var streamDescription: AudioStreamBasicDescription?
    private var recordingCallback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    
    func activate() throws {
        logger.debug(#function)
        
        // Create a process tap for all processes (system audio)
        let allProcesses = try AudioObjectID.readProcessList()
        
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: allProcesses)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        
        guard err == noErr else {
            throw "System process tap creation failed with error \(err)"
        }
        
        logger.debug("Created system process tap #\(tapID, privacy: .public)")
        
        self.processTapID = tapID
        
        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()
        
        let aggregateUID = UUID().uuidString
        
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SystemAudioTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]
        
        self.streamDescription = try tapID.readAudioTapStreamBasicDescription()
        
        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }
        
        logger.debug("Created aggregate device #\(self.aggregateDeviceID, privacy: .public)")
    }
    
    func startRecording(callback: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard let streamDescription = streamDescription else {
            throw "Stream description not available"
        }
        
        self.recordingCallback = callback
        
        var format = streamDescription
        guard let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw "Failed to create AVAudioFormat"
        }
        
        let queue = DispatchQueue(label: "SystemAudioTap", qos: .userInitiated)
        
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self = self, let callback = self.recordingCallback else { return }
            
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: inInputData, deallocator: nil) else {
                    throw "Failed to create PCM buffer"
                }
                
                let time = AVAudioTime(hostTime: inNow.pointee.mHostTime)
                callback(buffer, time)
            } catch {
                self.logger.error("Recording callback error: \(error, privacy: .public)")
            }
        }
        
        guard err == noErr else { throw "Failed to create device I/O proc: \(err)" }
        
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start audio device: \(err)" }
    }
    
    func invalidate() {
        logger.debug(#function)
        
        recordingCallback = nil
        
        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop aggregate device: \(err, privacy: .public)") }
            
            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }
            
            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            aggregateDeviceID = .unknown
        }
        
        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning("Failed to destroy system process tap: \(err, privacy: .public)")
            }
            self.processTapID = .unknown
        }
    }
    
    deinit {
        invalidate()
    }
} 