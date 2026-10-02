import Foundation
import Testing
@testable import AnkiNotchKit

@Suite struct MediaFilesTests {
    private func url(_ path: String) -> URL { URL(string: "ankinotch-media://collection\(path)")! }

    @Test func plainFilenameResolvesInsideMediaDir() {
        #expect(MediaFiles.fileURL(for: url("/foo.jpg"), mediaDir: "/tmp/m")
                == URL(fileURLWithPath: "/tmp/m/foo.jpg"))
        #expect(MediaFiles.fileURL(for: url("/%E6%97%A5.png"), mediaDir: "/tmp/m")
                == URL(fileURLWithPath: "/tmp/m/日.png"))
    }

    @Test func traversalIsRejected() {
        for path in ["/../etc/passwd", "/a/b.png", "/", "/%2E%2E", "/.."] {
            #expect(MediaFiles.fileURL(for: url(path), mediaDir: "/tmp/m") == nil, "\(path)")
        }
    }

    @Test func mimeTypesForCommonImages() {
        #expect(MediaFiles.mimeType(for: URL(fileURLWithPath: "/m/a.png")) == "image/png")
        #expect(MediaFiles.mimeType(for: URL(fileURLWithPath: "/m/a.jpg")) == "image/jpeg")
        #expect(MediaFiles.mimeType(for: URL(fileURLWithPath: "/m/a.unknownext"))
                == "application/octet-stream")
    }
}
