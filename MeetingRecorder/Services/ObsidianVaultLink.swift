import Foundation

// One source of truth: the vault gets a "Meetings" symlink pointing at the
// app's Transcripts directory, so Obsidian browses the exact files the app
// manages — there are no exported copies to drift out of sync.
enum ObsidianVaultLink {
    static let linkName = "Meetings"

    static func linkURL(inVault vaultRoot: URL) -> URL {
        vaultRoot.appending(path: linkName)
    }

    static func isLinked(vaultRoot: URL, transcriptsURL: URL) -> Bool {
        let link = linkURL(inVault: vaultRoot)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let resolved = URL(filePath: destination, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL
        return resolved.path == transcriptsURL.standardizedFileURL.path
    }

    // Creates the symlink. Anything already sitting at the link location (for
    // example a folder of old exported copies) is moved aside, never deleted.
    @discardableResult
    static func link(vaultRoot: URL, transcriptsURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let link = linkURL(inVault: vaultRoot)
        if isLinked(vaultRoot: vaultRoot, transcriptsURL: transcriptsURL) { return link }

        let occupied = fileManager.fileExists(atPath: link.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil
        if occupied {
            var aside = vaultRoot.appending(path: "\(linkName) (old exports)")
            var counter = 2
            while fileManager.fileExists(atPath: aside.path) {
                aside = vaultRoot.appending(path: "\(linkName) (old exports \(counter))")
                counter += 1
            }
            try fileManager.moveItem(at: link, to: aside)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: transcriptsURL)
        return link
    }

    static func unlink(vaultRoot: URL, transcriptsURL: URL) throws {
        guard isLinked(vaultRoot: vaultRoot, transcriptsURL: transcriptsURL) else { return }
        try FileManager.default.removeItem(at: linkURL(inVault: vaultRoot))
    }

    // obsidian://open?vault=<vault name>&file=Meetings/<folder>/<note name>
    static func openURL(for record: TranscriptRecord, vaultRoot: URL) -> URL? {
        var file = linkName
        if let folder = record.folder {
            file += "/\(folder)"
        }
        file += "/\(record.markdownURL.deletingPathExtension().lastPathComponent)"

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultRoot.lastPathComponent),
            URLQueryItem(name: "file", value: file),
        ]
        return components.url
    }
}
