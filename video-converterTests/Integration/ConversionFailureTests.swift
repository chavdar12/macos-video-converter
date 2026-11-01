//
//  ConversionFailureTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

@Suite("Conversion failures and cancelling")
struct ConversionFailureTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    @Test func fileThatIsNotMediaIsUnreadable() async throws {
        let error = await #expect(throws: ConversionError.self) {
            try await TestConversion.run(.notMedia, to: .mp4H264, in: directory)
        }
        guard case .unreadable? = error else { Issue.record("Got \(String(describing: error))"); return }
    }

    @Test func fileWithoutVideoOrAudioIsRejected() async throws {
        let error = await #expect(throws: ConversionError.self) {
            try await TestConversion.run(.sidecar, to: .mp4H264, in: directory)
        }
        guard case .noMediaTracks? = error else { Issue.record("Got \(String(describing: error))"); return }
    }

    @Test func errorsHaveReadableDescriptions() {
        #expect(ConversionError.unreadable.errorDescription == "The file couldn't be read.")
        #expect(ConversionError.noMediaTracks.errorDescription?.isEmpty == false)
        #expect(ConversionError.ffmpegFailed("Boom").errorDescription == "Boom")
    }

    @Test func cancellingStopsTheConversion() async throws {
        let output = directory.file("cancelled.mp4")
        let source = try Fixture.hevc10TwoSRT.url
        let task = Task {
            // Cancel before converting so the outcome doesn't depend on timing.
            withUnsafeCurrentTask { $0?.cancel() }
            try await VideoConverter.convert(source: source, subtitleFile: nil, to: output, format: .mp4H264, subtitleMode: .burnIn) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
