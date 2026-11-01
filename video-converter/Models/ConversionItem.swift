//
//  ConversionItem.swift
//  video-converter
//

import Foundation
import Observation

/// One video in the conversion queue.
@Observable
final class ConversionItem: Identifiable {
    enum Status: Equatable {
        case pending
        case converting
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let sourceURL: URL
    var subtitleURL: URL?
    var embeddedSubtitleTracks = 0
    var status: Status = .pending
    var progress: Double = 0
    var outputURL: URL?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    var name: String { sourceURL.lastPathComponent }
    var baseName: String { sourceURL.deletingPathExtension().lastPathComponent }
    var hasSubtitles: Bool { subtitleURL != nil || embeddedSubtitleTracks > 0 }
}
