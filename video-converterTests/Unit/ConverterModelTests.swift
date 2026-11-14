//
//  ConverterModelTests.swift
//  video-converterTests
//

import Foundation
import Testing
@testable import video_converter

@MainActor
@Suite("Converter model")
struct ConverterModelTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    // MARK: Adding files

    @Test func pairsSidecarSubtitlesWithTheVideoTheyAreNamedAfter() {
        let model = ConverterModel()
        model.add([
            directory.file("Movie.mp4"),
            directory.file("Movie.en.SRT"),
            directory.file("Other.mkv"),
            directory.file("Other Cut.mkv"),
            directory.file("Other Cut.vtt"),
            directory.file("Unrelated.ass")
        ])
        let byName = Dictionary(uniqueKeysWithValues: model.items.map { ($0.name, $0) })
        #expect(model.items.map(\.name) == ["Movie.mp4", "Other.mkv", "Other Cut.mkv"])
        #expect(byName["Movie.mp4"]?.subtitleURL?.lastPathComponent == "Movie.en.SRT")
        // The longest matching name wins.
        #expect(byName["Other Cut.mkv"]?.subtitleURL?.lastPathComponent == "Other Cut.vtt")
        #expect(byName["Other.mkv"]?.subtitleURL == nil)
    }

    @Test func ignoresVideosAlreadyInTheList() {
        let model = ConverterModel()
        model.add([directory.file("Movie.mp4")])
        model.add([directory.file("Movie.mp4"), directory.file("Second.mp4")])
        #expect(model.items.map(\.name) == ["Movie.mp4", "Second.mp4"])
    }

    @Test func countsEmbeddedSubtitlesInTheBackground() async throws {
        let model = ConverterModel()
        model.add([try Fixture.hevc10TwoSRT.url])
        let item = try #require(model.items.first)
        try await waitUntil { item.embeddedSubtitleTracks == 2 }
        #expect(item.hasSubtitles)
    }

    @Test func subtitlesCanBeSetAndRemoved() {
        let model = ConverterModel()
        model.add([directory.file("Movie.mp4")])
        let item = model.items[0]
        #expect(!item.hasSubtitles)
        model.setSubtitle(directory.file("Subs.srt"), for: item)
        #expect(item.subtitleURL?.lastPathComponent == "Subs.srt")
        #expect(item.hasSubtitles)
    }

    @Test func removesItemsAndClearsFinishedOnes() {
        let model = ConverterModel()
        model.add([directory.file("A.mp4"), directory.file("B.mp4"), directory.file("C.mp4")])
        model.remove(model.items[0])
        #expect(model.items.map(\.name) == ["B.mp4", "C.mp4"])
        model.items[0].status = .done
        model.clearFinished()
        #expect(model.items.map(\.name) == ["C.mp4"])
    }

    // MARK: Converting

    @Test func canConvertNeedsAnOutputFolderAndUnfinishedItems() {
        let model = ConverterModel()
        #expect(!model.canConvert)
        model.add([directory.file("Movie.mp4")])
        #expect(!model.canConvert)
        model.setOutputFolder(directory.url)
        #expect(model.canConvert)
        model.items[0].status = .done
        #expect(!model.canConvert)
    }

    @Test func outputNamesNeverOverwriteExistingFiles() throws {
        let model = ConverterModel()
        model.add([directory.file("Movie.mkv")])
        let item = model.items[0]
        #expect(model.uniqueOutputURL(for: item, in: directory.url, excluding: []).lastPathComponent == "Movie.mp4")

        try Data().write(to: directory.file("Movie.mp4"))
        let next = model.uniqueOutputURL(for: item, in: directory.url, excluding: [])
        #expect(next.lastPathComponent == "Movie (1).mp4")
        // Names already handed out in this run count too, even before the file exists.
        #expect(
            model.uniqueOutputURL(for: item, in: directory.url, excluding: [next]).lastPathComponent == "Movie (2).mp4"
        )

        model.format = .m4a
        #expect(model.uniqueOutputURL(for: item, in: directory.url, excluding: []).lastPathComponent == "Movie.m4a")
    }

    @Test func convertsEveryItemAndReportsFailures() async throws {
        let good = directory.file("Good.mp4")
        let broken = directory.file("Broken.mp4")
        try FileManager.default.copyItem(at: Fixture.h264MovText.url, to: good)
        try FileManager.default.copyItem(at: Fixture.notMedia.url, to: broken)
        let output = directory.file("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let model = ConverterModel()
        model.add([good, broken])
        model.setOutputFolder(output)
        model.convertAll()
        #expect(model.isConverting)
        try await waitUntil(timeout: .seconds(60)) { !model.isConverting }

        let (goodItem, brokenItem) = (model.items[0], model.items[1])
        #expect(goodItem.status == .done)
        #expect(goodItem.progress == 1)
        let outputURL = try #require(goodItem.outputURL)
        #expect(outputURL.lastPathComponent == "Good.mp4")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        guard case .failed(let message) = brokenItem.status else {
            Issue.record("Expected the broken file to fail, got \(brokenItem.status)")
            return
        }
        #expect(message == ConversionError.unreadable.errorDescription)
        #expect(!FileManager.default.fileExists(atPath: output.appending(path: "Broken (1).mp4").path))

        // Finished items are skipped on the next run.
        #expect(model.canConvert)
    }

    @Test func cancellingBeforeStartingMarksEverythingCancelled() async throws {
        let model = ConverterModel()
        model.add([directory.file("A.mp4"), directory.file("B.mp4")])
        model.setOutputFolder(directory.url)
        model.convertAll()
        model.cancel()
        try await waitUntil { !model.isConverting }
        #expect(model.items.allSatisfy { $0.status == .cancelled })
    }

    /// Polls `condition` on the main actor until it's true or `timeout` passes.
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
