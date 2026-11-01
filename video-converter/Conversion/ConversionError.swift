//
//  ConversionError.swift
//  video-converter
//

import Foundation

nonisolated enum ConversionError: LocalizedError {
    case unreadable
    case noMediaTracks
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The file couldn't be read."
        case .noMediaTracks:
            "The file doesn't contain any playable video or audio."
        case .ffmpegFailed(let message):
            message
        }
    }
}
