import Foundation
import WebKit
import AnkiNotchKit

/// Serves `ankinotch-media://collection/<name>` from Anki's media folder.
/// Responses are real HTTP (status, Content-Type, Content-Length): card
/// scripts that `fetch` media would read a status-less response as "HTTP 0".
@MainActor
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Set before each card is shown; nil means every request 404s.
    var mediaDir: String?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let mediaDir,
              let fileURL = MediaFiles.fileURL(for: url, mediaDir: mediaDir),
              let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: url, status: 404, contentType: "text/plain", body: Data())
            return
        }
        respond(task, url: url, status: 200,
                contentType: MediaFiles.mimeType(for: fileURL), body: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int,
                         contentType: String, body: Data) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"])
        else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
