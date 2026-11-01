//
//  AudioTranscoder.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavfilter
import Libavformat
import Libavutil

/// Decodes audio, converts it to what the encoder takes, and re-encodes it.
nonisolated final class AudioTranscoder: OutputHandler {
    let output: UnsafeMutablePointer<AVStream>
    private let muxer: Muxer
    private let streamTimeBase: AVRational
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let encoderCodec: UnsafePointer<AVCodec>
    private let encoder: UnsafeMutablePointer<AVCodecContext>
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private let frame: UnsafeMutablePointer<AVFrame>
    private let filteredFrame: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>
    private var nextPts: Int64 = 0

    init(stream: UnsafeMutablePointer<AVStream>, muxer: Muxer, format: OutputFormat) throws {
        self.muxer = muxer
        streamTimeBase = stream.pointee.time_base
        encoderCodec = try FFmpeg.findEncoder(format.audioEncoderName)
        frame = try FFmpeg.makeFrame()
        filteredFrame = try FFmpeg.makeFrame()
        packet = try FFmpeg.makePacket()
        decoder = try FFmpeg.openDecoder(for: stream)
        guard let encoder = avcodec_alloc_context3(encoderCodec) else { throw ConversionError.ffmpegFailed("Out of memory.") }
        self.encoder = encoder
        output = try muxer.addStream()

        // Keep the source's rate and channels when the encoder supports them.
        let sampleFormats = FFmpeg.supported(encoderCodec, AV_CODEC_CONFIG_SAMPLE_FORMAT, as: AVSampleFormat.self)
        encoder.pointee.sample_fmt = sampleFormats?.first ?? decoder.pointee.sample_fmt
        let sourceRate = decoder.pointee.sample_rate > 0 ? decoder.pointee.sample_rate : 48000
        if let rates = FFmpeg.supported(encoderCodec, AV_CODEC_CONFIG_SAMPLE_RATE, as: Int32.self), !rates.contains(sourceRate) {
            encoder.pointee.sample_rate = rates.contains(48000) ? 48000 : rates.first ?? sourceRate
        } else {
            encoder.pointee.sample_rate = sourceRate
        }
        Self.chooseChannelLayout(for: encoder, codec: encoderCodec, source: &decoder.pointee.ch_layout)
        encoder.pointee.time_base = AVRational(num: 1, den: encoder.pointee.sample_rate)
        encoder.pointee.bit_rate = format.audioBitRate
        if muxer.needsGlobalHeader {
            encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }
        let name = FFmpeg.string(encoderCodec.pointee.name)
        try FFmpeg.check(avcodec_open2(encoder, encoderCodec, nil), "Couldn't start the \(name) encoder")
        try FFmpeg.check(avcodec_parameters_from_context(output.pointee.codecpar, encoder), "Couldn't set up an audio stream")
        output.pointee.time_base = encoder.pointee.time_base
        output.pointee.disposition = stream.pointee.disposition
    }

    deinit {
        FFmpeg.freeCodec(decoder)
        var encoder: UnsafeMutablePointer<AVCodecContext>? = encoder
        avcodec_free_context(&encoder)
        FFmpeg.freeGraph(graph)
        FFmpeg.freeFrame(frame)
        FFmpeg.freeFrame(filteredFrame)
        FFmpeg.freePacket(packet)
    }

    /// The source layout if the encoder supports it, else 5.1 or stereo (or mono) downmixes.
    private static func chooseChannelLayout(
        for encoder: UnsafeMutablePointer<AVCodecContext>,
        codec: UnsafePointer<AVCodec>,
        source: UnsafeMutablePointer<AVChannelLayout>
    ) {
        let channels = max(source.pointee.nb_channels, 1)
        var layout = AVChannelLayout()
        if source.pointee.order == AV_CHANNEL_ORDER_NATIVE {
            av_channel_layout_copy(&layout, source)
        } else {
            av_channel_layout_default(&layout, channels)
        }
        if let supported = FFmpeg.supported(codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, as: AVChannelLayout.self) {
            func isSupported(_ layout: inout AVChannelLayout) -> Bool {
                supported.contains { option in withUnsafePointer(to: option) { av_channel_layout_compare($0, &layout) == 0 } }
            }
            if !isSupported(&layout) {
                av_channel_layout_uninit(&layout)
                av_channel_layout_default(&layout, channels >= 6 ? 6 : min(channels, 2))
                if !isSupported(&layout), var first = supported.first {
                    av_channel_layout_uninit(&layout)
                    av_channel_layout_copy(&layout, &first)
                }
            }
        }
        av_channel_layout_copy(&encoder.pointee.ch_layout, &layout)
        av_channel_layout_uninit(&layout)
    }

    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        guard avcodec_send_packet(decoder, packet) >= 0 else { return }
        try receiveFrames()
    }

    func finish() throws {
        avcodec_send_packet(decoder, nil)
        try receiveFrames()
        if let source {
            _ = av_buffersrc_add_frame_flags(source, nil, 0)
            try drainFilters()
        }
        avcodec_send_frame(encoder, nil)
        try receivePackets()
    }

    private func receiveFrames() throws {
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            // Audio is filtered with a 1/sample-rate time base, like ffmpeg does.
            let timeBase = AVRational(num: 1, den: frame.pointee.sample_rate)
            let pts = frame.pointee.best_effort_timestamp
            frame.pointee.pts = pts == FFmpeg.noTimestamp ? nextPts : av_rescale_q(pts, streamTimeBase, timeBase)
            nextPts = frame.pointee.pts + Int64(frame.pointee.nb_samples)
            if graph == nil { try makeGraph(for: frame, timeBase: timeBase) }
            try FFmpeg.check(
                av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)),
                "Couldn't convert the audio"
            )
            try drainFilters()
        }
    }

    /// abuffer → aformat (resamples and remixes as needed) → abuffersink (cut to the encoder's frame size)
    private func makeGraph(for frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) throws {
        guard let graph = avfilter_graph_alloc() else { throw ConversionError.ffmpegFailed("Out of memory.") }
        self.graph = graph
        let source = try FFmpeg.addSource(audio: true, to: graph) { parameters in
            parameters.pointee.format = frame.pointee.format
            parameters.pointee.sample_rate = frame.pointee.sample_rate
            parameters.pointee.time_base = timeBase
            if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
                av_channel_layout_default(&parameters.pointee.ch_layout, frame.pointee.ch_layout.nb_channels)
            } else {
                av_channel_layout_copy(&parameters.pointee.ch_layout, &frame.pointee.ch_layout)
            }
        }
        let aformat = try FFmpeg.addFilter("aformat", to: graph, options: [
            ("sample_fmts", FFmpeg.string(av_get_sample_fmt_name(encoder.pointee.sample_fmt))),
            ("sample_rates", String(encoder.pointee.sample_rate)),
            ("channel_layouts", FFmpeg.describe(&encoder.pointee.ch_layout)),
        ])
        let sink = try FFmpeg.addFilter("abuffersink", to: graph)
        try FFmpeg.link(source, to: aformat)
        try FFmpeg.link(aformat, to: sink)
        try FFmpeg.check(avfilter_graph_config(graph, nil), "Couldn't set up the audio conversion")
        if encoder.pointee.frame_size > 0, encoderCodec.pointee.capabilities & AV_CODEC_CAP_VARIABLE_FRAME_SIZE == 0 {
            av_buffersink_set_frame_size(sink, UInt32(encoder.pointee.frame_size))
        }
        self.source = source
        self.sink = sink
    }

    private func drainFilters() throws {
        guard let sink else { return }
        while av_buffersink_get_frame(sink, filteredFrame) >= 0 {
            defer { av_frame_unref(filteredFrame) }
            filteredFrame.pointee.pts = av_rescale_q(filteredFrame.pointee.pts, av_buffersink_get_time_base(sink), encoder.pointee.time_base)
            try FFmpeg.check(avcodec_send_frame(encoder, filteredFrame), "Couldn't encode the audio")
            try receivePackets()
        }
    }

    private func receivePackets() throws {
        while avcodec_receive_packet(encoder, packet) >= 0 {
            try muxer.write(packet, timeBase: encoder.pointee.time_base, stream: output.pointee.index)
        }
    }
}
