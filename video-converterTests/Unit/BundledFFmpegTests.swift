//
//  BundledFFmpegTests.swift
//  video-converterTests
//

import Libavcodec
import Libavfilter
import Libavformat
import Libavutil
import Testing
@testable import video_converter

/// The FFmpeg build comes from a third-party package that disables most components,
/// so check that everything the app relies on is actually in it.
@Suite("Bundled FFmpeg")
struct BundledFFmpegTests {
    @Test(arguments: Set(OutputFormat.allCases.map(\.muxerName)))
    func muxerIsAvailable(_ name: String) {
        #expect(av_guess_format(name, nil, nil) != nil)
    }

    @Test(arguments: Set(OutputFormat.allCases.compactMap(\.videoEncoderName) + OutputFormat.allCases.map(\.audioEncoderName)) + ["mov_text", "webvtt"])
    func encoderIsAvailable(_ name: String) {
        #expect(avcodec_find_encoder_by_name(name) != nil)
    }

    /// Codec names, as `MediaInfo` reports them; the app finds decoders by codec, not decoder name.
    @Test(arguments: ["subrip", "ass", "webvtt", "mov_text", "hdmv_pgs_subtitle", "dvd_subtitle", "h264", "hevc", "vp8", "vp9", "av1", "opus", "ac3", "mp2"])
    func decoderIsAvailable(_ codec: String) throws {
        let descriptor = try #require(avcodec_descriptor_get_by_name(codec))
        #expect(avcodec_find_decoder(descriptor.pointee.id) != nil)
    }

    @Test(arguments: ["buffer", "buffersink", "abuffer", "abuffersink", "subtitles", "overlay", "format", "aformat", "scale", "aresample", "bwdif"])
    func filterIsAvailable(_ name: String) {
        #expect(avfilter_get_by_name(name) != nil)
    }

    @Test func videoToolboxDeviceCanBeCreated() {
        var device: UnsafeMutablePointer<AVBufferRef>?
        #expect(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0)
        av_buffer_unref(&device)
    }

    @Test func errorCodesDescribeThemselves() {
        #expect(FFmpeg.errorDescription(FFmpeg.endOfFile) == "End of file")
        #expect(throws: ConversionError.self) { try FFmpeg.check(-1, "Doing something") }
        #expect(throws: Never.self) { try FFmpeg.check(0, "Doing something") }
    }
}
