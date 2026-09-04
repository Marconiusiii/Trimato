import Foundation
import Testing
@testable import Trimato

@Suite struct CaptionFileCodecTests {
    @Test func readsMultilineSubRipCuesAndMillisecondTiming() throws {
        let source = """
        1
        00:00:01,250 --> 00:00:03,500
        <i>First line</i>
        Second &amp; final line
           
        2
        00:00:03,250 --> 00:00:04,000
        Overlapping cue
        """
        let cues = try CaptionFileCodec.decode(data: Data(source.utf8), format: .subRip)
        #expect(cues.count == 2)
        #expect(cues[0].start == ProjectTime(seconds: 1.25))
        #expect(cues[0].end == ProjectTime(seconds: 3.5))
        #expect(cues[0].text == "First line\nSecond & final line")
        #expect(cues[1].start < cues[0].end)
    }

    @Test func readsWebVTTIdentifiersSettingsAndVisibleText() throws {
        let source = """
        WEBVTT

        greeting
        00:01.000 --> 00:03.500 line:90% align:center
        <v Marco>Hello &amp; welcome</v>
        """
        let cue = try #require(CaptionFileCodec.decode(data: Data(source.utf8), format: .webVTT).first)
        #expect(cue.identifier == "greeting")
        #expect(cue.webVTTSettings == "line:90% align:center")
        #expect(cue.text == "Hello & welcome")
    }

    @Test func readsUTF16WithAByteOrderMark() throws {
        let text = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        #expect(try CaptionFileCodec.decode(data: data, format: .subRip).first?.text == "Hello")
    }

    @Test func exportsExpectedSubRipAndWebVTTTimeSeparators() throws {
        let cue = CaptionCue(start: ProjectTime(seconds: 1.25), end: ProjectTime(seconds: 3.5), text: "Hello")
        let srt = String(decoding: try CaptionFileCodec.encode([cue], format: .subRip), as: UTF8.self)
        let vtt = String(decoding: try CaptionFileCodec.encode([cue], format: .webVTT), as: UTF8.self)
        #expect(srt.contains("00:00:01,250 --> 00:00:03,500"))
        #expect(vtt.contains("00:00:01.250 --> 00:00:03.500"))
    }

    @Test func clipsAndShiftsCuesForAnExportRange() {
        let cues = [
            CaptionCue(start: ProjectTime(seconds: 4), end: ProjectTime(seconds: 7), text: "One"),
            CaptionCue(start: ProjectTime(seconds: 8), end: ProjectTime(seconds: 12), text: "Two")
        ]
        let result = CaptionFileCodec.cues(cues, within: ProjectTimeRange(
            start: ProjectTime(seconds: 5), duration: ProjectTime(seconds: 5)
        ))
        #expect(result.map(\.start) == [.zero, ProjectTime(seconds: 3)])
        #expect(result.map(\.end) == [ProjectTime(seconds: 2), ProjectTime(seconds: 5)])
    }

    @Test func rejectsMissingHeadersAndBackwardTiming() {
        #expect(throws: CaptionFileError.self) {
            try CaptionFileCodec.decode(data: Data("00:00.000 --> 00:01.000\nHello".utf8), format: .webVTT)
        }
        #expect(throws: CaptionFileError.self) {
            try CaptionFileCodec.decode(
                data: Data("1\n00:00:02,000 --> 00:00:01,000\nHello".utf8),
                format: .subRip
            )
        }
    }
}
