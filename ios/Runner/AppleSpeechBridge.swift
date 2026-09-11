import AVFoundation
import Flutter
import Speech
import SwiftUI
import Translation
import UIKit

private func speechError(_ code: String) -> NSError {
  NSError(domain: "SoundcoreAppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: code])
}

private func speechErrorCode(_ error: Error) -> String {
  if error is CancellationError { return "cancelled" }
  let error = error as NSError
  return error.domain == "SoundcoreAppleSpeech" ? error.localizedDescription : "processing_failed"
}

/// Pure accumulation also used by the native regression tests. A volatile range
/// replaces its predecessor; finalized ranges are immutable and stay ordered.
struct AppleSpeechTranscript {
  struct Segment {
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
  }
  private(set) var segments = [Segment]()

  mutating func apply(text: String, start: Double, end: Double, isFinal: Bool) -> Bool {
    guard start.isFinite, end.isFinite, end >= start else { return false }
    if segments.contains(where: { $0.isFinal && $0.start == start && $0.end == end }) {
      return false
    }
    segments.removeAll { !$0.isFinal && ($0.start == start || ($0.start < end && start < $0.end)) }
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.isEmpty {
      segments.append(Segment(start: start, end: end, text: cleaned, isFinal: isFinal))
      segments.sort { $0.start < $1.start }
    }
    return isFinal && !cleaned.isEmpty
  }

  var text: String { segments.map(\.text).joined(separator: "\n") }
}

/// Split at paragraph/sentence/word boundaries when possible without breaking
/// grapheme clusters. Translation responses are appended in this exact order.
func appleTranslationChunks(_ text: String, limit: Int = 2400) -> [String] {
  guard limit > 0 else { return [] }
  var remaining = text[...]
  var chunks = [String]()
  while !remaining.isEmpty {
    let maximum = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex)
      ?? remaining.endIndex
    var end = maximum
    if maximum != remaining.endIndex {
      let candidate = remaining[..<maximum]
      if let boundary = candidate.lastIndex(where: { $0 == "\n" || $0 == "。" || $0 == "." || $0 == " " }),
        candidate.distance(from: candidate.startIndex, to: boundary) >= limit / 2
      {
        end = remaining.index(after: boundary)
      }
    }
    let chunk = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    if !chunk.isEmpty { chunks.append(chunk) }
    remaining = remaining[end...]
  }
  return chunks
}

@MainActor
final class AppleSpeechBridge: NSObject, @preconcurrency FlutterStreamHandler {
  static let shared = AppleSpeechBridge()
  private var sink: FlutterEventSink?
  private var runtimeStorage: AnyObject?

  func configure(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "soundcore/apple_speech", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { return reply(FlutterError(code: "cancelled", message: nil, details: nil)) }
      self.handle(call, reply: reply)
    }
    FlutterEventChannel(name: "soundcore/apple_speech/events", binaryMessenger: binaryMessenger)
      .setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  @available(iOS 26.0, *)
  private var runtime: AppleSpeechRuntime {
    if let value = runtimeStorage as? AppleSpeechRuntime { return value }
    let value = AppleSpeechRuntime { [weak self] event in self?.sink?(event) }
    runtimeStorage = value
    return value
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard #available(iOS 26.0, *) else {
      if call.method == "capabilities" {
        reply(["supported": false, "speechStatus": "unsupported", "translationStatus": "unsupported"])
      } else if call.method == "closeStream" || call.method == "cancelFile" {
        reply(nil)
      } else { reply(FlutterError(code: "unsupported", message: nil, details: nil)) }
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let runtime = runtime
    // PCM submission is synchronous on the platform thread, retaining ordering
    // with finishStream and avoiding one unbounded Swift Task per audio packet.
    if call.method == "appendPcm" {
      do {
        guard let id = args["sessionId"] as? String, let data = args["pcm"] as? FlutterStandardTypedData
        else { throw speechError("audio_invalid") }
        try runtime.append(id: id, data: data.data)
        reply(nil)
      } catch { reply(FlutterError(code: speechErrorCode(error), message: nil, details: nil)) }
      return
    }
    Task { @MainActor in
      do {
        switch call.method {
        case "capabilities":
          reply(await AppleSpeechResources.capabilities(
            source: args["sourceLanguage"] as? String, target: args["targetLanguage"] as? String))
        case "prepareLanguages":
          try await runtime.prepare(id: try required("jobId", args),
            source: try required("sourceLanguage", args), target: args["targetLanguage"] as? String)
          reply(nil)
        case "prepareTranslation":
          try await runtime.prepareTranslation(id: try required("jobId", args),
            source: try required("sourceLanguage", args),
            target: try required("targetLanguage", args))
          reply(nil)
        case "startStream":
          try await runtime.start(id: try required("sessionId", args),
            source: try required("sourceLanguage", args), target: args["targetLanguage"] as? String)
          reply(nil)
        case "finalizeUtterance":
          try await runtime.finalize(id: try required("sessionId", args))
          reply(nil)
        case "finishStream":
          reply(try await runtime.finish(id: try required("sessionId", args)))
        case "closeStream":
          await runtime.close(id: try required("sessionId", args))
          reply(nil)
        case "transcribeFile":
          reply(try await runtime.transcribe(id: try required("jobId", args),
            path: try required("path", args), source: try required("sourceLanguage", args)))
        case "translate":
          reply(try await runtime.translate(id: try required("jobId", args),
            text: args["text"] as? String ?? "", source: try required("sourceLanguage", args),
            target: try required("targetLanguage", args)))
        case "cancelFile":
          await runtime.cancelFile(id: args["jobId"] as? String)
          reply(nil)
        default: reply(FlutterMethodNotImplemented)
        }
      } catch { reply(FlutterError(code: speechErrorCode(error), message: nil, details: nil)) }
    }
  }

  private func required(_ key: String, _ args: [String: Any]) throws -> String {
    guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw speechError("language_unsupported") }
    return value
  }
}

@available(iOS 26.0, *)
private enum AppleSpeechResources {
  static func module(source: String, live: Bool, requireInstalled: Bool) async throws -> any SpeechModule {
    let locale = Locale(identifier: source)
    if SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    {
      if requireInstalled, !(await SpeechTranscriber.installedLocales.contains(supported)) {
        throw speechError("resources_missing")
      }
      return SpeechTranscriber(locale: supported, transcriptionOptions: [],
        reportingOptions: live ? [.volatileResults] : [], attributeOptions: [.audioTimeRange])
    }
    guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale)
    else { throw speechError("language_unsupported") }
    if requireInstalled, !(await DictationTranscriber.installedLocales.contains(supported)) {
      throw speechError("resources_missing")
    }
    return DictationTranscriber(locale: supported, contentHints: [.farField],
      transcriptionOptions: [.punctuation],
      reportingOptions: live ? [.volatileResults, .frequentFinalization] : [], attributeOptions: [.audioTimeRange])
  }

  static func speechStatus(_ source: String?) async -> String {
    guard let source, !source.isEmpty else { return "unsupported" }
    do {
      _ = try await module(source: source, live: false, requireInstalled: true)
      return "ready"
    } catch { return speechErrorCode(error) == "resources_missing" ? "needsDownload" : "unsupported" }
  }

  static func translationStatus(source: String?, target: String?) async -> String {
    guard let source, !source.isEmpty, let target, !target.isEmpty else { return "unsupported" }
    if Locale.Language(identifier: source) == Locale.Language(identifier: target) { return "ready" }
    switch await LanguageAvailability().status(
      from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    {
    case .installed: return "ready"
    case .supported: return "needsDownload"
    default: return "unsupported"
    }
  }

  static func capabilities(source: String?, target: String?) async -> [String: Any] {
    let speechLocales = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
    let dictationLocales = await DictationTranscriber.supportedLocales
    let locales = Array(Set(speechLocales + dictationLocales)).sorted { $0.identifier < $1.identifier }
    let translationLanguages = await LanguageAvailability().supportedLanguages
    var suggested: String?
    for preference in Locale.preferredLanguages {
      let preferred = Locale(identifier: preference)
      if SpeechTranscriber.isAvailable,
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
      {
        suggested = locale.identifier.replacingOccurrences(of: "_", with: "-")
        break
      }
      if let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
        suggested = locale.identifier.replacingOccurrences(of: "_", with: "-")
        break
      }
    }
    var response: [String: Any] = [
      "supported": !locales.isEmpty,
      "speechStatus": await speechStatus(source),
      "translationStatus": await translationStatus(source: source, target: target),
      "speechLanguages": locales.map { language($0.identifier) },
      "translationLanguages": translationLanguages.map { language($0.minimalIdentifier) },
    ]
    if let suggested { response["suggestedSourceLanguage"] = suggested }
    return response
  }

  private static func language(_ code: String) -> [String: String] {
    ["code": code.replacingOccurrences(of: "_", with: "-"),
     "name": Locale.current.localizedString(forIdentifier: code) ?? code]
  }

  static func prepareSpeech(source: String) async throws {
    try Task.checkCancellation()
    let module = try await module(source: source, live: false, requireInstalled: false)
    try Task.checkCancellation()
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await request.downloadAndInstall()
      } onCancel: {
        request.progress.cancel()
      }
    }
    try Task.checkCancellation()
  }

  static func translate(text: String, source: String, target: String) async throws -> String {
    try Task.checkCancellation()
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
    if Locale.Language(identifier: source) == Locale.Language(identifier: target) { return text }
    let status = await translationStatus(source: source, target: target)
    guard status == "ready" else {
      throw speechError(status == "unsupported" ? "language_unsupported" : "resources_missing")
    }
    let session = TranslationSession(installedSource: Locale.Language(identifier: source),
      target: Locale.Language(identifier: target))
    var result = [String]()
    for chunk in appleTranslationChunks(text) {
      try Task.checkCancellation()
      let translated = try await session.translate(chunk).targetText
      try Task.checkCancellation()
      result.append(translated)
    }
    return result.joined(separator: "\n\n")
  }
}

@available(iOS 26.0, *)
@MainActor
private final class AppleSpeechRuntime {
  let emit: ([String: Any]) -> Void
  var stream: AppleLiveSpeech?
  var pendingStreamID: String?
  var fileID: String?
  var fileTask: Task<Any, Error>?
  var fileAnalyzer: SpeechAnalyzer?
  private var preparationID: String?
  private var preparationTask: Task<Void, Error>?
  private var cancelPreparationPresentation: (() -> Void)?
  private var preparing: Bool { preparationID != nil }

  init(emit: @escaping ([String: Any]) -> Void) { self.emit = emit }

  private func preparation(id: String, operation: @escaping @MainActor () async throws -> Void) async throws {
    guard !preparing, stream == nil, pendingStreamID == nil, fileID == nil else { throw speechError("busy") }
    preparationID = id
    let task = Task { @MainActor in
      try Task.checkCancellation()
      try await operation()
      try Task.checkCancellation()
    }
    preparationTask = task
    defer {
      if preparationID == id {
        preparationID = nil
        preparationTask = nil
        cancelPreparationPresentation = nil
      }
    }
    try await task.value
    guard preparationID == id else { throw speechError("cancelled") }
  }

  func prepare(id: String, source: String, target: String?) async throws {
    try await preparation(id: id) { [self] in
      try await AppleSpeechResources.prepareSpeech(source: source)
      guard let target, !target.isEmpty else { return }
      try await prepareTranslationResources(source: source, target: target)
    }
  }

  func prepareTranslation(id: String, source: String, target: String) async throws {
    try await preparation(id: id) { [self] in
      try await prepareTranslationResources(source: source, target: target)
    }
  }

  private func prepareTranslationResources(source: String, target: String) async throws {
    try Task.checkCancellation()
    let status = await AppleSpeechResources.translationStatus(source: source, target: target)
    try Task.checkCancellation()
    if status == "ready" { return }
    guard status != "unsupported" else { throw speechError("language_unsupported") }
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController
    else { throw speechError("preparation_unavailable") }
    while let presented = presenter.presentedViewController { presenter = presented }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      weak var host: UIViewController?
      var finished = false
      let completion: (Error?) -> Void = { error in
        guard !finished else { return }
        finished = true
        host?.dismiss(animated: true)
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
      cancelPreparationPresentation = { completion(speechError("cancelled")) }
      let controller = UIHostingController(rootView:
        ApplePrepareTranslationView(source: source, target: target, completion: completion))
      host = controller
      controller.modalPresentationStyle = .formSheet
      presenter.present(controller, animated: true)
    }
    try Task.checkCancellation()
  }

  private func cancelPreparation(id: String?) {
    guard let current = preparationID, id == nil || id == current else { return }
    preparationTask?.cancel()
    cancelPreparationPresentation?()
    preparationID = nil
    preparationTask = nil
    cancelPreparationPresentation = nil
  }

  func start(id: String, source: String, target: String?) async throws {
    guard stream == nil, pendingStreamID == nil else { throw speechError("busy") }
    pendingStreamID = id
    defer { if pendingStreamID == id { pendingStreamID = nil } }
    await cancelFile(id: nil)
    let module = try await AppleSpeechResources.module(source: source, live: true, requireInstalled: true)
    guard pendingStreamID == id else { throw speechError("cancelled") }
    // Missing translation assets fail before accepting audio, never upload it.
    if let target, !target.isEmpty {
      let status = await AppleSpeechResources.translationStatus(source: source, target: target)
      guard status == "ready" else {
        throw speechError(status == "unsupported" ? "language_unsupported" : "resources_missing")
      }
    }
    guard pendingStreamID == id else { throw speechError("cancelled") }
    let value = AppleLiveSpeech(id: id, module: module, source: source, target: target, emit: emit)
    stream = value
    do {
      try await value.start()
      guard stream === value, pendingStreamID == id else { throw speechError("cancelled") }
    } catch {
      if stream === value { stream = nil }
      await value.cancel()
      throw error
    }
  }

  func append(id: String, data: Data) throws {
    guard let stream, stream.id == id else { throw speechError("cancelled") }
    try stream.append(data)
  }

  func finalize(id: String) async throws {
    guard let stream, stream.id == id else { return }
    try await stream.finalize()
  }

  func finish(id: String) async throws -> [String: Any]? {
    guard let value = stream, value.id == id else { return nil }
    defer { if stream === value { stream = nil } }
    return try await value.finish()
  }

  func close(id: String) async {
    if pendingStreamID == id { pendingStreamID = nil }
    guard let value = stream, value.id == id else { return }
    stream = nil
    await value.cancel()
  }

  private func fileOperation(id: String, operation: @escaping @MainActor () async throws -> Any) async throws -> Any {
    guard stream == nil, pendingStreamID == nil, !preparing, fileID == nil else { throw speechError("busy") }
    fileID = id
    let task = Task { @MainActor in try await operation() }
    fileTask = task
    defer {
      if fileID == id { fileID = nil; fileTask = nil; fileAnalyzer = nil }
    }
    let value = try await task.value
    guard fileID == id else { throw speechError("cancelled") }
    return value
  }

  func transcribe(id: String, path: String, source: String) async throws -> Any {
    try await fileOperation(id: id) { [self] in
      let module = try await AppleSpeechResources.module(source: source, live: false, requireInstalled: true)
      try Task.checkCancellation()
      let file: AVAudioFile
      do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
      catch { throw speechError("audio_invalid") }
      let analyzer = SpeechAnalyzer(modules: [module])
      fileAnalyzer = analyzer
      let collector = Task { @MainActor () throws -> String in
        var transcript = AppleSpeechTranscript()
        try await collectAppleResults(module) { text, range, final in
          if final {
            _ = transcript.apply(text: text, start: range.start.seconds,
              end: CMTimeRangeGetEnd(range).seconds, isFinal: true)
          }
        }
        return transcript.text
      }
      do {
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let text = try await collector.value
        try Task.checkCancellation()
        return ["text": text, "durationSec": Double(file.length) / file.processingFormat.sampleRate]
      } catch {
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
      }
    }
  }

  func translate(id: String, text: String, source: String, target: String) async throws -> Any {
    try await fileOperation(id: id) {
      try await AppleSpeechResources.translate(text: text, source: source, target: target)
    }
  }

  func cancelFile(id: String?) async {
    cancelPreparation(id: id)
    guard id == nil || id == fileID else { return }
    let cancelledID = fileID
    let task = fileTask
    let analyzer = fileAnalyzer
    task?.cancel()
    await analyzer?.cancelAndFinishNow()
    // Cancellation owns the resource until its current framework call returns.
    // A second saved job must not race the cancelled analyzer/translation task.
    _ = try? await task?.value
    if fileID == cancelledID {
      fileID = nil
      fileTask = nil
      fileAnalyzer = nil
    }
  }
}

@available(iOS 26.0, *)
@MainActor
private func collectAppleResults(_ module: any SpeechModule,
  receive: (String, CMTimeRange, Bool) -> Void) async throws
{
  if let transcriber = module as? SpeechTranscriber {
    for try await result in transcriber.results {
      try Task.checkCancellation()
      receive(String(result.text.characters), result.range, result.isFinal)
    }
  } else if let transcriber = module as? DictationTranscriber {
    for try await result in transcriber.results {
      try Task.checkCancellation()
      receive(String(result.text.characters), result.range, result.isFinal)
    }
  }
}

/// A single input converter is retained across packets so resampling phase and
/// pending samples survive the D3200's short PCM notifications.
final class ApplePCMConverter {
  let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
    channels: 1, interleaved: false)!
  let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private var trailingByte: UInt8?

  init(outputFormat: AVAudioFormat) throws {
    self.outputFormat = outputFormat
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { throw speechError("audio_invalid") }
    self.converter = converter
  }

  func convert(_ data: Data, emit: (AVAudioPCMBuffer) throws -> Void) throws {
    var bytes = data
    if let trailingByte { bytes.insert(trailingByte, at: bytes.startIndex); self.trailingByte = nil }
    if !bytes.count.isMultiple(of: 2) { trailingByte = bytes.removeLast() }
    guard !bytes.isEmpty else { return }
    let frames = AVAudioFrameCount(bytes.count / 2)
    guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
      let samples = input.int16ChannelData?[0] else { throw speechError("audio_invalid") }
    input.frameLength = frames
    _ = bytes.withUnsafeBytes { pointer in memcpy(samples, pointer.baseAddress!, bytes.count) }
    try convert(input: input, ending: false, emit: emit)
  }

  func finish(emit: (AVAudioPCMBuffer) throws -> Void) throws {
    guard trailingByte == nil else { throw speechError("audio_invalid") }
    try convert(input: nil, ending: true, emit: emit)
  }

  private func convert(input: AVAudioPCMBuffer?, ending: Bool,
    emit: (AVAudioPCMBuffer) throws -> Void) throws
  {
    let capacity = AVAudioFrameCount(max(1024,
      ceil(Double(input?.frameLength ?? 0) * outputFormat.sampleRate / inputFormat.sampleRate) + 64))
    var supplied = false
    while true {
      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
      else { throw speechError("audio_invalid") }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if !supplied, let input {
          supplied = true
          inputStatus.pointee = .haveData
          return input
        }
        inputStatus.pointee = ending ? .endOfStream : .noDataNow
        return nil
      }
      if let error { throw error }
      if status == .error { throw speechError("audio_invalid") }
      if output.frameLength > 0 { try emit(output) }
      if status != .haveData { break }
    }
  }
}

@available(iOS 26.0, *)
@MainActor
private final class AppleLiveSpeech {
  let id: String
  let module: any SpeechModule
  let source: String
  let target: String?
  let emit: ([String: Any]) -> Void
  let analyzer: SpeechAnalyzer
  private var converter: ApplePCMConverter?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var resultsTask: Task<Void, Error>?
  private var analysisTask: Task<Void, Error>?
  private var translationTask: Task<Void, Never>?
  private var transcript = AppleSpeechTranscript()
  private var translationTurns = [[String: Any]]()
  private var translationQueue = [String]()
  private var acceptingTranslation = true
  private var cancelled = false
  private var finishing = false
  private var inputFrames: Int64 = 0
  private var inputRate: Double = 16000
  private var failure: Error?

  init(id: String, module: any SpeechModule, source: String, target: String?,
    emit: @escaping ([String: Any]) -> Void)
  {
    self.id = id; self.module = module; self.source = source; self.target = target; self.emit = emit
    analyzer = SpeechAnalyzer(modules: [module])
  }

  func start() async throws {
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    else { throw speechError("audio_invalid") }
    guard !cancelled else { throw speechError("cancelled") }
    converter = try ApplePCMConverter(outputFormat: format)
    inputRate = format.sampleRate
    // Bound the native queue to five seconds in 100 ms buffers. The caller also
    // bounds bytes waiting on the method channel; neither layer drops silently.
    let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(50))
    self.continuation = continuation
    resultsTask = Task { @MainActor [weak self, module] in
      do {
        try await collectAppleResults(module) { text, range, final in
          self?.receive(text: text, range: range, final: final)
        }
      } catch {
        if let self, !self.cancelled { self.fail(error) }
        throw error
      }
    }
    try await analyzer.prepareToAnalyze(in: format)
    guard !cancelled else { throw speechError("cancelled") }
    analysisTask = Task { @MainActor [weak self, analyzer] in
      do { try await analyzer.start(inputSequence: input) }
      catch {
        if let self, !self.cancelled { self.fail(error) }
        throw error
      }
    }
    emit(snapshot(type: "created"))
  }

  func append(_ data: Data) throws {
    guard !cancelled, !finishing, let converter else { throw speechError("cancelled") }
    if let failure { throw failure }
    // Keep each queued buffer <=100 ms regardless of Bluetooth packet size.
    for offset in stride(from: 0, to: data.count, by: 3200) {
      try converter.convert(data.subdata(in: offset..<min(offset + 3200, data.count))) { buffer in
        try enqueue(buffer)
      }
    }
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer) throws {
    guard let continuation else { throw speechError("cancelled") }
    let time = CMTime(value: inputFrames, timescale: CMTimeScale(inputRate))
    switch continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) {
    case .enqueued: inputFrames += Int64(buffer.frameLength)
    case .dropped:
      let error = speechError("audio_buffer_full")
      fail(error)
      throw error
    case .terminated: throw speechError("cancelled")
    @unknown default: throw speechError("processing_failed")
    }
  }

  private func receive(text: String, range: CMTimeRange, final: Bool) {
    guard !cancelled else { return }
    let addedFinal = transcript.apply(text: text, start: range.start.seconds,
      end: CMTimeRangeGetEnd(range).seconds, isFinal: final)
    if addedFinal, acceptingTranslation, let target, !target.isEmpty {
      // Translation can lag behind dictation. Bound pending source characters;
      // a warning retains all source text for the explicit saved Translate action.
      if translationQueue.reduce(0, { $0 + $1.count }) + text.count > 24000 {
        acceptingTranslation = false
        translationQueue.removeAll()
        translationTask?.cancel()
        emit(snapshot(type: "translationError", error: "translation_queue_full"))
      } else {
        translationQueue.append(text)
        drainTranslation()
      }
    }
    emit(snapshot(type: "partial", final: final))
  }

  private func drainTranslation() {
    guard translationTask == nil, let target else { return }
    translationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.translationTask = nil }
      while !self.translationQueue.isEmpty && self.acceptingTranslation && !self.cancelled {
        let text = self.translationQueue[0]
        do {
          let translated = try await AppleSpeechResources.translate(text: text, source: self.source, target: target)
          guard !Task.isCancelled, self.acceptingTranslation, !self.cancelled else { return }
          self.translationQueue.removeFirst()
          self.translationTurns.append(["sourceLanguage": self.source, "targetLanguage": target,
            "sourceText": text, "text": translated, "isFinal": true])
          self.emit(self.snapshot(type: "partial", final: true))
        } catch {
          guard !Task.isCancelled, self.acceptingTranslation, !self.cancelled else { return }
          self.translationQueue.removeAll()
          self.acceptingTranslation = false
          self.emit(self.snapshot(type: "translationError", error: speechErrorCode(error)))
        }
      }
    }
  }

  func finalize() async throws {
    guard !cancelled, !finishing else { return }
    try await analyzer.finalize(through: nil)
  }

  func finish() async throws -> [String: Any] {
    guard !cancelled else { throw speechError("cancelled") }
    finishing = true
    do {
      if let failure { throw failure }
      try converter?.finish { try enqueue($0) }
      continuation?.finish()
      try await analysisTask?.value
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      try await resultsTask?.value
      // Finalization can add the last source segment. Keep translation accepting
      // until all source results have arrived, then drain that same ordered task.
      await translationTask?.value
      guard !cancelled else { throw speechError("cancelled") }
      acceptingTranslation = false
      let result = snapshot(type: "done", final: true)
      return result
    } catch {
      await cancel()
      throw error
    }
  }

  private func stopTranslation() {
    acceptingTranslation = false
    translationQueue.removeAll()
    translationTask?.cancel()
    translationTask = nil
  }

  func cancel() async {
    guard !cancelled else { return }
    cancelled = true
    stopTranslation()
    continuation?.finish()
    continuation = nil
    analysisTask?.cancel()
    resultsTask?.cancel()
    await analyzer.cancelAndFinishNow()
    converter = nil
  }

  private func fail(_ error: Error) {
    guard failure == nil, !cancelled else { return }
    failure = error
    stopTranslation()
    continuation?.finish()
    emit(snapshot(type: "error", error: speechErrorCode(error)))
  }

  private func snapshot(type: String, final: Bool = false, error: String? = nil) -> [String: Any] {
    let sourceFinal = final && transcript.segments.allSatisfy(\.isFinal)
    var value: [String: Any] = ["sessionId": id, "type": type, "text": transcript.text,
      "isFinal": sourceFinal, "speechFinal": sourceFinal, "durationSec": Double(inputFrames) / inputRate,
      "translationTurns": translationTurns]
    if let error { value["error"] = error }
    if !translationQueue.isEmpty { value["pendingTranslationSource"] = translationQueue.joined(separator: "\n") }
    return value
  }
}

@available(iOS 26.0, *)
private struct ApplePrepareTranslationView: View {
  let source: String
  let target: String
  let completion: (Error?) -> Void
  @State private var completed = false

  var body: some View {
    VStack(spacing: 20) {
      ProgressView("准备翻译语言")
      Button("取消") { finish(speechError("cancelled")) }
    }
    .padding(40)
    .translationTask(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target)) { session in
      do { try await session.prepareTranslation(); finish(nil) }
      catch { finish(error) }
    }
    .onDisappear { if !completed { finish(speechError("cancelled")) } }
  }

  private func finish(_ error: Error?) {
    guard !completed else { return }
    completed = true
    completion(error)
  }
}
