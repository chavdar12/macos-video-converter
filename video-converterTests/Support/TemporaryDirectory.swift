//
//  TemporaryDirectory.swift
//  video-converterTests
//

import Foundation

/// A scratch folder that's deleted along with this object.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "video-converterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }
}
