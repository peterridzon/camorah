import Foundation

/// Where the app keeps its things, and what it is called.
///
/// One place, because the name changes. It has already been Orah Control and
/// Orah Live Studio, and each rename silently orphaned a folder in Application
/// Support — with the config, the roster and every camera record inside it. The
/// app came back up looking like a fresh install standing next to a directory
/// full of work nobody could see.
///
/// So the name lives here once, the old names live here too, and the first
/// thing that asks for a path carries the old folder over.
public enum AppPaths {

    public static let name = "4idesk"

    /// Every name this app has shipped under, newest first. Never shorten this
    /// list — an operator who skipped a version still has the oldest folder.
    private static let previousNames = ["4i Studio", "Orah Live Studio", "Orah Control"]

    /// `~/Library/Application Support/<name>`, carried over from any earlier name.
    public static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let url = base.appendingPathComponent(name, isDirectory: true)
        adopt(into: url, from: previousNames.map { base.appendingPathComponent($0, isDirectory: true) })
        return url
    }()

    /// `~/Library/Logs/<name>`, likewise.
    public static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let url = base.appendingPathComponent(name, isDirectory: true)
        adopt(into: url, from: previousNames.map { base.appendingPathComponent($0, isDirectory: true) })
        return url
    }()

    /// Moves the first old folder that exists onto the new name.
    ///
    /// A move rather than a copy: two folders would drift, and the operator
    /// would have no way of telling which one the app was writing to. If the
    /// move fails the app carries on with an empty folder — losing settings is
    /// recoverable, refusing to start is not.
    private static func adopt(into destination: URL, from candidates: [URL]) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        guard let old = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: destination)
        } catch {
            // Deliberately quiet: Log itself asks for `logs`, so complaining
            // here would be a cycle. The empty folder is the visible symptom.
        }
    }
}
