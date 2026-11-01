//
//  OutputFormat.swift
//  video-converter
//

import Foundation

/// The container / codec combinations the app can produce.
nonisolated enum OutputFormat: String, CaseIterable, Identifiable {
    case mp4H264
    case mp4HEVC
    case mkvH264
    case movH264
    case movHEVC
    case movProRes
    case m4v
    case m4a

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4H264: "MP4 (H.264)"
        case .mp4HEVC: "MP4 (HEVC / H.265)"
        case .mkvH264: "MKV (H.264)"
        case .movH264: "MOV (H.264)"
        case .movHEVC: "MOV (HEVC / H.265)"
        case .movProRes: "MOV (ProRes 422)"
        case .m4v: "M4V (H.264)"
        case .m4a: "M4A (Audio only)"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC: "mp4"
        case .mkvH264: "mkv"
        case .movH264, .movHEVC, .movProRes: "mov"
        case .m4v: "m4v"
        case .m4a: "m4a"
        }
    }

    /// The FFmpeg muxer; M4V and M4A use the iPod flavor of MP4, as ffmpeg picks for those extensions.
    var muxerName: String {
        switch self {
        case .mp4H264, .mp4HEVC: "mp4"
        case .mkvH264: "matroska"
        case .movH264, .movHEVC, .movProRes: "mov"
        case .m4v, .m4a: "ipod"
        }
    }

    /// The video codec name FFmpeg reports for this format's output; a source already in it is copied as-is.
    var videoCodec: String? {
        switch self {
        case .mp4H264, .movH264, .m4v, .mkvH264: "h264"
        case .mp4HEVC, .movHEVC: "hevc"
        case .movProRes: "prores"
        case .m4a: nil
        }
    }

    /// Video is encoded on the media engine via VideoToolbox.
    var videoEncoderName: String? {
        switch self {
        case .mp4H264, .movH264, .m4v, .mkvH264: "h264_videotoolbox"
        case .mp4HEVC, .movHEVC: "hevc_videotoolbox"
        case .movProRes: "prores_videotoolbox"
        case .m4a: nil
        }
    }

    /// Constant quality, like ffmpeg's `-q:v`.
    /// shortcut: constant quality needs Apple Silicon; Intel Macs would need a bit rate instead.
    var videoQuality: Int32? {
        switch self {
        case .mp4H264, .movH264, .m4v, .mkvH264: 65
        case .mp4HEVC, .movHEVC: 60
        case .movProRes, .m4a: nil
        }
    }

    /// Private encoder options. `allow_sw` falls back to software encoding if the media engine is unavailable.
    var videoEncoderOptions: [(String, String)] {
        switch self {
        case .movProRes: [("profile", "standard")]
        case .m4a: []
        default: [("allow_sw", "1")]
        }
    }

    /// hvc1 tag so QuickTime and Apple devices will play HEVC.
    var usesHVC1Tag: Bool { videoCodec == "hevc" }

    var audioEncoderName: String { self == .movProRes ? "pcm_s16le" : "aac" }
    var audioBitRate: Int64 { self == .movProRes ? 0 : 192_000 }

    /// Whether an audio stream in `codec` fits this container without re-encoding.
    func canCopyAudio(_ codec: String?) -> Bool {
        isMatroska || ["aac", "mp3", "ac3", "eac3", "alac"].contains(codec ?? "")
    }

    var isAudioOnly: Bool { self == .m4a }
    var isMatroska: Bool { self == .mkvH264 }
}
