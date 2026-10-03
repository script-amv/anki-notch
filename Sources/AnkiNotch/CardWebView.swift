import AppKit
import WebKit
import AnkiNotchKit

/// Shows one card side and nothing else. JavaScript is on (note types use
/// it), the data store is non-persistent, and the only native bridge is a
/// one-way `cardHeight` message so the panel can size itself to the card.
@MainActor
final class CardWebView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    /// Called with the card's content height whenever it changes, including
    /// after images load or a note-type script finishes rendering.
    var onContentHeight: ((CGFloat) -> Void)?

    private let webView: WKWebView
    private let mediaHandler = MediaSchemeHandler()
    /// A freeze-frame of the previous document, shown while the next one
    /// loads, so swapping sides never flashes the backing colour.
    private let snapshotView = NSImageView()
    private var loadedDocument: String?
    /// The last height the page reported, replayed when an unchanged document
    /// is shown again (the page itself only reports changes).
    private var contentHeight: CGFloat = 0

    /// Reports the card's content height whenever it changes. It measures our
    /// own `#qa` wrapper, never `document.body`: a note type that sets
    /// `.card { display: unset }` (the body carries the `card` class) makes the
    /// body an inline element, and an inline body has `scrollHeight` 0 and no
    /// ResizeObserver events, so the panel would never size to such a card.
    /// `scrollHeight` on `#qa` includes descendants overflowing it, and neither
    /// number depends on the view's own height, so the page can shrink as well
    /// as grow. Layout that settles late (fonts, images, stylesheets, note-type
    /// scripts) is caught by the observers and a few delayed re-measures.
    private static let heightScript = """
    (function () {
      let last = 0;
      const qa = document.getElementById("qa") || document.body;
      const measure = () => {
        const rect = qa.getBoundingClientRect();
        return Math.ceil(Math.max(qa.scrollHeight, rect.bottom + window.scrollY));
      };
      const post = () => {
        const h = measure();
        if (h > 0 && h !== last) {
          last = h;
          window.webkit.messageHandlers.cardHeight.postMessage(h);
        }
      };
      new ResizeObserver(post).observe(qa);
      new MutationObserver(post).observe(qa, { childList: true, subtree: true,
                                               attributes: true, characterData: true });
      document.addEventListener("transitionend", post, true);
      window.addEventListener("load", post);
      [100, 300, 800, 2000].forEach((ms) => setTimeout(post, ms));
      post();
    })();
    """

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(mediaHandler, forURLScheme: CardDocument.scheme)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: .zero)

        // WKUserContentController retains its handlers; a weak proxy keeps
        // this view out of that cycle.
        config.userContentController.add(WeakMessageHandler(self), name: "cardHeight")
        webView.navigationDelegate = self
        for subview in [webView, snapshotView] {
            subview.frame = bounds
            subview.autoresizingMask = [.width, .height]
            addSubview(subview)
        }
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Spin up WebKit's content process before the first hover: loading the
    /// first card cold stalls the main thread for a moment, which would make
    /// the panel's opening animation hitch. Deliberately leaves the document
    /// bookkeeping alone, so the first real card still takes the plain
    /// first-load path.
    func warmUp() {
        webView.loadHTMLString("", baseURL: nil)
    }

    func show(html: String, css: String, mediaDir: String?, forceBlackBackground: Bool) {
        mediaHandler.mediaDir = mediaDir
        let document = CardDocument.html(side: html, css: css,
                                         forceBlackBackground: forceBlackBackground)
        guard document != loadedDocument else {
            if contentHeight > 0 { onContentHeight?(contentHeight) }
            return
        }
        let isFirstLoad = loadedDocument == nil
        loadedDocument = document
        if isFirstLoad {
            webView.loadHTMLString(document, baseURL: CardDocument.baseURL)
            return
        }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let image {
                    self.snapshotView.image = image
                    self.snapshotView.isHidden = false
                }
                // Always load the newest document: a later call may have
                // landed while the snapshot was being taken.
                if let latest = self.loadedDocument {
                    self.webView.loadHTMLString(latest, baseURL: CardDocument.baseURL)
                }
            }
        }
    }

    // MARK: WKScriptMessageHandler / WKNavigationDelegate

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "cardHeight", let height = message.body as? NSNumber else { return }
        contentHeight = CGFloat(truncating: height)
        onContentHeight?(contentHeight)
    }

    /// The new document has rendered; give it a frame to paint, then drop the
    /// freeze-frame of the previous side.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.snapshotView.isHidden = true
                self?.snapshotView.image = nil
            }
        }
    }

    /// Only the card document itself may load; links on a card do nothing.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction)
        async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        return url.scheme == CardDocument.scheme || url.absoluteString == "about:blank"
            ? .allow : .cancel
    }
}

/// Keeps the web view's content controller from retaining the card view.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
