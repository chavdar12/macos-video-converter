//
//  VideoTranscoder.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavfilter
import Libavformat
import Libavutil

/// Decodes video, optionally draws subtitles on it, and encodes it with VideoToolbox.
nonisolated final class VideoTranscoder: OutputHandler {
    enum BurnIn {
        case off
        /// Draws text subtitles with libass, from `file`'s `streamIndex`-th subtitle stream if given.
        /// - Parameter startsAtZero: The file's timestamps start at zero rather than at the source's start time.
        case text(file: URL, streamIndex: Int?, startsAtZero: Bool)
        /// Overlays the bitmap subtitles (PGS, VobSub) decoded from the given source stream.
        case bitmap(streamIndex: Int)
    }

    let output: UnsafeMutablePointer<AVStream>
    private let muxer: Muxer
    private let format: OutputFormat
    private let burnIn: BurnIn
    private let timeBase: AVRational
    private let frameRate: AVRational
    /// The source's start time in stream time base, removed before filtering when subtitles start at zero.
    private let filterShift: Int64
    /// The source's rotation, carried over so players keep showing it upright.
    private let displayMatrix: [UInt8]?
    /// Interlaced sources are deinterlaced, as the output is progressive and players
    /// would otherwise show combing wherever there's motion.
    private var deinterlace: Bool

    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let encoderCodec: UnsafePointer<AVCodec>
    private var encoder: UnsafeMutablePointer<AVCodecContext>?
    private var encodedStartsAtZero = false
    private var lastPts = Int64.min

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var subtitleSource: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?

    private let frame: UnsafeMutablePointer<AVFrame>
    private let softwareFrame: UnsafeMutablePointer<AVFrame>
    private let filteredFrame: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>

    private var pendingSubtitles: [BitmapSubtitle] = []
    private var activeSubtitle: (canvas: UnsafeMutablePointer<AVFrame>, end: Int64?)?
    private var blankCanvas: UnsafeMutablePointer<AVFrame>?
    private var canvasSize = (width: Int32(0), height: Int32(0))

    init(
        input: UnsafeMutablePointer<AVFormatContext>,
        stream: UnsafeMutablePointer<AVStream>,
        muxer: Muxer,
        format: OutputFormat,
        burnIn: BurnIn
    ) throws {
        guard let encoderName = format.videoEncoderName else { throw ConversionError.noMediaTracks }
        encoderCodec = try FFmpeg.findEncoder(encoderName)
        self.muxer = muxer
        self.format = format
        self.burnIn = burnIn
        timeBase = stream.pointee.time_base
        frameRate = av_guess_frame_rate(input, stream, nil)
        if case .text(_, _, true) = burnIn, input.pointee.start_time != FFmpeg.noTimestamp {
            filterShift = av_rescale_q(input.pointee.start_time, FFmpeg.microseconds, timeBase)
        } else {
            filterShift = 0
        }
        let parameters = stream.pointee.codecpar.pointee
        deinterlace = parameters.field_order != AV_FIELD_PROGRESSIVE && parameters.field_order != AV_FIELD_UNKNOWN
        if let matrix = av_packet_side_data_get(
            parameters.coded_side_data, parameters.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX
        ) {
            displayMatrix = Array(UnsafeBufferPointer(start: matrix.pointee.data, count: matrix.pointee.size))
        } else {
            displayMatrix = nil
        }

        frame = try FFmpeg.makeFrame()
        softwareFrame = try FFmpeg.makeFrame()
        filteredFrame = try FFmpeg.makeFrame()
        packet = try FFmpeg.makePacket()
        output = try muxer.addStream(initializesLater: true)
        decoder = try FFmpeg.openDecoder(for: stream) { context in
            // Decode on the media engine when VideoToolbox handles the codec; otherwise FFmpeg falls back to software.
            var device: UnsafeMutablePointer<AVBufferRef>?
            if av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                context.pointee.hw_device_ctx = device
                context.pointee.get_format = preferVideoToolbox
            }
        }
    }

    deinit {
        FFmpeg.freeCodec(decoder)
        FFmpeg.freeCodec(encoder)
        FFmpeg.freeGraph(graph)
        FFmpeg.freeFrame(frame)
        FFmpeg.freeFrame(softwareFrame)
        FFmpeg.freeFrame(filteredFrame)
        FFmpeg.freeFrame(activeSubtitle?.canvas)
        FFmpeg.freeFrame(blankCanvas)
        FFmpeg.freePacket(packet)
    }

    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        // Damaged packets are skipped, as ffmpeg does.
        guard avcodec_send_packet(decoder, packet) >= 0 else { return }
        try receiveFrames()
    }

    func finish() throws {
        avcodec_send_packet(decoder, nil)
        try receiveFrames()
        if let source {
            _ = av_buffersrc_add_frame_flags(source, nil, 0)
            if let subtitleSource { _ = av_buffersrc_add_frame_flags(subtitleSource, nil, 0) }
            try drainFilters()
        }
        if let encoder {
            avcodec_send_frame(encoder, nil)
            try receivePackets()
        }
    }

    /// Bitmap subtitles to show, in microseconds of the source's timeline.
    func addSubtitle(_ subtitle: BitmapSubtitle) {
        let index = pendingSubtitles.lastIndex { $0.start <= subtitle.start }.map { $0 + 1 } ?? 0
        pendingSubtitles.insert(subtitle, at: index)
    }

    // MARK: Decoding and filtering

    private func receiveFrames() throws {
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            try process(frame)
        }
    }

    private func process(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        frame.pointee.pts = frame.pointee.best_effort_timestamp
        let isHardwareFrame = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        // Containers don't always flag interlacing, so the first frame decides too. Later frames
        // can't switch paths: the encoder is already set up for one or the other.
        if encoder == nil, graph == nil, frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 { deinterlace = true }
        if case .off = burnIn, !deinterlace, isHardwareFrame, graph == nil {
            // Nothing to draw: the frame goes straight from the decoder to the encoder
            // without leaving the media engine.
            try encode(frame, timeBase: timeBase, startsAtZero: false)
            return
        }

        var picture = frame
        if isHardwareFrame {
            // The subtitle filters run on the CPU, so the frame is copied back to system memory.
            av_frame_unref(softwareFrame)
            try FFmpeg.check(av_hwframe_transfer_data(softwareFrame, frame, 0), "Couldn't read a decoded frame")
            try FFmpeg.check(av_frame_copy_props(softwareFrame, frame), "Couldn't read a decoded frame")
            picture = softwareFrame
        }
        if picture.pointee.pts != FFmpeg.noTimestamp { picture.pointee.pts -= filterShift }
        if graph == nil { try makeGraph(for: picture) }
        if let subtitleSource { try pushSubtitleCanvas(to: subtitleSource, at: picture.pointee.pts) }
        try FFmpeg.check(
            av_buffersrc_add_frame_flags(source, picture, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)),
            "Couldn't filter the video"
        )
        try drainFilters()
    }

    /// buffer → [bwdif] → [subtitles | overlay] → format (what the encoder accepts) → buffersink
    private func makeGraph(for frame: UnsafeMutablePointer<AVFrame>) throws {
        guard let graph = avfilter_graph_alloc() else { throw ConversionError.ffmpegFailed("Out of memory.") }
        self.graph = graph
        let source = try FFmpeg.addSource(to: graph) { parameters in
            parameters.pointee.format = frame.pointee.format
            parameters.pointee.width = frame.pointee.width
            parameters.pointee.height = frame.pointee.height
            parameters.pointee.time_base = timeBase
            parameters.pointee.frame_rate = frameRate
            parameters.pointee.sample_aspect_ratio = frame.pointee.sample_aspect_ratio
            parameters.pointee.color_space = frame.pointee.colorspace
            parameters.pointee.color_range = frame.pointee.color_range
        }
        var last = source

        if deinterlace {
            // Before the subtitles so they stay sharp. One frame per frame keeps the source's frame rate;
            // `interlaced` leaves frames flagged progressive untouched.
            let bwdif = try FFmpeg.addFilter(
                "bwdif", to: graph, options: [("mode", "send_frame"), ("deint", "interlaced")]
            )
            try FFmpeg.link(last, to: bwdif)
            last = bwdif
        }

        switch burnIn {
        case .off:
            break
        case .text(let file, let streamIndex, _):
            var options = [("filename", file.path)]
            if let streamIndex { options.append(("stream_index", String(streamIndex))) }
            let subtitles = try FFmpeg.addFilter("subtitles", to: graph, options: options)
            try FFmpeg.link(last, to: subtitles)
            last = subtitles
        case .bitmap:
            canvasSize = (frame.pointee.width, frame.pointee.height)
            blankCanvas = try SubtitleCanvas.make(size: canvasSize)
            let subtitleSource = try FFmpeg.addSource(to: graph) { parameters in
                parameters.pointee.format = AV_PIX_FMT_YUVA420P.rawValue
                parameters.pointee.width = canvasSize.width
                parameters.pointee.height = canvasSize.height
                parameters.pointee.time_base = timeBase
                parameters.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
            }
            let overlay = try FFmpeg.addFilter("overlay", to: graph, options: [("eof_action", "pass")])
            try FFmpeg.link(last, to: overlay)
            try FFmpeg.link(subtitleSource, to: overlay, pad: 1)
            self.subtitleSource = subtitleSource
            last = overlay
        }

        let pixelFormats = (FFmpeg.supported(encoderCodec, AV_CODEC_CONFIG_PIX_FORMAT, as: AVPixelFormat.self) ?? [])
            .filter { $0 != AV_PIX_FMT_VIDEOTOOLBOX }
            .compactMap { av_get_pix_fmt_name($0).map { String(cString: $0) } }
        if !pixelFormats.isEmpty {
            let convert = try FFmpeg.addFilter(
                "format", to: graph, options: [("pix_fmts", pixelFormats.joined(separator: "|"))]
            )
            try FFmpeg.link(last, to: convert)
            last = convert
        }
        let sink = try FFmpeg.addFilter("buffersink", to: graph)
        try FFmpeg.link(last, to: sink)
        try FFmpeg.check(avfilter_graph_config(graph, nil), "Couldn't set up the video filters")
        self.source = source
        self.sink = sink
    }

    private func drainFilters() throws {
        guard let sink else { return }
        while av_buffersink_get_frame(sink, filteredFrame) >= 0 {
            defer { av_frame_unref(filteredFrame) }
            try encode(filteredFrame, timeBase: av_buffersink_get_time_base(sink), startsAtZero: filterShift != 0)
        }
    }

    // MARK: Encoding

    /// The overlay filter needs a subtitle picture for every video frame to stay in sync,
    /// so the current one (or a transparent one) is pushed with each frame's timestamp.
    private func pushSubtitleCanvas(to subtitleSource: UnsafeMutablePointer<AVFilterContext>, at pts: Int64) throws {
        let time = av_rescale_q(pts, timeBase, FFmpeg.microseconds)
        while let next = pendingSubtitles.first, next.start <= time {
            pendingSubtitles.removeFirst()
            FFmpeg.freeFrame(activeSubtitle?.canvas)
            activeSubtitle = next.rects.isEmpty ? nil : (try SubtitleCanvas.render(next, size: canvasSize), next.end)
        }
        if let end = activeSubtitle?.end, time >= end {
            FFmpeg.freeFrame(activeSubtitle?.canvas)
            activeSubtitle = nil
        }
        guard let canvas = activeSubtitle?.canvas ?? blankCanvas else { return }
        canvas.pointee.pts = pts
        try FFmpeg.check(
            av_buffersrc_add_frame_flags(subtitleSource, canvas, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)),
            "Couldn't draw the subtitles"
        )
    }
}

// MARK: - Encoding

nonisolated extension VideoTranscoder {
    private func encode(_ frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational, startsAtZero: Bool) throws {
        if encoder == nil {
            try openEncoder(for: frame, timeBase: timeBase)
            encodedStartsAtZero = startsAtZero
        }
        guard let encoder else { return }
        if frame.pointee.pts == FFmpeg.noTimestamp {
            frame.pointee.pts = lastPts == Int64.min ? 0 : lastPts + 1
        }
        // Frames with repeated timestamps are dropped, like ffmpeg's default for MP4 and MKV.
        guard frame.pointee.pts > lastPts else { return }
        lastPts = frame.pointee.pts
        frame.pointee.pict_type = AV_PICTURE_TYPE_NONE
        try FFmpeg.check(avcodec_send_frame(encoder, frame), "Couldn't encode the video")
        try receivePackets()
    }

    private func receivePackets() throws {
        guard let encoder else { return }
        while avcodec_receive_packet(encoder, packet) >= 0 {
            try muxer.write(
                packet, timeBase: encoder.pointee.time_base,
                stream: output.pointee.index, startsAtZero: encodedStartsAtZero
            )
        }
    }

    /// Opens the encoder once the first frame shows the picture's real size and format.
    private func openEncoder(for frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) throws {
        guard let encoder = avcodec_alloc_context3(encoderCodec) else {
            throw ConversionError.ffmpegFailed("Out of memory.")
        }
        self.encoder = encoder
        encoder.pointee.width = frame.pointee.width
        encoder.pointee.height = frame.pointee.height
        encoder.pointee.sample_aspect_ratio = frame.pointee.sample_aspect_ratio
        encoder.pointee.time_base = timeBase
        encoder.pointee.framerate = frameRate
        encoder.pointee.color_range = frame.pointee.color_range
        encoder.pointee.color_primaries = frame.pointee.color_primaries
        encoder.pointee.color_trc = frame.pointee.color_trc
        encoder.pointee.colorspace = frame.pointee.colorspace
        encoder.pointee.chroma_sample_location = frame.pointee.chroma_location
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            encoder.pointee.pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX
            encoder.pointee.hw_frames_ctx = av_buffer_ref(frame.pointee.hw_frames_ctx)
        } else {
            encoder.pointee.pix_fmt = AVPixelFormat(rawValue: frame.pointee.format)
        }
        if muxer.needsGlobalHeader {
            encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }
        if let quality = format.videoQuality {
            encoder.pointee.flags |= AV_CODEC_FLAG_QSCALE
            encoder.pointee.global_quality = quality * FFmpeg.qualityScale
        }
        for (key, value) in format.videoEncoderOptions {
            try FFmpeg.check(av_opt_set(encoder.pointee.priv_data, key, value, 0), "Couldn't set the encoder's \(key)")
        }
        let name = FFmpeg.string(encoderCodec.pointee.name)
        try FFmpeg.check(avcodec_open2(encoder, encoderCodec, nil), "Couldn't start the \(name) encoder")

        let parameters = output.pointee.codecpar!
        try FFmpeg.check(avcodec_parameters_from_context(parameters, encoder), "Couldn't set up the video stream")
        if format.usesHVC1Tag { parameters.pointee.codec_tag = FFmpeg.hvc1Tag }
        if let displayMatrix,
           let data = av_packet_side_data_new(
               &parameters.pointee.coded_side_data, &parameters.pointee.nb_coded_side_data,
               AV_PKT_DATA_DISPLAYMATRIX, displayMatrix.count, 0
           ) {
            displayMatrix.withUnsafeBytes {
                data.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count)
            }
        }
        output.pointee.time_base = timeBase
        output.pointee.avg_frame_rate = frameRate
        try muxer.streamInitialized()
    }

    // MARK: Bitmap subtitles
}

/// Picks VideoToolbox decoding when FFmpeg offers it for the stream.
nonisolated private func preferVideoToolbox(
    _ context: UnsafeMutablePointer<AVCodecContext>?,
    _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    var format = formats
    while let current = format?.pointee, current != AV_PIX_FMT_NONE {
        if current == AV_PIX_FMT_VIDEOTOOLBOX { return current }
        format = format?.successor()
    }
    return avcodec_default_get_format(context, formats)
}
