//
//  MemoryUsage.swift
//  video-converterTests
//

import Darwin

enum MemoryUsage {
    /// Bytes currently allocated with malloc in this process, which includes FFmpeg's `av_malloc`.
    /// Unlike the resident size, it drops as soon as memory is freed, so leaks stand out.
    static var liveMallocBytes: Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}
