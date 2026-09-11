import AVFoundation
import XCTest
@testable import Runner

final class AppleSpeechNativeTests: XCTestCase {
  func testVolatileTextIsReplacedAndFinalRangesStayOrdered() {
    var transcript = AppleSpeechTranscript()
    XCTAssertFalse(transcript.apply(text: "hel", start: 0, end: 1, isFinal: false))
    XCTAssertFalse(transcript.apply(text: "hello", start: 0, end: 1.2, isFinal: false))
    XCTAssertEqual(transcript.text, "hello")
    XCTAssertTrue(transcript.apply(text: "Hello.", start: 0, end: 1.2, isFinal: true))
    XCTAssertFalse(transcript.apply(text: "stale", start: 0, end: 1.2, isFinal: false))
    XCTAssertTrue(transcript.apply(text: "World.", start: 1.2, end: 2.5, isFinal: true))
    XCTAssertEqual(transcript.text, "Hello.\nWorld.")
  }

  func testLongTranslationChunksKeepOrderAndGraphemeClusters() {
    let text = String(repeating: "👩🏽‍💻中文", count: 1001)
    let chunks = appleTranslationChunks(text, limit: 80)
    XCTAssertTrue(chunks.count > 1)
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 80 })
    XCTAssertEqual(chunks.joined(), text)
  }

  func testPCMResamplingPreservesSamplesAcrossOddPacketBoundaries() throws {
    let samples = (0..<16000).map { Int16(sin(Double($0) * 0.1) * 12000) }
    let data = samples.withUnsafeBytes { Data($0) }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
      channels: 1, interleaved: false)!
    func convert(packetSize: Int) throws -> [Float] {
      let converter = try ApplePCMConverter(outputFormat: format)
      var output = [Float]()
      let receive: (AVAudioPCMBuffer) -> Void = { buffer in
        output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      }
      for offset in stride(from: 0, to: data.count, by: packetSize) {
        try converter.convert(data.subdata(in: offset..<min(offset + packetSize, data.count)), emit: receive)
      }
      try converter.finish(emit: receive)
      return output
    }
    let whole = try convert(packetSize: data.count)
    let packets = try convert(packetSize: 319)
    XCTAssertEqual(whole.count, packets.count)
    XCTAssertGreaterThan(whole.count, 43000)
    XCTAssertLessThan(whole.count, 45000)
    for (a, b) in zip(whole, packets) { XCTAssertEqual(a, b, accuracy: 0.0001) }
  }

  func testTrailingHalfSampleIsRejected() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let converter = try ApplePCMConverter(outputFormat: format)
    try converter.convert(Data([0x10])) { _ in }
    XCTAssertThrowsError(try converter.finish { _ in })
  }
}
