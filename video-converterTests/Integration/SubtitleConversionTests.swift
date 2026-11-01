//
//  SubtitleConversionTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

/// Subtitles show from 0.2 to 1.0 s in every fixture, so frames at 0.6 s should have text
/// burned in and frames at 1.5 s shouldn't.
@Suite("Converting subtitles")
struct SubtitleConversionTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    // MARK: Soft tracks

    @Test func keepsEmbeddedTextAsMovText() async throws {
        let result = try await TestConversion.run(.h264MovText, to: .mp4H264, subtitles: .keepTrack, in: directory)
        let subtitles = try MediaInspector.inspect(result.output).subtitles
        #expect(subtitles.map(\.codecName) == ["mov_text"])
        #expect(subtitles.map(\.isDefault) == [true])
    }

    @Test func sidecarBecomesTheFirstAndOnlyDefaultTrack() async throws {
        let result = try await TestConversion.run(.hevc10TwoSRT, sidecar: .sidecar, to: .mp4H264, subtitles: .keepTrack, in: directory)
        let subtitles = try MediaInspector.inspect(result.output).subtitles
        #expect(subtitles.map(\.codecName) == ["mov_text", "mov_text", "mov_text"])
        #expect(subtitles.map(\.isDefault) == [true, false, false])
    }

    @Test func matroskaCopiesSRTAndTurnsMovTextIntoWebVTT() async throws {
        let result = try await TestConversion.run(.h264MovText, sidecar: .sidecar, to: .mkvH264, subtitles: .keepTrack, in: directory)
        let subtitles = try MediaInspector.inspect(result.output).subtitles
        #expect(subtitles.map(\.codecName) == ["subrip", "webvtt"])
        #expect(subtitles.map(\.isDefault) == [true, false])
    }

    @Test(arguments: [SubtitleMode.remove, .burnIn])
    func noSubtitleTracksUnlessKept(_ mode: SubtitleMode) async throws {
        let result = try await TestConversion.run(.hevc10TwoSRT, sidecar: .sidecar, to: .mp4H264, subtitles: mode, in: directory)
        #expect(try MediaInspector.inspect(result.output).subtitles.isEmpty)
    }

    // MARK: Burning in

    struct BurnInCase: Sendable, CustomTestStringConvertible {
        let name: String
        let fixture: Fixture
        let sidecar: Fixture?
        let format: OutputFormat
        var testDescription: String { name }
    }

    @Test("Burns in the right subtitles at the right time", arguments: [
        BurnInCase(name: "embedded mov_text", fixture: .h264MovText, sidecar: nil, format: .mp4H264),
        // The non-default track would show at 1.5 s instead.
        BurnInCase(name: "default SRT track", fixture: .hevc10TwoSRT, sidecar: nil, format: .mp4HEVC),
        // The source starts at 1.4 s; the sidecar must still line up with the picture.
        BurnInCase(name: "sidecar with start offset", fixture: .transportStream, sidecar: .sidecar, format: .movH264),
    ])
    func burnsIn(_ burnIn: BurnInCase) async throws {
        let result = try await TestConversion.run(burnIn.fixture, sidecar: burnIn.sidecar, to: burnIn.format, subtitles: .burnIn, in: directory)
        #expect(try MediaInspector.brightPixelFraction(in: result.output, at: 0.6) > 0.002)
        #expect(try MediaInspector.brightPixelFraction(in: result.output, at: 1.5) < 0.0005)
    }

    @Test(arguments: [SubtitleMode.keepTrack, .remove])
    func otherModesLeaveThePictureClean(_ mode: SubtitleMode) async throws {
        let result = try await TestConversion.run(.h264MovText, to: .mp4HEVC, subtitles: mode, in: directory)
        #expect(try MediaInspector.brightPixelFraction(in: result.output, at: 0.6) < 0.0005)
    }

    @Test func burningInForcesAReencode() async throws {
        let result = try await TestConversion.run(.h264MovText, to: .mp4H264, subtitles: .burnIn, in: directory)
        #expect(try MediaInspector.videoPayloadSize(of: result.output) != MediaInspector.videoPayloadSize(of: Fixture.h264MovText.url))
    }
}
