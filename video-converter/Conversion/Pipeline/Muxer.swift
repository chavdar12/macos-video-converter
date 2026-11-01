//
//  Muxer.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Writes packets to the output file. The header can only be written once every stream's
/// parameters are known, and the video encoder opens on the first decoded frame, so packets
/// that arrive earlier wait in a queue.
nonisolated final class Muxer {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let url: URL
    private let usesFastStart: Bool
    /// The source's start time in microseconds. It's subtracted so the output starts at zero, like ffmpeg does.
    private let startOffset: Int64
    private var uninitializedStreams = 0
    private var started = false
    private var headerWritten = false
    private var queue: [(packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational, stream: Int32, startsAtZero: Bool)] = []

    /// The output stream whose timestamps drive progress.
    var progressStream: Int32 = -1
    private let duration: Double
    private let reportProgress: (Double) -> Void
    private var reportedProgress = 0.0

    init(url: URL, format: OutputFormat, startOffset: Int64, duration: Double, reportProgress: @escaping (Double) -> Void) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        try FFmpeg.check(avformat_alloc_output_context2(&context, nil, format.muxerName, url.path), "Couldn't create the output")
        guard let context else { throw ConversionError.ffmpegFailed("Couldn't create the output.") }
        self.context = context
        self.url = url
        self.usesFastStart = !format.isMatroska
        self.startOffset = startOffset
        self.duration = duration
        self.reportProgress = reportProgress
    }

    deinit {
        for item in queue { FFmpeg.freePacket(item.packet) }
        if context.pointee.pb != nil {
            avio_closep(&context.pointee.pb)
        }
        avformat_free_context(context)
    }

    var needsGlobalHeader: Bool {
        context.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0
    }

    /// - Parameter initializesLater: The stream's codec parameters are filled in later, and
    ///   `streamInitialized()` must be called once they are.
    func addStream(initializesLater: Bool = false) throws -> UnsafeMutablePointer<AVStream> {
        guard let stream = avformat_new_stream(context, nil) else {
            throw ConversionError.ffmpegFailed("Couldn't add a stream to the output.")
        }
        if initializesLater { uninitializedStreams += 1 }
        return stream
    }

    func streamInitialized() throws {
        uninitializedStreams -= 1
        try writeHeaderIfReady()
    }

    /// Called once all streams are added.
    func start() throws {
        started = true
        try writeHeaderIfReady()
    }

    /// Takes the packet's data; `packet` is left blank.
    /// - Parameter startsAtZero: The timestamps are already relative to the start of the output.
    func write(_ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational, stream: Int32, startsAtZero: Bool = false) throws {
        guard headerWritten else {
            let queued = try FFmpeg.makePacket()
            av_packet_move_ref(queued, packet)
            queue.append((queued, timeBase, stream, startsAtZero))
            return
        }
        try send(packet, timeBase: timeBase, stream: stream, startsAtZero: startsAtZero)
    }

    func finish() throws {
        guard headerWritten else { throw ConversionError.ffmpegFailed("No video frames could be decoded.") }
        try FFmpeg.check(av_write_trailer(context), "Couldn't finish the output file")
    }

    private func writeHeaderIfReady() throws {
        guard started, uninitializedStreams == 0, !headerWritten else { return }
        if context.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try FFmpeg.check(avio_open(&context.pointee.pb, url.path, AVIO_FLAG_WRITE), "Couldn't create the output file")
        }
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if usesFastStart { av_dict_set(&options, "movflags", "+faststart", 0) }
        try FFmpeg.check(avformat_write_header(context, &options), "Couldn't write the output file")
        headerWritten = true

        let queued = queue
        queue = []
        defer { for item in queued { FFmpeg.freePacket(item.packet) } }
        for item in queued {
            try send(item.packet, timeBase: item.timeBase, stream: item.stream, startsAtZero: item.startsAtZero)
        }
    }

    private func send(_ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational, stream: Int32, startsAtZero: Bool) throws {
        if !startsAtZero && startOffset != 0 {
            let shift = av_rescale_q(startOffset, FFmpeg.microseconds, timeBase)
            if packet.pointee.pts != FFmpeg.noTimestamp { packet.pointee.pts -= shift }
            if packet.pointee.dts != FFmpeg.noTimestamp { packet.pointee.dts -= shift }
        }
        let outputTimeBase = FFmpeg.stream(context, Int(stream)).pointee.time_base
        av_packet_rescale_ts(packet, timeBase, outputTimeBase)
        packet.pointee.stream_index = stream
        packet.pointee.pos = -1

        if stream == progressStream, duration > 0, packet.pointee.pts != FFmpeg.noTimestamp {
            let fraction = min(1, max(0, Double(packet.pointee.pts) * av_q2d(outputTimeBase) / duration))
            if fraction - reportedProgress >= 0.002 {
                reportedProgress = fraction
                reportProgress(fraction)
            }
        }
        try FFmpeg.check(av_interleaved_write_frame(context, packet), "Couldn't write to the output file")
    }
}
