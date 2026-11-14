//
//  ContentView.swift
//  video-converter
//
//  Created by Chavdar Shishkov on 30.10.26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// What the shared file importer is currently picking.
    private enum ImportTarget {
        case videos
        case outputFolder
        case subtitle(ConversionItem)
    }

    @State private var model = ConverterModel()
    /// Kept separate from `isImporterPresented`: SwiftUI dismisses the importer
    /// (setting the flag to false) before calling its completion handler, so the
    /// target must survive the dismissal.
    @State private var importTarget: ImportTarget = .videos
    @State private var isImporterPresented = false
    @State private var isTargetedForDrop = false

    private static let subtitleTypes: [UTType] = VideoConverter.sidecarExtensions.compactMap {
        UTType(filenameExtension: $0)
    }
    // Formats like MKV aren't always registered as movies, so list them explicitly.
    private static let videoTypes: [UTType] = [.movie, .audiovisualContent]
        + ["mkv", "webm", "avi", "flv", "ts"].compactMap { UTType(filenameExtension: $0) } + subtitleTypes

    var body: some View {
        VStack(spacing: 0) {
            fileList
            Divider()
            settings
        }
        .frame(minWidth: 640, minHeight: 460)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Videos", systemImage: "plus") {
                    showImporter(for: .videos)
                }
                .disabled(model.isConverting)
                .accessibilityIdentifier("addVideosButton")
                Button("Clear Finished", systemImage: "checkmark.circle") {
                    model.clearFinished()
                }
                .disabled(model.isConverting || !model.items.contains { $0.status == .done })
                .accessibilityIdentifier("clearFinishedButton")
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: allowsMultipleSelection
        ) { result in
            handleImport(result)
        }
        .task {
            #if DEBUG
            UITestingSupport.prepare(model)
            #endif
        }
    }

    // MARK: - File list

    private var fileList: some View {
        Group {
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("No Videos", systemImage: "film.stack")
                } description: {
                    Text("""
                        Drop videos here, or click Add Videos. \
                        Drop .srt, .vtt or .ass files with the same name to add subtitles.
                        """)
                } actions: {
                    Button("Add Videos") { showImporter(for: .videos) }
                }
                .accessibilityIdentifier("emptyState")
            } else {
                List {
                    ForEach(model.items) { item in
                        ConversionRow(
                            item: item,
                            isLocked: model.isConverting,
                            chooseSubtitle: { showImporter(for: .subtitle(item)) },
                            removeSubtitle: { item.subtitleURL = nil },
                            remove: { model.remove(item) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isConverting else { return false }
            model.add(urls)
            return true
        } isTargeted: { isTargetedForDrop = $0 }
    }

    // MARK: - Settings

    private var settings: some View {
        Form {
            Picker("Output format", selection: $model.format) {
                ForEach(OutputFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .disabled(model.isConverting)
            .accessibilityIdentifier("formatPicker")

            Picker("Subtitles", selection: $model.subtitleMode) {
                ForEach(SubtitleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(model.isConverting)
            .accessibilityIdentifier("subtitlesPicker")

            Stepper("Convert at once: \(model.maxParallelConversions)", value: $model.maxParallelConversions, in: 1...8)
                .disabled(model.isConverting)
                .accessibilityIdentifier("parallelStepper")

            LabeledContent("Save to") {
                HStack {
                    Text(model.outputFolder?.path(percentEncoded: false) ?? "No folder selected")
                        .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("outputFolderLabel")
                    Button("Choose…") { showImporter(for: .outputFolder) }
                        .accessibilityIdentifier("chooseOutputFolderButton")
                }
            }
            .disabled(model.isConverting)

            HStack {
                Spacer()
                if model.isConverting {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("cancelButton")
                } else {
                    Button("Convert All") { model.convertAll() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConvert)
                        .accessibilityIdentifier("convertButton")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Importing

    private var allowedTypes: [UTType] {
        switch importTarget {
        case .outputFolder: [.folder]
        case .subtitle: Self.subtitleTypes
        case .videos: Self.videoTypes
        }
    }

    private var allowsMultipleSelection: Bool {
        if case .videos = importTarget { return true }
        return false
    }

    private func showImporter(for target: ImportTarget) {
        importTarget = target
        isImporterPresented = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let first = urls.first else { return }
        switch importTarget {
        case .videos: model.add(urls)
        case .outputFolder: model.setOutputFolder(first)
        case .subtitle(let item): model.setSubtitle(first, for: item)
        }
    }
}

#Preview {
    ContentView()
}
