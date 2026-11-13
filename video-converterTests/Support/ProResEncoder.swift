//
//  ProResEncoder.swift
//  video-converterTests
//

import VideoToolbox

enum ProResEncoder {
    /// Whether this Mac can encode ProRes with VideoToolbox. GitHub's virtual macOS runners can't, so the ProRes
    /// conversions are skipped there instead of failing.
    static let isAvailable: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_AppleProRes422,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }()
}
