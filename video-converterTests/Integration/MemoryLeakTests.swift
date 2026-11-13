//
//  MemoryLeakTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

/// Each pipeline object frees its FFmpeg memory in `deinit`, so a missed free or a retain cycle
/// shows up as malloc'd bytes that pile up with every conversion.
@Suite("Memory leaks", .serialized)
struct MemoryLeakTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let fixture: Fixture
        var sidecar: Fixture?
        let format: OutputFormat
        var subtitles: SubtitleMode = .remove
        var cancelsMidway = false
        var testDescription: String { name }
    }

    static let cases = [
        Case(name: "stream copy", fixture: .h264MovText, format: .mp4H264),
        Case(name: "hardware re-encode", fixture: .h264MovText, format: .mp4HEVC),
        Case(name: "software decode and audio re-encode", fixture: .vp8Opus51, format: .mp4H264),
        Case(name: "burn-in", fixture: .hevc10TwoSRT, format: .mp4H264, subtitles: .burnIn),
        Case(name: "deinterlace", fixture: .interlaced, format: .mp4HEVC),
        Case(name: "subtitle tracks", fixture: .hevc10TwoSRT, sidecar: .sidecar, format: .mkvH264, subtitles: .keepTrack),
        Case(name: "failure after setup", fixture: .h264MovText, sidecar: .notMedia, format: .mkvH264, subtitles: .keepTrack),
        Case(name: "cancelled midway", fixture: .interlaced, format: .mp4HEVC, cancelsMidway: true),
    ]

    @Test(arguments: cases)
    func repeatedConversionsDoNotLeak(_ test: Case) async throws {
        let source = try test.fixture.url
        let sidecar = try test.sidecar?.url
        let output = directory.file("leak.\(test.format.fileExtension)")
        // Calls the converter directly: test helpers that record progress add noise of their own.
        func convertOnce() async {
            let conversion = Task {
                try await VideoConverter.convert(source: source, subtitleFile: sidecar, to: output, format: test.format, subtitleMode: test.subtitles) { _ in }
            }
            if test.cancelsMidway {
                try? await Task.sleep(for: .milliseconds(30))
                conversion.cancel()
            }
            _ = try? await conversion.value
        }

        // Warms up one-time caches: codec tables, VideoToolbox, libass fonts.
        for _ in 0..<5 { await convertOnce() }
        let before = MemoryUsage.liveMallocBytes
        let runs = 20
        var series: [Int] = []
        for _ in 0..<runs { await convertOnce(); series.append((MemoryUsage.liveMallocBytes - before) / 1024) }
        // Progress updates queued on the main actor hold memory until they run.
        await MainActor.run {}
        let growthPerRun = (MemoryUsage.liveMallocBytes - before) / runs
        // VideoToolbox caches up to a few hundred KB when handed hardware frames, growing up to ~14 KB a run
        // before it purges. Leaking any codec, filter graph or frame of a conversion costs far more.
        #expect(growthPerRun < 32 * 1024, "Live memory grew \(growthPerRun) bytes per conversion; KB since warm-up: \(series)")
    }
}
