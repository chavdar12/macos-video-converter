//
//  PacketHandler.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat

/// Receives the demuxed packets of one input stream.
nonisolated protocol PacketHandler: AnyObject {
    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws
    /// Called at the end of the input to drain decoders, filters and encoders.
    func finish() throws
}

/// A handler that produces an output stream.
nonisolated protocol OutputHandler: PacketHandler {
    var output: UnsafeMutablePointer<AVStream> { get }
}
