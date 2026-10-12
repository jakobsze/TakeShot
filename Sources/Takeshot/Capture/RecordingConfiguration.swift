import Foundation
import ScreenCaptureKit

/// Everything picked in the pre-recording control bar and settings: what to
/// capture, which (if any) camera/microphone/system-audio to include, and
/// capture options.
struct RecordingConfiguration {
    var source: CaptureSource
    /// `uniqueID` of the camera device to record, or nil for no webcam bubble.
    var cameraDeviceID: String?
    /// `uniqueID` of the microphone device to record, or nil for no mic audio.
    var microphoneDeviceID: String?
    var systemAudioEnabled: Bool = false
    var fps: Int = 60
    var hideDesktopIcons = false
    var recordKeystrokes = true
    var highQuality = true
}
