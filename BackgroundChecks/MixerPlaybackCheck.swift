import Foundation
import AVFoundation
@testable import Trimato

@main struct MixerIntegration {
 @MainActor static func main() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("source.wav")
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
  buffer.frameLength = 144000
  for i in 0..<144000 { for c in 0..<2 { buffer.floatChannelData![c][i] = Float(sin(Double(i)*2 * .pi*440/48000)*0.2) } }
  var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
  do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buffer) }
  let segment = SourceSegment(sourceRange: ProjectTimeRange(start: .zero, duration: ProjectTime(seconds: 3)))
  let asset = MediaAssetRecord(name: "Voice", originalPath: url.path, duration: ProjectTime(seconds: 3), hasAudio: true, sourceEdit: [segment], playbackMode: .nativePassthrough)
  var project = TrimatoProject(name: "Mixer background check")
  project.media = [asset]
  project.tracks = [TimelineTrack(name: "Voice", kind: .audio, clips: [TimelineClip(assetID: asset.id, name: "Voice", segments: [segment])]), TimelineTrack(name: "Music", kind: .audio, clips: [TimelineClip(assetID: asset.id, name: "Music", segments: [segment])])]
  let controller = ProjectController(document: ProjectDocument(project: project))
  let player = ProjectPlayerViewModel()
  controller.installProjectPlayer(player)
  player.player.isMuted = true // Exercise transport without sending sound to any output.
  player.prepare(project: project, mediaURLs: [asset.id: url])
  for _ in 0..<100 { if player.canControlPlayback { break }; try await Task.sleep(for: .milliseconds(50)) }
  guard player.canControlPlayback, let item = player.player.currentItem else { fatalError("Preparation failed: \(String(describing: player.errorMessage))") }
  let session = MixerSession(controller: controller, player: player)
  session.togglePlayback()
  try await Task.sleep(for: .milliseconds(500))
  let before = player.player.currentTime().seconds
  session.change(\.volumeDB, to: -6)
  session.selectAdjacentTrack(1)
  session.change(\.pan, to: 0.5)
  try await Task.sleep(for: .milliseconds(500))
  let after = player.player.currentTime().seconds
  precondition(after > before && before > 0, "Playback did not advance")
  precondition(player.player.currentItem === item && !player.isPreparing, "Mix edit replaced playback")
  precondition(controller.document.hasUnsavedChanges)
  print("Project playback advanced from", before, "to", after, "with the same player item during track edits")
  player.stopMixerPlayback()
  player.seek(to: player.duration)
  try await Task.sleep(for: .milliseconds(150))
  session.togglePlayback()
  try await Task.sleep(for: .milliseconds(400))
  let restarted = player.player.currentTime().seconds
  precondition(restarted > 0 && restarted < 1, "Playback did not restart")
  print("Playback restarted from the end:", restarted)
  player.stopMixerPlayback()
  let mixed = try await ProjectCompositionBuilder.build(project: controller.project, mediaURLs: [asset.id: url], purpose: .finalExport)
  let reader = try AVAssetReader(asset: mixed.composition)
  let audio = try await mixed.composition.loadTracks(withMediaType: .audio)
  let output = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVNumberOfChannelsKey: 2])
  output.audioMix = mixed.audioMix
  reader.add(output)
  precondition(reader.startReading())
  var peak: Float = 0
  while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
   var length = 0; var pointer: UnsafeMutablePointer<Int8>?
   precondition(CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr)
   let values = UnsafeRawPointer(pointer!).assumingMemoryBound(to: Float.self)
   for i in 0..<(length / 4) { peak = max(peak, abs(values[i])) }
  }
  precondition(reader.status == .completed && peak > 0.2, "Project audio mix is silent or incomplete")
  print("Combined project audio contains both tracks; peak:", peak)
 }
}
