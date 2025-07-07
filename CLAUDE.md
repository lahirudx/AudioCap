# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AudioCap is a macOS SwiftUI application that demonstrates Apple's CoreAudio Process Tap API introduced in macOS 14.4. It allows capturing audio from other applications or the entire system with proper permissions.

## Build Commands

```bash
# Build the project
xcodebuild -project AudioCap.xcodeproj -scheme AudioCap -configuration Debug build

# Clean build folder
xcodebuild -project AudioCap.xcodeproj -scheme AudioCap clean

# Run tests (if any)
xcodebuild -project AudioCap.xcodeproj -scheme AudioCap test
```

## Architecture

### Core Components

- **AudioCapApp.swift**: Main app entry point with SwiftUI App protocol
- **RootView.swift**: Main view controller handling permission states
- **ProcessTap/**: Contains the core audio capture functionality
  - **ProcessTap.swift**: Main process audio tap implementation with recording capabilities
  - **SystemAudioRecorder.swift**: System-wide audio recording with optional microphone mixing
  - **AudioProcessController.swift**: Manages audio process discovery and grouping
  - **CoreAudioUtils.swift**: CoreAudio utility functions and extensions
  - **AudioRecordingPermission.swift**: Audio recording permission management

### Key Architecture Patterns

- **SwiftUI + Observation**: Uses @Observable for reactive state management
- **CoreAudio Integration**: Direct CoreAudio API usage for process tapping
- **Process Management**: Real-time audio process discovery and categorization
- **Permission-First Design**: UI flow based on audio recording permission status

### Audio Processing Flow

1. **Permission Check**: App checks/requests audio recording permission
2. **Process Discovery**: Scans for running processes with audio capabilities
3. **Process Tap Creation**: Creates CoreAudio taps for selected processes
4. **Aggregate Device Setup**: Creates virtual aggregate audio devices
5. **Recording Pipeline**: Captures audio through AVAudioFile with custom I/O blocks

## Configuration

- **Main.xcconfig**: Contains build configuration including bundle identifier and TCC private API flags
- **Info.plist**: Contains `NSAudioCaptureUsageDescription` for permission prompts
- **AudioCap.entitlements**: Required entitlements for audio capture

## Private API Usage

The project uses private TCC (Transparency, Consent, and Control) APIs controlled by the `ENABLE_TCC_SPI` build flag in Main.xcconfig. This can be disabled by removing the flag, though permission requests will then only trigger when recording starts.

## Development Notes

- **Process Grouping**: Audio processes are automatically grouped by type (Apps vs Processes)
- **Real-time Updates**: Process list updates automatically when applications start/stop
- **Audio Format Handling**: Automatically handles various audio formats through AVAudioFormat
- **Resource Management**: Proper cleanup of CoreAudio resources on deinit/invalidation
- **System Integration**: Uses NSWorkspace for application discovery and system settings integration

## Key Classes

- `ProcessTap`: Manages individual process audio tapping
- `ProcessTapRecorder`: Handles file recording from process taps
- `SystemAudioRecorder`: System-wide audio recording (microphone mixing in development)
- `AudioProcessController`: Process discovery and management
- `AudioProcess`: Represents an audio-capable process with metadata