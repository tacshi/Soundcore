import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  @MainActor
  func testRecordingShortcutIsConsumedExactlyOnce() {
    let suiteName = "RecordingShortcutBridgeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let bridge = RecordingShortcutBridge(defaults: defaults)
    XCTAssertFalse(bridge.consumePendingStartRecording())

    bridge.enqueueStartRecording()
    bridge.enqueueStartRecording()

    XCTAssertTrue(bridge.consumePendingStartRecording())
    XCTAssertFalse(bridge.consumePendingStartRecording())
  }

}
