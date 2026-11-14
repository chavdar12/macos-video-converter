//
//  VideoConverter.swift
//  video-converter
//

import Foundation
import Libavutil

/// Converts a single file with the bundled FFmpeg libraries.
nonisolated enum VideoConverter {

    static let sidecarExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// Only errors reach the console; FFmpeg's warnings about odd files are noise here.
    private static let configureLogging: Void = av_log_set_level(AV_LOG_ERROR)

    // One parameter per conversion setting, hence the function_parameter_count exception.
    /// Converts `source` into `outputURL`.
    /// - Parameters:
    ///   - subtitleFile: An optional sidecar subtitle file, used instead of embedded subtitles
    ///     when burning in, or added as the first (default) track when keeping tracks.
    ///   - progress: Called on the main actor with values in `0...1`.
    static func convert( // swiftlint:disable:this function_parameter_count
        source: URL,
        subtitleFile: URL?,
        to outputURL: URL,
        format: OutputFormat,
        subtitleMode: SubtitleMode,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        configureLogging
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            // FFmpeg calls block, so each conversion gets its own thread rather than tying up the
            // shared concurrency pool, which only has one thread per core.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let thread = Thread {
                    do {
                        let transcoder = try Transcoder(
                            source: source,
                            sidecar: subtitleFile,
                            output: outputURL,
                            format: format,
                            subtitleMode: subtitleMode,
                            cancellation: cancellation
                        ) { fraction in
                            DispatchQueue.main.async { MainActor.assumeIsolated { progress(fraction) } }
                        }
                        try transcoder.run()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "Transcoder"
                thread.qualityOfService = .userInitiated
                thread.stackSize = 8 << 20
                thread.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
        await progress(1)
    }

    /// Number of subtitle streams in the file, or 0 if it can't be read.
    static func embeddedSubtitleTrackCount(in url: URL) async -> Int {
        (try? await probe(url).subtitleStreams.count) ?? 0
    }

    @concurrent
    static func probe(_ url: URL) async throws -> MediaInfo {
        configureLogging
        let input = try FFmpeg.openInput(url)
        defer { FFmpeg.closeInput(input) }
        return MediaInfo(context: input)
    }
}
