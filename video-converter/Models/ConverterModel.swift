//
//  ConverterModel.swift
//  video-converter
//

import Foundation
import Observation

@Observable
final class ConverterModel {
    var items: [ConversionItem] = []
    var format: OutputFormat = .mp4H264
    var subtitleMode: SubtitleMode = .burnIn
    var outputFolder: URL?
    private(set) var isConverting = false

    /// Each ffmpeg is already multithreaded and they share one media engine, so more than a few just thrash.
    var maxParallelConversions = 5

    private var conversionTask: Task<Void, Never>?
    /// Security-scoped URLs we've started accessing and must release later.
    private var accessedURLs: Set<URL> = []

    var canConvert: Bool {
        !isConverting && outputFolder != nil && items.contains { $0.status != .done }
    }

    // MARK: - Adding files

    /// Adds videos and sidecar subtitle files. Subtitles are paired with videos
    /// whose file name they start with (e.g. `Movie.srt` or `Movie.en.srt` → `Movie.mp4`).
    func add(_ urls: [URL]) {
        var subtitles: [URL] = []
        for url in urls {
            startAccessing(url)
            if VideoConverter.sidecarExtensions.contains(url.pathExtension.lowercased()) {
                subtitles.append(url)
            } else if !items.contains(where: { $0.sourceURL == url }) {
                let item = ConversionItem(sourceURL: url)
                items.append(item)
                Task {
                    item.embeddedSubtitleTracks = await VideoConverter.embeddedSubtitleTrackCount(in: url)
                }
            }
        }

        for subtitle in subtitles {
            let subtitleName = subtitle.deletingPathExtension().lastPathComponent.lowercased()
            let match = items
                .filter { subtitleName.hasPrefix($0.baseName.lowercased()) }
                .max { $0.baseName.count < $1.baseName.count }
            match?.subtitleURL = subtitle
        }
    }

    func setSubtitle(_ url: URL, for item: ConversionItem) {
        startAccessing(url)
        item.subtitleURL = url
    }

    func setOutputFolder(_ url: URL) {
        if let outputFolder { stopAccessing(outputFolder) }
        startAccessing(url)
        outputFolder = url
    }

    func remove(_ item: ConversionItem) {
        items.removeAll { $0.id == item.id }
        stopAccessing(item.sourceURL)
        if let subtitleURL = item.subtitleURL { stopAccessing(subtitleURL) }
    }

    func clearFinished() {
        for item in items where item.status == .done { remove(item) }
    }

    // MARK: - Converting

    func convertAll() {
        guard let outputFolder, !isConverting else { return }
        isConverting = true

        conversionTask = Task {
            // Paths handed out this run; ffmpeg only creates the file once it starts writing.
            var reserved: Set<URL> = []
            await withTaskGroup(of: Void.self) { group in
                for (index, item) in items.filter({ $0.status != .done }).enumerated() {
                    if index >= maxParallelConversions { await group.next() }
                    if Task.isCancelled {
                        item.status = .cancelled
                        continue
                    }
                    let outputURL = uniqueOutputURL(for: item, in: outputFolder, excluding: reserved)
                    reserved.insert(outputURL)
                    group.addTask { await self.convert(item, to: outputURL) }
                }
            }
            isConverting = false
        }
    }

    func cancel() {
        conversionTask?.cancel()
    }

    private func convert(_ item: ConversionItem, to outputURL: URL) async {
        item.status = .converting
        item.progress = 0

        do {
            try await VideoConverter.convert(
                source: item.sourceURL,
                subtitleFile: item.subtitleURL,
                to: outputURL,
                format: format,
                subtitleMode: subtitleMode
            ) { progress in
                item.progress = progress
            }
            item.outputURL = outputURL
            item.status = .done
        } catch is CancellationError {
            item.status = .cancelled
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            item.status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    /// `Movie.mp4`, then `Movie (1).mp4`, `Movie (2).mp4`… so nothing gets overwritten.
    func uniqueOutputURL(for item: ConversionItem, in folder: URL, excluding reserved: Set<URL>) -> URL {
        let ext = format.fileExtension
        var candidate = folder.appending(path: "\(item.baseName).\(ext)")
        var counter = 1
        while reserved.contains(candidate)
                || FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(item.baseName) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Sandbox access

    private func startAccessing(_ url: URL) {
        guard !accessedURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
        }
    }

    private func stopAccessing(_ url: URL) {
        guard accessedURLs.remove(url) != nil else { return }
        url.stopAccessingSecurityScopedResource()
    }
}
