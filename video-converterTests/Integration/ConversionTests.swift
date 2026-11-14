//
//  ConversionTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

@Suite("Converting video and audio")
struct ConversionTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    @Test func copiesStreamsAlreadyInTheTargetCodec() async throws {
        let result = try await TestConversion.run(.h264MovText, to: .mp4H264, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video?.codecName == "h264")
        #expect(report.video?.codecTag == "avc1")
        #expect(report.audio.map(\.codecName) == ["aac"])
        #expect(abs(report.duration - 2) < 0.1)
        // A copied stream is byte-for-byte the same.
        #expect(
            try MediaInspector.videoPayloadSize(of: result.output)
                == MediaInspector.videoPayloadSize(of: Fixture.h264MovText.url)
        )
    }

    @Test func reencodesToHEVCWithTheAppleTag() async throws {
        let result = try await TestConversion.run(.h264MovText, to: .mp4HEVC, in: directory)
        let video = try #require(try MediaInspector.inspect(result.output).video)
        #expect(video.codecName == "hevc")
        #expect(video.codecTag == "hvc1")
    }

    @Test func tenBitHEVCBecomesEightBitH264() async throws {
        let result = try await TestConversion.run(.hevc10TwoSRT, to: .mp4H264, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video?.codecName == "h264")
        #expect(report.video?.pixelFormat == "yuv420p")
        // AC-3 fits in MP4, so it's copied with all six channels.
        #expect(report.audio.map(\.codecName) == ["ac3"])
        #expect(report.audio.first?.channels == 6)
    }

    @Test(.enabled(if: ProResEncoder.isAvailable, "needs a VideoToolbox ProRes encoder"))
    func proResUsesTheStandardProfileAndPCMAudio() async throws {
        let result = try await TestConversion.run(.vp8Opus51, to: .movProRes, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video?.codecName == "prores")
        #expect(report.video?.codecTag == "apcn")
        #expect(report.audio.first?.codecName == "pcm_s16le")
        #expect(report.audio.first?.channels == 6)
    }

    @Test func softwareDecodedVideoIsReencoded() async throws {
        let result = try await TestConversion.run(.vp8Opus51, to: .m4v, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video?.codecName == "h264")
        #expect(abs(report.duration - 2) < 0.1)
    }

    /// Re-encoding without deinterlacing shows the two fields as combing wherever there's motion.
    @Test(arguments: [SubtitleMode.remove, .burnIn])
    func interlacedVideoIsDeinterlaced(_ mode: SubtitleMode) async throws {
        let source = try Fixture.interlaced.url
        #expect(try MediaInspector.combing(in: source, at: 1) > 1.5, "The fixture should show combing")
        let result = try await TestConversion.run(
            .interlaced, sidecar: .sidecar, to: .mp4HEVC, subtitles: mode, in: directory
        )
        let combing = try MediaInspector.combing(in: result.output, at: 1)
        #expect(combing < 1.1)
        #expect(abs(try MediaInspector.inspect(result.output).duration - 2) < 0.1)
    }

    struct AudioCase: Sendable, CustomTestStringConvertible {
        let fixture: Fixture
        let sampleRate: Int32
        let channels: Int32
        var testDescription: String { fixture.rawValue }
    }

    @Test("Audio that doesn't fit MP4 becomes AAC with the same layout", arguments: [
        AudioCase(fixture: .transportStream, sampleRate: 44_100, channels: 1),
        AudioCase(fixture: .vp8Opus51, sampleRate: 48_000, channels: 6)
    ])
    func audioIsReencodedToAAC(_ audio: AudioCase) async throws {
        let result = try await TestConversion.run(audio.fixture, to: .mp4H264, in: directory)
        let stream = try #require(try MediaInspector.inspect(result.output).audio.first)
        #expect(stream.codecName == "aac")
        #expect(stream.sampleRate == audio.sampleRate)
        #expect(stream.channels == audio.channels)
    }

    @Test func matroskaKeepsAudioAsIs() async throws {
        let result = try await TestConversion.run(.vp8Opus51, to: .mkvH264, in: directory)
        #expect(try MediaInspector.inspect(result.output).audio.map(\.codecName) == ["opus"])
    }

    @Test func audioOnlyFormatDropsVideoAndSubtitles() async throws {
        let result = try await TestConversion.run(.hevc10TwoSRT, to: .m4a, subtitles: .keepTrack, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video == nil)
        #expect(report.subtitles.isEmpty)
        #expect(report.audio.map(\.codecName) == ["ac3"])
    }

    @Test func audioOnlySourceMakesAnAudioOnlyFile() async throws {
        let result = try await TestConversion.run(.audioOnly, to: .mp4H264, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(report.video == nil)
        #expect(report.audio.map(\.codecName) == ["aac"])
    }

    @Test func outputStartsAtZeroEvenWhenTheSourceDoesNot() async throws {
        #expect(try MediaInspector.inspect(Fixture.transportStream.url).startTime > 1)
        let result = try await TestConversion.run(.transportStream, to: .mp4H264, in: directory)
        let report = try MediaInspector.inspect(result.output)
        #expect(abs(report.startTime) < 0.05)
        #expect(abs(report.duration - 2) < 0.1)
    }

    @Test(arguments: [Fixture.h264MovText, .vp8Opus51])
    func reportsProgressUpToOne(_ fixture: Fixture) async throws {
        let result = try await TestConversion.run(fixture, to: .mp4HEVC, in: directory)
        #expect(!result.progress.isEmpty)
        #expect(result.progress == result.progress.sorted())
        #expect(result.progress.allSatisfy { (0...1).contains($0) })
        #expect(result.progress.last == 1)
    }

    @Test func runsManyConversionsAtOnce() async throws {
        let jobs: [(Fixture, OutputFormat)] = [
            (.h264MovText, .mp4HEVC), (.hevc10TwoSRT, .mp4H264), (.transportStream, .movHEVC),
            (.vp8Opus51, .m4v), (.h264MovText, .movProRes), (.hevc10TwoSRT, .mkvH264)
        ].filter { $0.1 != .movProRes || ProResEncoder.isAvailable }
        let directory = self.directory
        let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask {
                    try await TestConversion.run(job.0, to: job.1, in: directory, name: "parallel-\(index)").output
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outputs.count == jobs.count)
        for output in outputs {
            #expect(try MediaInspector.inspect(output).video != nil, "\(output.lastPathComponent)")
        }
    }
}
