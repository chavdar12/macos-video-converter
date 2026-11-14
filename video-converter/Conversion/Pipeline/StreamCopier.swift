//
//  StreamCopier.swift
//  video-converter
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Passes packets through unchanged.
nonisolated final class StreamCopier: OutputHandler {
    let output: UnsafeMutablePointer<AVStream>
    private let muxer: Muxer
    private let timeBase: AVRational
    private let startsAtZero: Bool

    init(
        stream: UnsafeMutablePointer<AVStream>,
        muxer: Muxer,
        codecTag: UInt32 = 0,
        startsAtZero: Bool = false
    ) throws {
        self.muxer = muxer
        self.timeBase = stream.pointee.time_base
        self.startsAtZero = startsAtZero
        output = try muxer.addStream()
        try FFmpeg.check(
            avcodec_parameters_copy(output.pointee.codecpar, stream.pointee.codecpar),
            "Couldn't copy a stream"
        )
        // The source container's tag may not be valid in the output one; 0 lets the muxer pick.
        output.pointee.codecpar.pointee.codec_tag = codecTag
        output.pointee.time_base = stream.pointee.time_base
        output.pointee.avg_frame_rate = stream.pointee.avg_frame_rate
        output.pointee.disposition = stream.pointee.disposition
    }

    func handle(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        try muxer.write(packet, timeBase: timeBase, stream: output.pointee.index, startsAtZero: startsAtZero)
    }

    func finish() throws {}
}
