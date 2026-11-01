//
//  MediaInfoTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

@Suite("Probing files")
struct MediaInfoTests {
    @Test func readsVideoAudioAndTextSubtitles() async throws {
        let info = try await VideoConverter.probe(Fixture.h264MovText.url)
        #expect(info.video?.codecName == "h264")
        #expect(info.audioStreams.map(\.codecName) == ["aac"])
        #expect(info.subtitleStreams.map(\.codecName) == ["mov_text"])
        #expect(info.subtitleStreams.allSatisfy { $0.isTextSubtitle })
        #expect(abs(info.duration - 2) < 0.1)
    }

    @Test func reportsWhichSubtitleTrackIsTheDefault() async throws {
        let info = try await VideoConverter.probe(Fixture.hevc10TwoSRT.url)
        #expect(info.video?.codecName == "hevc")
        #expect(info.audioStreams.map(\.codecName) == ["ac3"])
        #expect(info.subtitleStreams.map(\.codecName) == ["subrip", "subrip"])
        #expect(info.subtitleStreams.map(\.isDefault) == [false, true])
    }

    @Test func audioOnlyFileHasNoVideo() async throws {
        let info = try await VideoConverter.probe(Fixture.audioOnly.url)
        #expect(!info.hasVideo)
        #expect(info.hasAudio)
    }

    @Test func subtitleFileHasOnlyASubtitleStream() async throws {
        let info = try await VideoConverter.probe(Fixture.sidecar.url)
        #expect(!info.hasVideo)
        #expect(!info.hasAudio)
        #expect(info.subtitleStreams.count == 1)
    }

    @Test(arguments: [
        (Fixture.h264MovText, 1), (.hevc10TwoSRT, 2), (.transportStream, 0), (.vp8Opus51, 0), (.notMedia, 0),
    ])
    func countsEmbeddedSubtitleTracks(_ fixture: Fixture, expected: Int) async throws {
        #expect(await VideoConverter.embeddedSubtitleTrackCount(in: try fixture.url) == expected)
    }

    @Test func unreadableFilesThrow() async throws {
        for url in [try Fixture.notMedia.url, URL(filePath: "/nonexistent/movie.mp4")] {
            let error = await #expect(throws: ConversionError.self) { try await VideoConverter.probe(url) }
            guard case .unreadable? = error else {
                Issue.record("Expected .unreadable for \(url.lastPathComponent), got \(String(describing: error))")
                continue
            }
        }
    }
}
