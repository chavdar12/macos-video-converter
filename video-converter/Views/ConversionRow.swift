//
//  ConversionRow.swift
//  video-converter
//

import SwiftUI

/// A single row in the queue showing the file, its subtitles and progress.
struct ConversionRow: View {
    let item: ConversionItem
    let isLocked: Bool
    let chooseSubtitle: () -> Void
    let removeSubtitle: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                subtitleInfo
                statusView
            }

            Spacer()

            Menu {
                Button("Choose Subtitle File…", action: chooseSubtitle)
                if item.subtitleURL != nil {
                    Button("Remove Subtitle File", action: removeSubtitle)
                }
                if let outputURL = item.outputURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                }
                Divider()
                Button("Remove from List", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isLocked)
            .accessibilityIdentifier("rowMenu")
        }
        .padding(.vertical, 4)
    }

    private var subtitleInfo: some View {
        subtitleLabel.accessibilityIdentifier("rowSubtitles")
    }

    @ViewBuilder
    private var subtitleLabel: some View {
        if let subtitleURL = item.subtitleURL {
            Label(subtitleURL.lastPathComponent, systemImage: "captions.bubble.fill")
                .font(.caption)
                .foregroundStyle(.tint)
        } else if item.embeddedSubtitleTracks > 0 {
            Label(
                item.embeddedSubtitleTracks == 1 ? "1 embedded subtitle track" : "\(item.embeddedSubtitleTracks) embedded subtitle tracks",
                systemImage: "captions.bubble"
            )
            .font(.caption)
            .foregroundStyle(.tint)
        } else {
            Label("No subtitles", systemImage: "captions.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusView: some View {
        statusLabel.accessibilityIdentifier("rowStatus")
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .pending:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .converting:
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
