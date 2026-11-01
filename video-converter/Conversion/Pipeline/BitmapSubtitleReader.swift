//
//  BitmapSubtitleReader.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat

/// A decoded bitmap subtitle, copied out of FFmpeg's `AVSubtitle`.
nonisolated struct BitmapSubtitle {
    struct Rect {
        let x, y, width, height, linesize: Int
        /// Palette indices, `linesize` bytes per row.
        let pixels: [UInt8]
        let palette: [UInt32]
    }

    /// In microseconds of the source's timeline.
    let start: Int64
    let end: Int64?
    /// Empty to clear the screen.
    let rects: [Rect]
}

/// Decodes bitmap subtitles and hands them to the video transcoder to overlay.
nonisolated final class BitmapSubtitleReader: PacketHandler {
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let video: VideoTranscoder

    init(stream: UnsafeMutablePointer<AVStream>, video: VideoTranscoder) throws {
        decoder = try FFmpeg.openDecoder(for: stream)
        self.video = video
    }

    deinit {
        FFmpeg.freeCodec(decoder)
    }

    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(decoder, &subtitle, &gotSubtitle, packet) >= 0, gotSubtitle != 0 else { return }
        defer { avsubtitle_free(&subtitle) }
        guard subtitle.pts != FFmpeg.noTimestamp else { return }

        let start = subtitle.pts + Int64(subtitle.start_display_time) * 1000
        let hasEnd = subtitle.end_display_time > subtitle.start_display_time && subtitle.end_display_time != UInt32.max
        var rects: [BitmapSubtitle.Rect] = []
        for i in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i]?.pointee, rect.type == SUBTITLE_BITMAP,
                  let pixels = rect.data.0, let palette = rect.data.1
            else { continue }
            let linesize = Int(rect.linesize.0)
            rects.append(BitmapSubtitle.Rect(
                x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h), linesize: linesize,
                pixels: Array(UnsafeBufferPointer(start: pixels, count: linesize * Int(rect.h))),
                palette: (0..<Int(rect.nb_colors)).map { UnsafeRawPointer(palette).loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
            ))
        }
        video.addSubtitle(BitmapSubtitle(
            start: start,
            end: hasEnd ? subtitle.pts + Int64(subtitle.end_display_time) * 1000 : nil,
            rects: rects
        ))
    }

    func finish() throws {}
}
