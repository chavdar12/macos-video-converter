//
//  ProResEncoder.swift
//  video-converterTests
//

import VideoToolbox

enum ProResEncoder {
    /// Whether this Mac has a hardware ProRes encoder, which `prores_videotoolbox` requires. GitHub's virtual macOS
    /// runners only have the software one, so the ProRes conversions are skipped there instead of failing.
    static let isAvailable: Bool = {
        var session: VTCompressionSession?
        let hardwareOnly = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_AppleProRes422,
            encoderSpecification: hardwareOnly, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }()
}
