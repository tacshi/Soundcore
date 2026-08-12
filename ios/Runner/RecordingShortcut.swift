import AppIntents
import Flutter
import Foundation

@MainActor
final class RecordingShortcutBridge {
  static let shared = RecordingShortcutBridge()
  static let channelName = "com.capyvibe.soundcore/recording_shortcut"

  private static let pendingStartKey = "recordingShortcut.pendingStartRecording"

  private let defaults: UserDefaults
  private var channel: FlutterMethodChannel?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumePendingStartRecording" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.consumePendingStartRecording() ?? false)
    }
    self.channel = channel
  }

  func enqueueStartRecording() {
    defaults.set(true, forKey: Self.pendingStartKey)
    channel?.invokeMethod("pendingStartRecording", arguments: nil)
  }

  func consumePendingStartRecording() -> Bool {
    guard defaults.bool(forKey: Self.pendingStartKey) else { return false }
    defaults.removeObject(forKey: Self.pendingStartKey)
    return true
  }
}

@available(iOS 17.0, *)
struct StartRecordingIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Recording"
  static let description = IntentDescription(
    "Open Soundcore Manager and start a recording on the paired D3200."
  )
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @available(iOS, introduced: 17.0, deprecated: 26.0)
  static var openAppWhenRun: Bool { true }

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes { .foreground(.immediate) }

  func perform() async throws -> some IntentResult {
    await MainActor.run {
      RecordingShortcutBridge.shared.enqueueStartRecording()
    }
    return .result()
  }
}

@available(iOS 17.0, *)
struct SoundcoreAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: [
        "Start recording with \(.applicationName)",
        "Start a recording with \(.applicationName)",
      ],
      shortTitle: "Start Recording",
      systemImageName: "record.circle"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .red }
}
