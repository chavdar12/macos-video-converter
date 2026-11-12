//
//  CancellationFlag.swift
//  video-converter
//

import Foundation
import os

/// Set from any thread to stop a running conversion.
nonisolated final class CancellationFlag: Sendable {
    // OSAllocatedUnfairLock rather than Mutex, which needs macOS 15.
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0 = true }
    }
}
