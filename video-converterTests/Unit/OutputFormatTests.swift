//
//  OutputFormatTests.swift
//  video-converterTests
//

import Testing
@testable import video_converter

@Suite("Output formats")
struct OutputFormatTests {
    struct VideoFormat: Sendable, CustomTestStringConvertible {
        let format: OutputFormat
        let fileExtension: String
        let muxer: String
        let codec: String
        let encoder: String

        var testDescription: String { format.rawValue }
    }

    static let videoFormats = [
        VideoFormat(format: .mp4H264, fileExtension: "mp4", muxer: "mp4", codec: "h264", encoder: "h264_videotoolbox"),
        VideoFormat(format: .mp4HEVC, fileExtension: "mp4", muxer: "mp4", codec: "hevc", encoder: "hevc_videotoolbox"),
        VideoFormat(
            format: .mkvH264, fileExtension: "mkv", muxer: "matroska", codec: "h264", encoder: "h264_videotoolbox"
        ),
        VideoFormat(format: .movH264, fileExtension: "mov", muxer: "mov", codec: "h264", encoder: "h264_videotoolbox"),
        VideoFormat(format: .movHEVC, fileExtension: "mov", muxer: "mov", codec: "hevc", encoder: "hevc_videotoolbox"),
        VideoFormat(
            format: .movProRes, fileExtension: "mov", muxer: "mov", codec: "prores", encoder: "prores_videotoolbox"
        ),
        VideoFormat(format: .m4v, fileExtension: "m4v", muxer: "ipod", codec: "h264", encoder: "h264_videotoolbox")
    ]

    @Test("Video formats map to the right container and encoder", arguments: videoFormats)
    func videoFormat(_ expected: VideoFormat) {
        let format = expected.format
        #expect(format.fileExtension == expected.fileExtension)
        #expect(format.muxerName == expected.muxer)
        #expect(format.videoCodec == expected.codec)
        #expect(format.videoEncoderName == expected.encoder)
        #expect(!format.isAudioOnly)
    }

    @Test func audioOnlyFormatHasNoVideo() {
        let format = OutputFormat.m4a
        #expect(format.isAudioOnly)
        #expect(format.fileExtension == "m4a")
        #expect(format.muxerName == "ipod")
        #expect(format.videoCodec == nil)
        #expect(format.videoEncoderName == nil)
        #expect(format.videoQuality == nil)
        #expect(format.videoEncoderOptions.isEmpty)
    }

    @Test func h264AndHEVCUseConstantQualityWithSoftwareFallback() {
        for format in [OutputFormat.mp4H264, .mkvH264, .movH264, .m4v] {
            #expect(format.videoQuality == 65)
            #expect(format.videoEncoderOptions.contains { $0 == ("allow_sw", "1") })
        }
        for format in [OutputFormat.mp4HEVC, .movHEVC] {
            #expect(format.videoQuality == 60)
            #expect(format.videoEncoderOptions.contains { $0 == ("allow_sw", "1") })
        }
    }

    @Test func proResUsesStandardProfileAndPCMAudio() {
        let format = OutputFormat.movProRes
        #expect(format.videoQuality == nil)
        #expect(format.videoEncoderOptions.contains { $0 == ("profile", "standard") })
        #expect(format.audioEncoderName == "pcm_s16le")
        #expect(format.audioBitRate == 0)
    }

    @Test(arguments: OutputFormat.allCases.filter { $0 != .movProRes })
    func otherFormatsUseAAC(_ format: OutputFormat) {
        #expect(format.audioEncoderName == "aac")
        #expect(format.audioBitRate == 192_000)
    }

    @Test(arguments: OutputFormat.allCases)
    func onlyHEVCGetsTheHvc1Tag(_ format: OutputFormat) {
        #expect(format.usesHVC1Tag == (format.videoCodec == "hevc"))
    }

    @Test func matroskaAndMP4FamilyAcceptDifferentAudio() {
        for codec in ["aac", "mp3", "ac3", "eac3", "alac"] {
            #expect(OutputFormat.mp4H264.canCopyAudio(codec), "\(codec)")
        }
        for codec in ["opus", "flac", "mp2", "vorbis", "pcm_s16le"] {
            #expect(!OutputFormat.mp4H264.canCopyAudio(codec), "\(codec)")
        }
        #expect(!OutputFormat.mp4H264.canCopyAudio(nil))
        for codec in ["aac", "opus", "flac", "mp2", "truehd"] {
            #expect(OutputFormat.mkvH264.canCopyAudio(codec), "\(codec)")
        }
        #expect(OutputFormat.mkvH264.isMatroska)
        #expect(OutputFormat.allCases.filter { $0.isMatroska } == [.mkvH264])
    }

    @Test func titlesAndIdentifiersAreUnique() {
        #expect(Set(OutputFormat.allCases.map(\.title)).count == OutputFormat.allCases.count)
        #expect(OutputFormat.allCases.allSatisfy { $0.id == $0.rawValue })
        #expect(Set(SubtitleMode.allCases.map(\.title)).count == SubtitleMode.allCases.count)
        #expect(SubtitleMode.allCases.allSatisfy { $0.id == $0.rawValue })
    }
}
