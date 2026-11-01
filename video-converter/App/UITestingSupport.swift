//
//  UITestingSupport.swift
//  video-converter
//

#if DEBUG
import Foundation

/// Lets UI tests start the app with files already queued, since they can't drive the system open panel.
///
/// The app is sandboxed and can't read the test bundle's files, so tests pass the media itself:
/// - `-ui-testing` turns this on.
/// - `UITEST_FILES` lists `name:base64data` pairs separated by `;`; each is written to a scratch
///   folder in the app's container and queued.
/// - `UITEST_OUTPUT=1` also sets an output folder there, so Convert All can run.
enum UITestingSupport {
    static let launchArgument = "-ui-testing"

    static func prepare(_ model: ConverterModel) {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains(launchArgument) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "UITesting")
        try? FileManager.default.removeItem(at: folder)
        let output = folder.appending(path: "Output")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let files = (process.environment["UITEST_FILES"] ?? "").split(separator: ";").compactMap { entry -> URL? in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let data = Data(base64Encoded: String(parts[1])) else { return nil }
            let url = folder.appending(path: String(parts[0]))
            return (try? data.write(to: url)) != nil ? url : nil
        }
        model.add(files)
        if process.environment["UITEST_OUTPUT"] == "1" {
            model.setOutputFolder(output)
        }
    }
}
#endif
