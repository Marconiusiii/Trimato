import AppKit
import Combine
import Foundation
import AVFoundation
@testable import Trimato

@main struct MixerStressCheck {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  precondition(NSApp == nil, "This check must not create an application or windows")
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
  let undo = UndoManager()
  undo.groupsByEvent = false
  controller.installUndoManager(undo)
  for looping in [false, true] {
   player.stopMixerPlayback()
   player.seek(to: ProjectTime(seconds: 0.4))
   try await Task.sleep(for: .milliseconds(100))
   player.markIn()
   player.seek(to: ProjectTime(seconds: 1.0))
   try await Task.sleep(for: .milliseconds(100))
   player.markOut()
   player.setMixerLoopEnabled(looping)
   player.seek(to: ProjectTime(seconds: 0.4))
   try await Task.sleep(for: .milliseconds(100))
   session.togglePlayback()
   let before = controller.project
   var notifications = 0
   let observation = controller.document.objectWillChange.sink { notifications += 1 }
   undo.beginUndoGrouping()
   var durations: [Double] = []
   for step in 0..<300 {
    let start = ContinuousClock.now
    controller.mixerSliderEditingChanged(true)
    session.change(\.pan, to: Double(step % 101) / 50 - 1)
    session.change(\.volumeDB, to: -Double(step % 25))
    controller.mixerSliderEditingChanged(false)
    let elapsed = start.duration(to: .now).components
    durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    try await Task.sleep(for: .milliseconds(2))
   }
   precondition(notifications == 0, "Rapid mixing invalidated the whole document")
   precondition(controller.hasPendingMixerAdjustment && controller.document.hasUnsavedChanges)
   let snapshot = try controller.document.snapshot(contentType: .trimatoProject)
   precondition(snapshot == controller.project, "Save snapshot missed pending mix values")
   precondition(snapshot.tracks[0].mix.pan == session.selected?.mix.pan)
   controller.mixerAdjustmentEditing(false)
   undo.endUndoGrouping()
   precondition(notifications == 1, "Mix burst did not coalesce into one document update")
   let after = controller.project
   undo.undo()
   precondition(controller.project == before, "Undo did not restore the whole burst")
   undo.redo()
   precondition(controller.project == after, "Redo lost the final values")
   precondition(player.player.currentItem === item && !player.isPreparing)
   durations.sort()
   print("PASS: \(looping ? "Loop" : "Playback") 600 rapid adjustments, one document notification; immediate save snapshot, Undo/Redo, same playback item; p95 pair cost \(durations[285]) ms, max \(durations.last!) ms")
   withExtendedLifetime(observation) {}
   player.stopMixerPlayback()
  }
  undo.beginUndoGrouping()
  session.change(\.pan, to: 0.37)
  session.close()
  undo.endUndoGrouping()
  precondition(!controller.hasPendingMixerAdjustment && player.player.rate == 0)
  try await Task.sleep(for: .milliseconds(350))
  precondition(controller.project.tracks[0].mix.pan == 0.37)
  print("PASS: Closing flushes the final adjustment without delayed overwrite")

  undo.beginUndoGrouping()
  session.change(\.pan, to: 0.19)
  controller.saveProjectDocument() // No coordinator: exercise the save flush without opening a panel.
  precondition(!controller.hasPendingMixerAdjustment)
  undo.endUndoGrouping()
  undo.beginUndoGrouping()
  session.change(\.pan, to: 0.29)
  try await Task.sleep(for: .milliseconds(350))
  precondition(!controller.hasPendingMixerAdjustment && controller.project.tracks[0].mix.pan == 0.29)
  undo.endUndoGrouping()
  print("PASS: Save flush and idle completion preserve the last value")

  let suite = "trimato-waveform-check-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  precondition(!AppPreferences.showAudioWaveforms(in: defaults))
  let clip = VideoPlayerViewModel(waveformPreferences: defaults)
  clip.player.isMuted = true
  let avAsset = AVURLAsset(url: url)
  let source = MediaSource.native(url: url, asset: avAsset, contentType: nil,
      mode: .nativePassthrough, hasVideo: false, hasAudio: true)
  clip.load(url: url, preparedSource: source)
  for _ in 0..<200 {
   if clip.hasMedia && !clip.isLoadingMedia { break }
   try await Task.sleep(for: .milliseconds(25))
  }
  precondition(clip.hasMedia && !clip.isLoadingMedia && !clip.isPreparingMedia)
  precondition(!clip.showsAudioWaveforms && !clip.isPreparingWaveform && clip.waveformSamples.isEmpty)
  let clipItem = clip.player.currentItem
  defaults.set(true, forKey: AppPreferenceKey.showAudioWaveforms)
  NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
  for _ in 0..<200 {
   if clip.showsAudioWaveforms && !clip.waveformSamples.isEmpty { break }
   try await Task.sleep(for: .milliseconds(25))
  }
  precondition(clip.showsAudioWaveforms && !clip.waveformSamples.isEmpty)
  precondition(!clip.isPreparingMedia && clip.player.currentItem === clipItem)
  precondition(AppPreferences.showAudioWaveforms(in: UserDefaults(suiteName: suite)!))
  defaults.set(false, forKey: AppPreferenceKey.showAudioWaveforms)
  clip.refreshWaveformPreference()
  precondition(!clip.showsAudioWaveforms && clip.waveformSamples.isEmpty && !clip.isPreparingWaveform)
  defaults.set(true, forKey: AppPreferenceKey.showAudioWaveforms)
  clip.refreshWaveformPreference()
  precondition(clip.isPreparingWaveform && !clip.isPreparingMedia)
  clip.cancelMediaLoad()
  precondition(clip.hasMedia && !clip.isPreparingMedia && clip.isPreparingWaveform, "Optional analysis must not turn a completed import into cancellation")
  defaults.set(false, forKey: AppPreferenceKey.showAudioWaveforms)
  clip.refreshWaveformPreference()
  try await Task.sleep(for: .milliseconds(300))
  precondition(clip.waveformSamples.isEmpty && !clip.isPreparingWaveform && !clip.isPreparingMedia)
  clip.closeMedia()
  precondition(NSApp == nil)
  print("PASS: waveform default off, persisted toggle, enable in open clip, disable/cancel, no late samples, media readiness independent of waveform")
 }
}
