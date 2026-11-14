//
//  SubtitleCanvas.swift
//  video-converter
//

import Foundation
import Libavutil

/// Draws bitmap subtitles (PGS, VobSub) onto transparent YUVA 4:2:0 pictures for the overlay filter.
nonisolated enum SubtitleCanvas {
    /// A palette entry in limited-range BT.601 YUV plus alpha.
    private struct YUVA {
        let y: UInt8
        let u: UInt8
        let v: UInt8
        let a: UInt8
    }

    /// A transparent YUVA 4:2:0 picture of the given size.
    static func make(size: (width: Int32, height: Int32)) throws -> UnsafeMutablePointer<AVFrame> {
        let canvas = try FFmpeg.makeFrame()
        canvas.pointee.format = AV_PIX_FMT_YUVA420P.rawValue
        canvas.pointee.width = size.width
        canvas.pointee.height = size.height
        try FFmpeg.check(av_frame_get_buffer(canvas, 0), "Couldn't draw the subtitles")
        let height = Int(size.height)
        let chromaHeight = (height + 1) / 2
        let planes = [
            (canvas.pointee.data.0, canvas.pointee.linesize.0, height, Int32(16)),
            (canvas.pointee.data.1, canvas.pointee.linesize.1, chromaHeight, Int32(128)),
            (canvas.pointee.data.2, canvas.pointee.linesize.2, chromaHeight, Int32(128)),
            (canvas.pointee.data.3, canvas.pointee.linesize.3, height, Int32(0))
        ]
        for (data, linesize, rows, value) in planes {
            if let data { memset(data, value, Int(linesize) * rows) }
        }
        return canvas
    }

    static func render(
        _ subtitle: BitmapSubtitle,
        size: (width: Int32, height: Int32)
    ) throws -> UnsafeMutablePointer<AVFrame> {
        let canvas = try make(size: size)
        guard let lumaPlane = canvas.pointee.data.0, let uPlane = canvas.pointee.data.1,
              let vPlane = canvas.pointee.data.2, let alphaPlane = canvas.pointee.data.3
        else { return canvas }
        let lumaStride = Int(canvas.pointee.linesize.0), chromaStride = Int(canvas.pointee.linesize.1)
        let alphaStride = Int(canvas.pointee.linesize.3)
        let width = Int(size.width), height = Int(size.height)

        for rect in subtitle.rects {
            let colors = rect.palette.map(Self.yuva)
            for row in 0..<rect.height {
                let y = rect.y + row
                guard y >= 0, y < height else { continue }
                for column in 0..<rect.width {
                    let x = rect.x + column
                    guard x >= 0, x < width else { continue }
                    let index = Int(rect.pixels[row * rect.linesize + column])
                    guard index < colors.count, colors[index].a > 0 else { continue }
                    let color = colors[index]
                    lumaPlane[y * lumaStride + x] = color.y
                    alphaPlane[y * alphaStride + x] = color.a
                    uPlane[(y / 2) * chromaStride + x / 2] = color.u
                    vPlane[(y / 2) * chromaStride + x / 2] = color.v
                }
            }
        }
        return canvas
    }

    /// Converts a palette entry (0xAARRGGBB) to limited-range BT.601 YUV plus alpha.
    private static func yuva(_ argb: UInt32) -> YUVA {
        let a = Int(argb >> 24 & 0xFF), r = Int(argb >> 16 & 0xFF), g = Int(argb >> 8 & 0xFF), b = Int(argb & 0xFF)
        let y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16
        let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128
        let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128
        return YUVA(y: UInt8(clamping: y), u: UInt8(clamping: u), v: UInt8(clamping: v), a: UInt8(a))
    }
}
