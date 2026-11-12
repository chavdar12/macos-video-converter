//
//  Transcoder.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat

/// Converts one file with the FFmpeg libraries: demuxes the source, hands each stream's packets
/// to a handler that copies or re-encodes them, and muxes the results into the output file.
/// All work is blocking, so `run()` belongs on a dedicated thread.
nonisolated final class Transcoder {
    private let source: URL
    private let sidecar: URL?
    private let outputURL: URL
    private let format: OutputFormat
    private let subtitleMode: SubtitleMode
    private let cancellation: CancellationFlag
    private let reportProgress: (Double) -> Void

    private let input: UnsafeMutablePointer<AVFormatContext>
    private var sidecarInput: UnsafeMutablePointer<AVFormatContext>?
    /// Keyed by input stream index; streams without a handler are dropped.
    private var handlers: [Int: PacketHandler] = [:]
    private var sidecarHandler: PacketHandler?

    init(
        source: URL,
        sidecar: URL?,
        output: URL,
        format: OutputFormat,
        subtitleMode: SubtitleMode,
        cancellation: CancellationFlag,
        reportProgress: @escaping (Double) -> Void
    ) throws {
        self.source = source
        self.sidecar = sidecar
        self.outputURL = output
        self.format = format
        self.subtitleMode = subtitleMode
        self.cancellation = cancellation
        self.reportProgress = reportProgress
        input = try FFmpeg.openInput(source)
    }

    deinit {
        // Handlers point into the input streams, so they go first.
        handlers = [:]
        sidecarHandler = nil
        FFmpeg.closeInput(sidecarInput)
        FFmpeg.closeInput(input)
    }

    func run() throws {
        let info = MediaInfo(context: input)
        let hasVideo = info.hasVideo && !format.isAudioOnly
        guard hasVideo || info.hasAudio else { throw ConversionError.noMediaTracks }
        let sidecar = hasVideo && subtitleMode != .remove ? sidecar : nil

        let startTime = input.pointee.start_time
        let muxer = try Muxer(
            url: outputURL,
            format: format,
            startOffset: startTime == FFmpeg.noTimestamp ? 0 : startTime,
            duration: info.duration,
            reportProgress: reportProgress
        )

        if hasVideo, let video = info.video {
            try addVideo(video, info: info, sidecar: sidecar, muxer: muxer)
        }
        try addAudio(info: info, muxer: muxer)
        if hasVideo && subtitleMode == .keepTrack {
            try addSubtitleTracks(info: info, sidecar: sidecar, muxer: muxer)
        }
        try muxer.start()

        let packet = try FFmpeg.makePacket()
        defer { FFmpeg.freePacket(packet) }

        // A sidecar file holds only a few small subtitle packets, so it's read up front
        // and the muxer interleaves them with the rest.
        if let sidecarInput, let sidecarHandler {
            while av_read_frame(sidecarInput, packet) >= 0 {
                defer { av_packet_unref(packet) }
                try sidecarHandler.handle(packet)
            }
            try sidecarHandler.finish()
        }

        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let result = av_read_frame(input, packet)
            if result == FFmpeg.endOfFile { break }
            try FFmpeg.check(result, "Couldn't read the file")
            defer { av_packet_unref(packet) }
            try handlers[Int(packet.pointee.stream_index)]?.handle(packet)
        }
        for handler in handlers.values {
            try handler.finish()
        }
        try muxer.finish()
    }

    // MARK: - Planning

    private func addVideo(_ video: MediaInfo.Stream, info: MediaInfo, sidecar: URL?, muxer: Muxer) throws {
        let stream = FFmpeg.stream(input, video.index)
        let burnIn = burnInPlan(info: info, sidecar: sidecar)
        // Fastest path: the source is already in the target codec and nothing is drawn on it.
        if case .off = burnIn, video.codecName == format.videoCodec {
            let copier = try StreamCopier(stream: stream, muxer: muxer, codecTag: format.usesHVC1Tag ? FFmpeg.hvc1Tag : 0)
            handlers[video.index] = copier
            muxer.progressStream = copier.output.pointee.index
            return
        }
        let transcoder = try VideoTranscoder(input: input, stream: stream, muxer: muxer, format: format, burnIn: burnIn)
        handlers[video.index] = transcoder
        muxer.progressStream = transcoder.output.pointee.index
        if case .bitmap(let index) = burnIn {
            handlers[index] = try BitmapSubtitleReader(stream: FFmpeg.stream(input, index), video: transcoder)
        }
    }

    /// Draws the sidecar file, or the default (else first) embedded subtitle stream, into the picture.
    private func burnInPlan(info: MediaInfo, sidecar: URL?) -> VideoTranscoder.BurnIn {
        guard subtitleMode == .burnIn else { return .off }
        if let sidecar {
            return .text(file: sidecar, streamIndex: nil, startsAtZero: true)
        }
        let subtitles = info.subtitleStreams
        guard let position = subtitles.firstIndex(where: \.isDefault) ?? subtitles.indices.first else { return .off }
        if subtitles[position].isTextSubtitle {
            return .text(file: source, streamIndex: position, startsAtZero: false)
        }
        // Bitmap subtitles are full-frame images, so they're simply laid over the video.
        return .bitmap(streamIndex: subtitles[position].index)
    }

    private func addAudio(info: MediaInfo, muxer: Muxer) throws {
        let copiesAudio = info.audioStreams.allSatisfy { format.canCopyAudio($0.codecName) }
        for audio in info.audioStreams {
            let stream = FFmpeg.stream(input, audio.index)
            let handler: OutputHandler = copiesAudio
                ? try StreamCopier(stream: stream, muxer: muxer)
                : try AudioTranscoder(stream: stream, muxer: muxer, format: format)
            handlers[audio.index] = handler
            if muxer.progressStream < 0 { muxer.progressStream = handler.output.pointee.index }
        }
    }

    /// Maps subtitle streams as soft tracks; the sidecar file goes first so it's the default.
    /// MP4-family containers only hold text subtitles (as `mov_text`), so bitmap ones are dropped there.
    private func addSubtitleTracks(info: MediaInfo, sidecar: URL?, muxer: Muxer) throws {
        var outputs: [UnsafeMutablePointer<AVStream>] = []
        if let sidecar {
            let unreadable = ConversionError.ffmpegFailed("The subtitle file \(sidecar.lastPathComponent) couldn't be read.")
            guard let sidecarInput = try? FFmpeg.openInput(sidecar) else { throw unreadable }
            self.sidecarInput = sidecarInput
            // Every packet in the file goes to this one handler, so it must hold a single subtitle stream.
            guard sidecarInput.pointee.nb_streams == 1, MediaInfo(context: sidecarInput).streams.first?.kind == .subtitle else {
                throw unreadable
            }
            let stream = FFmpeg.stream(sidecarInput, 0)
            let handler: OutputHandler = format.isMatroska
                ? try StreamCopier(stream: stream, muxer: muxer, startsAtZero: true)
                : try SubtitleTranscoder(stream: stream, muxer: muxer, encoder: "mov_text", startsAtZero: true)
            sidecarHandler = handler
            outputs.append(handler.output)
        }
        for subtitle in info.subtitleStreams where format.isMatroska || subtitle.isTextSubtitle {
            let stream = FFmpeg.stream(input, subtitle.index)
            let isMovText = subtitle.codecName == "mov_text"
            let handler: OutputHandler
            if format.isMatroska {
                // Matroska can't hold mov_text, and this FFmpeg build has no SRT encoder, so it becomes WebVTT.
                handler = isMovText
                    ? try SubtitleTranscoder(stream: stream, muxer: muxer, encoder: "webvtt")
                    : try StreamCopier(stream: stream, muxer: muxer)
            } else {
                handler = isMovText
                    ? try StreamCopier(stream: stream, muxer: muxer)
                    : try SubtitleTranscoder(stream: stream, muxer: muxer, encoder: "mov_text")
            }
            handlers[subtitle.index] = handler
            outputs.append(handler.output)
        }
        // Clear any inherited default flags, then enable only the first track.
        for (i, output) in outputs.enumerated() {
            output.pointee.disposition = i == 0 ? AV_DISPOSITION_DEFAULT : 0
        }
    }
}
