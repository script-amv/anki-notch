import Foundation
import UniformTypeIdentifiers

/// WebKit-free helpers behind the card view's media scheme handler: a request
/// like `ankinotch-media://collection/foo.jpg` resolves to a file inside Anki's
/// `collection.media` folder (the path from `getMediaDirPath`).
public enum MediaFiles {
    /// Resolve a media request to a file inside `mediaDir`, or nil if the
    /// request escapes it. Anki media filenames are flat (no subdirectories),
    /// so anything that isn't a plain filename is rejected.
    public static func fileURL(for requestURL: URL, mediaDir: String) -> URL? {
        let components = requestURL.path.split(separator: "/")
        guard components.count == 1, let name = components.first.map(String.init),
              name != ".", name != ".." else { return nil }
        let base = URL(fileURLWithPath: mediaDir, isDirectory: true)
        let file = base.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(base.standardizedFileURL.path + "/") else { return nil }
        return file
    }

    public static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
