//
//  FFmpeg.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavfilter
import Libavformat
import Libavutil

/// Small helpers over the FFmpeg C libraries.
nonisolated enum FFmpeg {
    static let noTimestamp = Int64.min
    static let microseconds = AVRational(num: 1, den: AV_TIME_BASE)
    /// `AVERROR_EOF`, which is a macro Swift can't import.
    static let endOfFile: Int32 = -Int32(bitPattern: 0x45 | 0x4F << 8 | 0x46 << 16 | 0x20 << 24)
    /// `AVERROR(EAGAIN)`: the codec or filter needs more input before it can output anything.
    static let needsMoreInput = -EAGAIN
    /// `MKTAG('h','v','c','1')`, so QuickTime and Apple devices will play HEVC.
    static let hvc1Tag = UInt32(0x68) | UInt32(0x76) << 8 | UInt32(0x63) << 16 | UInt32(0x31) << 24
    /// `FF_QP2LAMBDA`: converts a `-q:v` style quality to `global_quality`.
    static let qualityScale: Int32 = 118

    /// Throws a readable error when an FFmpeg call returns a negative error code.
    static func check(_ code: Int32, _ action: @autoclosure () -> String) throws {
        guard code < 0 else { return }
        throw ConversionError.ffmpegFailed("\(action()) (\(errorDescription(code))).")
    }

    static func errorDescription(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return string(buffer)
    }

    static func string(_ buffer: [CChar]) -> String {
        String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    static func string(_ cString: UnsafePointer<CChar>?) -> String {
        cString.map { String(cString: $0) } ?? ""
    }

    // MARK: - Inputs

    static func openInput(_ url: URL) throws -> UnsafeMutablePointer<AVFormatContext> {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, url.path, nil, nil) >= 0, let context else {
            throw ConversionError.unreadable
        }
        guard avformat_find_stream_info(context, nil) >= 0 else {
            closeInput(context)
            throw ConversionError.unreadable
        }
        return context
    }

    static func closeInput(_ context: UnsafeMutablePointer<AVFormatContext>?) {
        var context = context
        avformat_close_input(&context)
    }

    static func stream(
        _ context: UnsafeMutablePointer<AVFormatContext>,
        _ index: Int
    ) -> UnsafeMutablePointer<AVStream> {
        context.pointee.streams[index]!
    }

    // MARK: - Codecs and frames

    static func openDecoder(
        for stream: UnsafeMutablePointer<AVStream>,
        configure: (UnsafeMutablePointer<AVCodecContext>) -> Void = { _ in }
    ) throws -> UnsafeMutablePointer<AVCodecContext> {
        let parameters = stream.pointee.codecpar!
        let name = string(avcodec_get_name(parameters.pointee.codec_id))
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { throw ConversionError.ffmpegFailed("There's no decoder for \(name).") }
        do {
            try check(avcodec_parameters_to_context(context, parameters), "Couldn't set up the \(name) decoder")
            context.pointee.pkt_timebase = stream.pointee.time_base
            configure(context)
            try check(avcodec_open2(context, codec, nil), "Couldn't open the \(name) decoder")
        } catch {
            freeCodec(context)
            throw error
        }
        return context
    }

    static func findEncoder(_ name: String) throws -> UnsafePointer<AVCodec> {
        guard let codec = avcodec_find_encoder_by_name(name) else {
            throw ConversionError.ffmpegFailed("The \(name) encoder isn't available.")
        }
        return codec
    }

    static func freeCodec(_ context: UnsafeMutablePointer<AVCodecContext>?) {
        var context = context
        avcodec_free_context(&context)
    }

    /// The values `codec` supports for `config`, or nil if it accepts anything.
    static func supported<T>(_ codec: UnsafePointer<AVCodec>, _ config: AVCodecConfig, as type: T.Type) -> [T]? {
        var values: UnsafeRawPointer?
        var count: Int32 = 0
        guard avcodec_get_supported_config(nil, codec, config, 0, &values, &count) >= 0, let values else { return nil }
        return Array(UnsafeBufferPointer(start: values.assumingMemoryBound(to: T.self), count: Int(count)))
    }

    static func makeFrame() throws -> UnsafeMutablePointer<AVFrame> {
        guard let frame = av_frame_alloc() else { throw ConversionError.ffmpegFailed("Out of memory.") }
        return frame
    }

    static func freeFrame(_ frame: UnsafeMutablePointer<AVFrame>?) {
        var frame = frame
        av_frame_free(&frame)
    }

    static func makePacket() throws -> UnsafeMutablePointer<AVPacket> {
        guard let packet = av_packet_alloc() else { throw ConversionError.ffmpegFailed("Out of memory.") }
        return packet
    }

    static func freePacket(_ packet: UnsafeMutablePointer<AVPacket>?) {
        var packet = packet
        av_packet_free(&packet)
    }

    static func describe(_ layout: UnsafePointer<AVChannelLayout>) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_channel_layout_describe(layout, &buffer, buffer.count)
        return string(buffer)
    }

    // MARK: - Filters

    /// Adds a filter to `graph`. Options are set one by one rather than parsed from a
    /// filtergraph string, so values such as file paths need no escaping.
    static func addFilter(
        _ name: String,
        to graph: UnsafeMutablePointer<AVFilterGraph>,
        options: [(String, String)] = []
    ) throws -> UnsafeMutablePointer<AVFilterContext> {
        guard let filter = avfilter_get_by_name(name),
              let context = avfilter_graph_alloc_filter(graph, filter, "\(name)\(graph.pointee.nb_filters)")
        else { throw ConversionError.ffmpegFailed("The \(name) filter isn't available.") }
        for (key, value) in options {
            try check(
                av_opt_set(context, key, value, AV_OPT_SEARCH_CHILDREN),
                "Couldn't set the \(name) filter's \(key)"
            )
        }
        try check(avfilter_init_str(context, nil), "Couldn't set up the \(name) filter")
        return context
    }

    /// Adds a `buffer` (video) or `abuffer` (audio) source that frames are pushed into.
    static func addSource(
        audio: Bool = false,
        to graph: UnsafeMutablePointer<AVFilterGraph>,
        configure: (UnsafeMutablePointer<AVBufferSrcParameters>) -> Void
    ) throws -> UnsafeMutablePointer<AVFilterContext> {
        let name = audio ? "abuffer" : "buffer"
        guard let filter = avfilter_get_by_name(name),
              let context = avfilter_graph_alloc_filter(graph, filter, "\(name)\(graph.pointee.nb_filters)"),
              let parameters = av_buffersrc_parameters_alloc()
        else { throw ConversionError.ffmpegFailed("The \(name) filter isn't available.") }
        defer {
            av_channel_layout_uninit(&parameters.pointee.ch_layout)
            av_free(parameters)
        }
        configure(parameters)
        try check(av_buffersrc_parameters_set(context, parameters), "Couldn't set up the \(name) filter")
        try check(avfilter_init_str(context, nil), "Couldn't set up the \(name) filter")
        return context
    }

    static func link(
        _ source: UnsafeMutablePointer<AVFilterContext>,
        to destination: UnsafeMutablePointer<AVFilterContext>,
        pad: UInt32 = 0
    ) throws {
        try check(avfilter_link(source, 0, destination, pad), "Couldn't connect the filters")
    }

    static func freeGraph(_ graph: UnsafeMutablePointer<AVFilterGraph>?) {
        var graph = graph
        avfilter_graph_free(&graph)
    }
}
