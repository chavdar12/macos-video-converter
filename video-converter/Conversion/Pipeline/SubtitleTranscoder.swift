//
//  SubtitleTranscoder.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Converts text subtitles to another text format (`mov_text` for MP4, `webvtt` for MKV).
nonisolated final class SubtitleTranscoder: OutputHandler {
    let output: UnsafeMutablePointer<AVStream>
    private let muxer: Muxer
    private let startsAtZero: Bool
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let encoder: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    /// ffmpeg's limit for one encoded subtitle.
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)

    init(stream: UnsafeMutablePointer<AVStream>, muxer: Muxer, encoder encoderName: String, startsAtZero: Bool = false) throws {
        self.muxer = muxer
        self.startsAtZero = startsAtZero
        packet = try FFmpeg.makePacket()
        decoder = try FFmpeg.openDecoder(for: stream)
        let codec = try FFmpeg.findEncoder(encoderName)
        guard let encoder = avcodec_alloc_context3(codec) else { throw ConversionError.ffmpegFailed("Out of memory.") }
        self.encoder = encoder
        output = try muxer.addStream()

        encoder.pointee.time_base = FFmpeg.microseconds
        // Text decoders turn subtitles into ASS; the encoder needs the same ASS header.
        let headerSize = Int(decoder.pointee.subtitle_header_size)
        if headerSize > 0, let header = decoder.pointee.subtitle_header, let copy = av_mallocz(headerSize + 1) {
            copy.copyMemory(from: header, byteCount: headerSize)
            encoder.pointee.subtitle_header = copy.assumingMemoryBound(to: UInt8.self)
            encoder.pointee.subtitle_header_size = Int32(headerSize)
        }
        try FFmpeg.check(avcodec_open2(encoder, codec, nil), "Couldn't start the \(encoderName) encoder")
        try FFmpeg.check(avcodec_parameters_from_context(output.pointee.codecpar, encoder), "Couldn't set up a subtitle stream")
        output.pointee.time_base = AVRational(num: 1, den: 1000)
    }

    deinit {
        FFmpeg.freeCodec(decoder)
        var encoder: UnsafeMutablePointer<AVCodecContext>? = encoder
        avcodec_free_context(&encoder)
        FFmpeg.freePacket(packet)
    }

    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(decoder, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else { return }
        defer { avsubtitle_free(&subtitle) }
        guard subtitle.pts != FFmpeg.noTimestamp, subtitle.num_rects > 0 else { return }

        // Like ffmpeg: fold the display offset into the timestamp so the subtitle starts at its packet time.
        subtitle.pts += Int64(subtitle.start_display_time) * 1000
        subtitle.end_display_time -= min(subtitle.start_display_time, subtitle.end_display_time)
        subtitle.start_display_time = 0
        let size = avcodec_encode_subtitle(encoder, &buffer, Int32(buffer.count), &subtitle)
        guard size > 0 else { return }

        try FFmpeg.check(av_new_packet(self.packet, size), "Out of memory")
        buffer.withUnsafeBufferPointer { self.packet.pointee.data.update(from: $0.baseAddress!, count: Int(size)) }
        self.packet.pointee.pts = subtitle.pts
        self.packet.pointee.dts = subtitle.pts
        self.packet.pointee.duration = Int64(subtitle.end_display_time) * 1000
        try muxer.write(self.packet, timeBase: FFmpeg.microseconds, stream: output.pointee.index, startsAtZero: startsAtZero)
    }

    func finish() throws {}
}
