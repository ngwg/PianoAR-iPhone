import Foundation

/// User-imported songs.
///
/// The phone lives in a headset, so there is no in-app file picker. Songs
/// come in from outside instead:
///  * Files app → On My iPhone → PianoAR → drop `.mid` / `.midi` / `.json`
///    files there (UIFileSharingEnabled), or
///  * "Open in PianoAR" / AirDrop on a MIDI file (copied into Songs/).
/// Everything found is listed in the AR LIBRARY after the built-in songs.
enum SongLibrary {
    private static let exts: Set<String> = ["mid", "midi", "json"]

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var songsFolder: URL {
        let url = documents.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every readable song in Documents and Documents/Songs, sorted by title.
    static func loadImported() -> [Song] {
        let fm = FileManager.default
        var urls: [URL] = []
        for folder in [documents, songsFolder] {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            urls += items.filter { exts.contains($0.pathExtension.lowercased()) }
        }
        return urls.compactMap(load).sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    static func load(_ url: URL) -> Song? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "json" {
            guard let song = try? JSONDecoder().decode(Song.self, from: data) else { return nil }
            return Song(title: song.title ?? name, bpm: song.bpm, notes: song.notes)
        }
        return try? MIDIFileImporter.song(from: data, title: name)
    }

    /// Copies a file handed to the app (Open in / AirDrop) into Songs/.
    @discardableResult
    static func importFile(at url: URL) -> Bool {
        guard exts.contains(url.pathExtension.lowercased()) else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = songsFolder.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL == dest.standardizedFileURL { return true }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: url, to: dest)
            return true
        } catch {
            return false
        }
    }
}
