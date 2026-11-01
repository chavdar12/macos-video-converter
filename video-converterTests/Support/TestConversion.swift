//
//  TestConversion.swift
//  video-converterTests
//

import Foundation
@testable import video_converter

/// Collects the progress values a conversion reports.
@MainActor
final class ProgressRecorder {
    var values: [Double] = []
}

/// Runs `VideoConverter.convert` on a fixture.
struct TestConversion {
    let output: URL
    let progress: [Double]

    static func run(
        _ fixture: Fixture,
        sidecar: Fixture? = nil,
        to format: OutputFormat,
        subtitles: SubtitleMode = .remove,
        in directory: TemporaryDirectory,
        name: String? = nil
    ) async throws -> TestConversion {
        let baseName = name ?? "\(fixture.rawValue)-\(format.rawValue)-\(subtitles.rawValue)"
        let output = directory.file("\(baseName).\(format.fileExtension)")
        let recorder = await ProgressRecorder()
        try await VideoConverter.convert(
            source: try fixture.url,
            subtitleFile: try sidecar?.url,
            to: output,
            format: format,
            subtitleMode: subtitles
        ) { recorder.values.append($0) }
        return TestConversion(output: output, progress: await recorder.values)
    }
}
