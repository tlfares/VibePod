import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FileImportService: ObservableObject {
    @Published private(set) var isImporting = false
    @Published var lastError: String?

    private let libraryService: LibraryService
    private let fileManager = FileManager.default

    init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    /// Audio files plus optional companion LRC files picked at the same time.
    static var importableContentTypes: [UTType] {
        Song.supportedAudioUTTypes + [UTType(filenameExtension: "lrc") ?? .plainText]
    }

    /// Imports files returned by `fileImporter` (security-scoped URLs). Lyrics
    /// are copied first so the songs imported right after pick them up.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        libraryService.activityMessage = urls.count > 1 ? String(localized: "Importing \(urls.count) Files…") : String(localized: "Importing…")
        defer {
            isImporting = false
            libraryService.activityMessage = nil
        }

        let lyrics = urls.filter { ["lrc", "txt"].contains($0.pathExtension.lowercased()) }
        let audio = urls.filter { Song.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }

        for url in lyrics {
            copy(url, into: libraryService.lyricsDirectory)
        }

        var failures = 0
        for url in audio {
            guard let destination = copy(url, into: libraryService.musicDirectory),
                  let song = await libraryService.createSongFromFile(url: destination) else {
                failures += 1
                continue
            }
            if let existing = libraryService.songs.first(where: { $0.fileURL.standardizedFileURL == destination.standardizedFileURL }) {
                // Re-importing a file refreshes its tags but keeps its identity
                // (playlists, pins and queue keep pointing at it).
                ArtworkStore.remove(for: existing.id)
                let refreshed = Song(
                    id: existing.id,
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    albumArtist: song.albumArtist,
                    genre: song.genre,
                    duration: song.duration,
                    fileURL: destination,
                    artworkData: song.artworkData,
                    addedAt: existing.addedAt,
                    trackNumber: song.trackNumber,
                    discNumber: song.discNumber,
                    year: song.year,
                    lrcFilePath: song.lrcFilePath ?? existing.lrcFilePath,
                    fileSize: song.fileSize,
                    format: song.format
                )
                ArtworkStore.remove(for: song.id)
                libraryService.updateSong(refreshed)
            } else {
                libraryService.addSong(song)
            }
        }
        if failures > 0 {
            lastError = String(localized: "\(failures) files couldn't be imported.")
        }
    }

    @discardableResult
    private func copy(_ url: URL, into directory: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Self.placeFile(url, in: directory)
    }

    /// Copies `url` into `directory` without ever destroying another file:
    /// - already inside the directory (picked from Files): used in place;
    /// - same name and same bytes: the existing copy is reused (re-import);
    /// - same name, different file: saved as "Name 2.ext".
    nonisolated static func placeFile(_ url: URL, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return destination
        }
        if fileManager.fileExists(atPath: destination.path) {
            if fileManager.contentsEqual(atPath: url.path, andPath: destination.path) {
                return destination
            }
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 2
            repeat {
                destination = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
                counter += 1
            } while fileManager.fileExists(atPath: destination.path)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }
}
