//
//  MediaInfo.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// The streams FFmpeg finds in a file.
nonisolated struct MediaInfo: Sendable {
    enum StreamKind: Sendable {
        case video, audio, subtitle, other
    }

    struct Stream: Sendable {

        let index: Int
        let kind: StreamKind
        let codecName: String
        let isDefault: Bool
        /// Cover art shows up as a video stream too.
        let isAttachedPicture: Bool
        /// Text subtitles can become `mov_text` or be rendered with libass; bitmap ones (PGS, VobSub) can't.
        let isTextSubtitle: Bool
    }

    let streams: [Stream]
    /// In seconds; 0 when unknown.
    let duration: Double

    init(context: UnsafeMutablePointer<AVFormatContext>) {
        streams = (0..<Int(context.pointee.nb_streams)).map { index in
            let stream = FFmpeg.stream(context, index)
            let parameters = stream.pointee.codecpar.pointee
            let kind: StreamKind = switch parameters.codec_type {
            case AVMEDIA_TYPE_VIDEO: .video
            case AVMEDIA_TYPE_AUDIO: .audio
            case AVMEDIA_TYPE_SUBTITLE: .subtitle
            default: .other
            }
            let properties = avcodec_descriptor_get(parameters.codec_id)?.pointee.props ?? 0
            return Stream(
                index: index,
                kind: kind,
                codecName: FFmpeg.string(avcodec_get_name(parameters.codec_id)),
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
                isAttachedPicture: stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0,
                isTextSubtitle: properties & AV_CODEC_PROP_TEXT_SUB != 0
            )
        }
        let duration = context.pointee.duration
        self.duration = duration == FFmpeg.noTimestamp ? 0 : Double(duration) / Double(AV_TIME_BASE)
    }

    var subtitleStreams: [Stream] { streams.filter { $0.kind == .subtitle } }
    var audioStreams: [Stream] { streams.filter { $0.kind == .audio } }
    var hasAudio: Bool { !audioStreams.isEmpty }
    /// The main video stream, not cover art.
    var video: Stream? { streams.first { $0.kind == .video && !$0.isAttachedPicture } }
    var hasVideo: Bool { video != nil }
}
