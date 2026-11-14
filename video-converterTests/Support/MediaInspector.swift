//
//  MediaInspector.swift
//  video-converterTests
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil
@testable import video_converter

/// Reads back what a conversion produced, using the same FFmpeg libraries as the app.
enum MediaInspector {
    struct Stream {
        let kind: MediaInfo.StreamKind
        let codecName: String
        /// The container's four-character code, e.g. `avc1` or `hvc1`; empty if none.
        let codecTag: String
        let profile: String
        let isDefault: Bool
        let pixelFormat: String
        let sampleRate: Int32
        let channels: Int32
    }

    struct Report {
        let streams: [Stream]
        /// In seconds.
        let startTime: Double
        let duration: Double

        var video: Stream? { streams.first { $0.kind == .video } }
        var audio: [Stream] { streams.filter { $0.kind == .audio } }
        var subtitles: [Stream] { streams.filter { $0.kind == .subtitle } }
    }

    enum InspectionError: Error {
        case noVideo
        case noFrame(at: Double)
        case unsupportedPixelFormat(String)
    }

    static func inspect(_ url: URL) throws -> Report {
        let input = try FFmpeg.openInput(url)
        defer { FFmpeg.closeInput(input) }
        let info = MediaInfo(context: input)
        let streams = info.streams.map { stream in
            let parameters = FFmpeg.stream(input, stream.index).pointee.codecpar.pointee
            return Stream(
                kind: stream.kind,
                codecName: stream.codecName,
                codecTag: fourCharacterCode(parameters.codec_tag),
                profile: FFmpeg.string(avcodec_profile_name(parameters.codec_id, parameters.profile)),
                isDefault: stream.isDefault,
                pixelFormat: stream.kind == .video
                    ? FFmpeg.string(av_get_pix_fmt_name(AVPixelFormat(rawValue: parameters.format)))
                    : "",
                sampleRate: parameters.sample_rate,
                channels: parameters.ch_layout.nb_channels
            )
        }
        let start = input.pointee.start_time
        return Report(
            streams: streams,
            startTime: start == FFmpeg.noTimestamp ? 0 : Double(start) / Double(AV_TIME_BASE),
            duration: info.duration
        )
    }

    /// Total bytes of the main video stream. It's the same in source and output when the video was copied.
    static func videoPayloadSize(of url: URL) throws -> Int {
        let input = try FFmpeg.openInput(url)
        defer { FFmpeg.closeInput(input) }
        guard let video = MediaInfo(context: input).video else { throw InspectionError.noVideo }
        let packet = try FFmpeg.makePacket()
        defer { FFmpeg.freePacket(packet) }
        var total = 0
        while av_read_frame(input, packet) >= 0 {
            if packet.pointee.stream_index == Int32(video.index) { total += Int(packet.pointee.size) }
            av_packet_unref(packet)
        }
        return total
    }

    /// The share of bright pixels in the bottom half of the first frame at or after `seconds`.
    /// The fixtures are flat and dark, so anything bright there is burned-in subtitle text.
    static func brightPixelFraction(in url: URL, at seconds: Double) throws -> Double {
        try measureFrame(in: url, at: seconds, brightFraction)
    }

    /// How much more neighbouring rows differ than rows two apart, in the first frame at or after `seconds`.
    /// Interlaced motion shows as combing, where neighbouring rows (different fields) differ most,
    /// so this is well above 1; in a progressive picture it's about 1 or less. 8-bit only.
    static func combing(in url: URL, at seconds: Double) throws -> Double {
        try measureFrame(in: url, at: seconds) { frame in
            guard let luma = frame.pointee.data.0,
                  av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format))?.pointee.comp.0.depth == 8
            else {
                let name = FFmpeg.string(av_get_pix_fmt_name(AVPixelFormat(rawValue: frame.pointee.format)))
                throw InspectionError.unsupportedPixelFormat(name)
            }
            let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
            let stride = Int(frame.pointee.linesize.0)
            var adjacent = 0, sameField = 0
            for y in 0 ..< height - 2 {
                for x in 0 ..< width {
                    let row = Int(luma[y * stride + x])
                    adjacent += abs(row - Int(luma[(y + 1) * stride + x]))
                    sameField += abs(row - Int(luma[(y + 2) * stride + x]))
                }
            }
            return Double(adjacent) / Double(max(sameField, 1))
        }
    }

    private static func measureFrame(
        in url: URL,
        at seconds: Double,
        _ measure: (UnsafeMutablePointer<AVFrame>) throws -> Double
    ) throws -> Double {
        let input = try FFmpeg.openInput(url)
        defer { FFmpeg.closeInput(input) }
        guard let video = MediaInfo(context: input).video else { throw InspectionError.noVideo }
        let stream = FFmpeg.stream(input, video.index)
        let decoder = try FFmpeg.openDecoder(for: stream)
        defer { FFmpeg.freeCodec(decoder) }
        let packet = try FFmpeg.makePacket()
        defer { FFmpeg.freePacket(packet) }
        let frame = try FFmpeg.makeFrame()
        defer { FFmpeg.freeFrame(frame) }
        let timeBase = av_q2d(stream.pointee.time_base)

        func measureFirstFrameAtTarget() throws -> Double? {
            while avcodec_receive_frame(decoder, frame) >= 0 {
                defer { av_frame_unref(frame) }
                if Double(frame.pointee.best_effort_timestamp) * timeBase + 0.001 >= seconds {
                    return try measure(frame)
                }
            }
            return nil
        }

        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(video.index) else { continue }
            _ = avcodec_send_packet(decoder, packet)
            if let fraction = try measureFirstFrameAtTarget() { return fraction }
        }
        _ = avcodec_send_packet(decoder, nil)
        if let fraction = try measureFirstFrameAtTarget() { return fraction }
        throw InspectionError.noFrame(at: seconds)
    }

    /// Works on 8-bit and high-bit-depth (e.g. 10-bit HEVC) planar YUV.
    private static func brightFraction(_ frame: UnsafeMutablePointer<AVFrame>) throws -> Double {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        guard let descriptor = av_pix_fmt_desc_get(format), let luma = frame.pointee.data.0 else {
            throw InspectionError.unsupportedPixelFormat(FFmpeg.string(av_get_pix_fmt_name(format)))
        }
        let depth = Int(descriptor.pointee.comp.0.depth)
        guard (8...16).contains(depth) else {
            throw InspectionError.unsupportedPixelFormat(FFmpeg.string(av_get_pix_fmt_name(format)))
        }
        let threshold = 180 << (depth - 8)
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let stride = Int(frame.pointee.linesize.0)
        let raw = UnsafeRawPointer(luma)
        var bright = 0
        for y in height / 2 ..< height {
            for x in 0 ..< width {
                let value = depth == 8
                    ? Int(luma[y * stride + x])
                    : Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: y * stride + x * 2, as: UInt16.self)))
                if value > threshold { bright += 1 }
            }
        }
        return Double(bright) / Double(width * (height - height / 2))
    }

    private static func fourCharacterCode(_ tag: UInt32) -> String {
        guard tag != 0 else { return "" }
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: tag >> ($0 * 8)) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
