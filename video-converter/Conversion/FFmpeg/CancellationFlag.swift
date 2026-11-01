//
//  CancellationFlag.swift
//  video-converter
//

import Foundation
import Synchronization

/// Set from any thread to stop a running conversion.
nonisolated final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}
