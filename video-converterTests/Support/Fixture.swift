//
//  Fixture.swift
//  video-converterTests
//

import Foundation
import Testing

/// Sample media bundled with the tests (flat dark ffmpeg-generated clips, committed in Fixtures/).
///
/// Every video is a flat dark picture, 2 seconds long. Subtitles show from 0.2 to 1.0 s, except the
/// MKV's non-default track, which shows from 1.2 to 1.8 s.
enum Fixture: String, CaseIterable, CustomTestStringConvertible {
    /// H.264, AAC (mono), one embedded mov_text track.
    case h264MovText = "h264-aac-movtext.mp4"
    /// 10-bit HEVC, 5.1 AC-3, two SRT tracks of which the second is the default.
    case hevc10TwoSRT = "hevc10-ac3-2srt.mkv"
    /// H.264 and MP2 in MPEG-TS, which starts at about 1.4 s instead of 0.
    case transportStream = "h264-mp2.mts"
    /// Interlaced (top field first) H.264 of a fast-moving, detailed picture; no audio or subtitles.
    case interlaced = "h264-interlaced.mp4"
    /// VP8 (no hardware decoding) and 5.1 Opus.
    case vp8Opus51 = "vp8-opus51.mkv"
    /// AAC only, no video.
    case audioOnly = "aac-only.m4a"
    /// A sidecar subtitle file.
    case sidecar = "sidecar.srt"
    /// A text file that isn't media.
    case notMedia = "not-media.txt"

    var url: URL {
        get throws {
            let bundle = Bundle(for: BundleToken.self)
            guard let url = bundle.url(forResource: rawValue, withExtension: nil)
                ?? bundle.url(forResource: rawValue, withExtension: nil, subdirectory: "Fixtures")
            else { throw FixtureError.missing(rawValue) }
            return url
        }
    }

    var testDescription: String { rawValue }
}

enum FixtureError: Error {
    case missing(String)
}

private final class BundleToken {}
