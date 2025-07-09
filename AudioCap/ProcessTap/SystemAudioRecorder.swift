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
    private(set) var includeMicrophone = true
    
    @ObservationIgnored
    private var systemTap: SystemAudioTap?
    @ObservationIgnored
    private var audioFile: AVAudioFile?
    @ObservationIgnored
    private var audioEngine = AVAudioEngine()
    @ObservationIgnored
    private var microphoneInput: AVAssetWriterInput?
    @ObservationIgnored
    private var systemAudioInput: AVAssetWriterInput?
    @ObservationIgnored
    private var assetWriter: AVAssetWriter?
    
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.logger = Logger(subsystem: kAppSubsystem, category: "\(String(describing: SystemAudioRecorder.self))(\(fileURL.lastPathComponent))")
    }
    
    func setIncludeMicrophone(_ include: Bool) {
        guard !isRecording else { return }
        includeMicrophone = include
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
        
        if includeMicrophone {
            try startWithMicrophoneMixing()
        } else {
            try startSystemAudioOnly()
        }
        
        isRecording = true
        logger.info("Started system audio recording (microphone: \(self.includeMicrophone))")
    }
    
    private func startWithMicrophoneMixing() throws {
        logger.info("Starting system audio recording with microphone mixing")
        
        // Create system audio tap
        let tap = SystemAudioTap()
        systemTap = tap
        try tap.activate()
        
        guard let systemStreamDescription = tap.streamDescription else {
            throw "System tap stream description not available."
        }
        
        // Convert system audio format to AVAudioFormat
        var systemFormat = systemStreamDescription
        guard let systemAVFormat = AVAudioFormat(streamDescription: &systemFormat) else {
            throw "Failed to create AVAudioFormat for system audio."
        }
        
        logger.info("System audio format: \(systemAVFormat, privacy: .public)")
        
        // Create audio settings for multi-track recording
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Create asset writer for multi-track audio file
        assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
        
        // Create system audio input
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput?.expectsMediaDataInRealTime = true
        
        // Create microphone audio input  
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        microphoneInput?.expectsMediaDataInRealTime = true
        
        // Add inputs to asset writer
        if let writer = assetWriter {
            if let sysInput = systemAudioInput, writer.canAdd(sysInput) {
                writer.add(sysInput)
            }
            if let micInput = microphoneInput, writer.canAdd(micInput) {
                writer.add(micInput)
            }
        }
        
        // Clear the old audio file reference
        self.audioFile = nil
        
        // Setup microphone recording
        do {
            try setupMicrophoneRecording()
        } catch {
            logger.error("Failed to setup microphone: \(error, privacy: .public)")
            // Continue with system audio only
            errorMessage = "Microphone setup failed: \(error.localizedDescription). Recording system audio only."
        }
        
        // Start asset writer
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: CMTime.zero)
        
        // Start audio engine for microphone
        do {
            try audioEngine.start()
            logger.info("Audio engine started successfully")
        } catch {
            logger.error("Failed to start audio engine: \(error, privacy: .public)")
            throw error
        }
        
        // Start system audio recording
        try tap.startRecording { [weak self] systemBuffer, time in
            guard let self = self else { return }
            
            // Convert system audio buffer to CMSampleBuffer and write to system track
            if let sampleBuffer = self.createSampleBuffer(from: systemBuffer, time: time, format: systemAVFormat) {
                if self.systemAudioInput?.isReadyForMoreMediaData == true {
                    self.systemAudioInput?.append(sampleBuffer)
                }
            }
        }
        
        logger.info("Started multi-track audio recording (system + microphone)")
    }
    
    private func setupMicrophoneRecording() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        logger.info("Microphone format: \(inputFormat, privacy: .public)")
        
        // Create mixer node
        let mixerNode = AVAudioMixerNode()
        audioEngine.attach(mixerNode)
        
        // Connect input to a mixer node to enable the audio tap.
        // DO NOT connect the mixer to the mainMixerNode, as that will cause playback.
        audioEngine.connect(inputNode, to: mixerNode, format: inputFormat)
        
        // Explicitly set the mixer's volume to 0 to prevent feedback.
        mixerNode.outputVolume = 0
        
        // Install tap on input node for recording (after connections are made)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            self.logger.info("Received microphone buffer - frames: \(buffer.frameLength)")
            
            // Convert microphone buffer to CMSampleBuffer and write to microphone track
            if let sampleBuffer = self.createSampleBuffer(from: buffer, time: time) {
                if self.microphoneInput?.isReadyForMoreMediaData == true {
                    self.microphoneInput?.append(sampleBuffer)
                    self.logger.info("Successfully wrote microphone buffer to track")
                } else {
                    self.logger.warning("Microphone input not ready for data")
                }
            } else {
                self.logger.error("Failed to create sample buffer from microphone data")
            }
        }
        
        // Prepare audio engine
        audioEngine.prepare()
        logger.info("Microphone recording setup completed with proper signal path")
    }
    
    private func createSampleBuffer(from audioBuffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        guard audioBuffer.floatChannelData != nil else { return nil }
        
        let frameCount = AVAudioFrameCount(audioBuffer.frameLength)
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        
        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        let dataSize = Int(frameCount) * Int(bytesPerFrame)
        
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == kCMBlockBufferNoErr,
              let blockBuffer = blockBuffer else { return nil }
        
        // Copy audio data
        guard let channelData = audioBuffer.floatChannelData else { return nil }
        
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: channelData[0],
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        
        // Create format description
        let asbd = audioBuffer.format.streamDescription
        var formatDescription: CMAudioFormatDescription?
        
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard formatStatus == noErr,
              let formatDescription = formatDescription else { return nil }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleCount = CMItemCount(audioBuffer.frameLength)
        let presentationTimeStamp = CMTime(
            value: CMTimeValue(time.sampleTime),
            timescale: CMTimeScale(audioBuffer.format.sampleRate)
        )
        
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(
                duration: CMTime.invalid,
                presentationTimeStamp: presentationTimeStamp,
                decodeTimeStamp: CMTime.invalid
            )],
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr else { return nil }
        
        return sampleBuffer
    }
    
    private func createSampleBuffer(from systemBuffer: AVAudioPCMBuffer, time: AVAudioTime, format: AVAudioFormat) -> CMSampleBuffer? {
        // Convert system audio buffer similar to microphone
        return createSampleBuffer(from: systemBuffer, time: time)
    }
    
    private func startSystemAudioOnly() throws {
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
    }
    

    
    @MainActor
    func stop() {
        logger.debug(#function)
        
        guard isRecording else { return }
        
        _stop()
    }
    
    private func _stop() {
        // Stop and clean up audio engine
        if audioEngine.isRunning {
            // Remove microphone tap
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        
        // Stop system audio tap
        systemTap?.invalidate()
        systemTap = nil
        
        // Finalize asset writer
        if let writer = assetWriter {
            systemAudioInput?.markAsFinished()
            microphoneInput?.markAsFinished()
            
            writer.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    self?.logger.info("Asset writer finished")
                }
            }
        }
        
        // Clean up
        systemAudioInput = nil
        microphoneInput = nil
        assetWriter = nil
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

// TODO: Implement microphone mixing in a future update 
