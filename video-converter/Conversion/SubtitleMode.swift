//
//  SubtitleMode.swift
//  video-converter
//

import Foundation

/// How subtitles found in (or next to) a video are handled.
nonisolated enum SubtitleMode: String, CaseIterable, Identifiable {
    /// Draw the subtitles into the picture so they are always visible.
    case burnIn
    /// Keep subtitles as selectable tracks and mark the first one as enabled.
    case keepTrack
    /// Drop all subtitles.
    case remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .burnIn: "Burn in (always visible)"
        case .keepTrack: "Keep as track (enabled by default)"
        case .remove: "Remove subtitles"
        }
    }
}
