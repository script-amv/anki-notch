import Foundation

/// Builds the HTML document one card side is shown in.
public enum CardDocument {
    /// The custom scheme the card view registers; documents load with
    /// `baseURL` so relative `src` attributes route to the media handler.
    public static let scheme = "ankinotch-media"
    public static let baseURL = URL(string: "\(scheme)://collection/")!

    /// Wrap one card side in a document matching Anki's reviewer DOM: the card
    /// HTML inside `<div id="qa">`, a direct child of `<body class="card isMac">`.
    /// Note-type CSS routinely depends on exactly this shape (e.g.
    /// `.card:has(> #qa)`), and on Anki's `nightMode` / `night_mode` body
    /// classes for dark themes, mirrored here from the system colour scheme.
    ///
    /// The `body.nightMode` rule is lifted from Anki's own `reviewer.css`: it is
    /// how Anki darkens note types that never heard of night mode (the stock
    /// template says `.card { color: black; background-color: white }`, and
    /// `body.nightMode` outranks that on specificity alone).
    public static func html(side: String, css: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --canvas: #f5f5f5; --fg: #020202; }
        :root.night-mode { --canvas: #2c2c2c; --fg: #fcfcfc; }
        body { margin: 0; }
        body.nightMode { background-color: var(--canvas); color: var(--fg); }
        </style>
        <style>\(css)</style>
        </head>
        <body class="card isMac"><div id="qa">\(stripAudioMarkers(side))</div>
        <script>
        (function () {
          const mq = matchMedia("(prefers-color-scheme: dark)");
          const apply = () => {
            document.body.classList.toggle("nightMode", mq.matches);
            document.body.classList.toggle("night_mode", mq.matches);
            document.documentElement.classList.toggle("night-mode", mq.matches);
          };
          apply();
          mq.addEventListener("change", apply);
        })();
        </script>
        </body>
        </html>
        """
    }

    /// AnkiNotch plays no audio, so Anki's markers would only show as stray
    /// text: `[sound:file]`, `[anki:play:q:0]`, and TTS blocks, text included.
    public static func stripAudioMarkers(_ html: String) -> String {
        let patterns = [
            #"(?s)\[anki:tts[^\]]*\].*?\[/anki:tts\]"#,
            #"\[sound:[^\]]*\]"#,
            #"\[anki:play:[^\]]*\]"#,
        ]
        return patterns.reduce(html) {
            $0.replacingOccurrences(of: $1, with: "", options: .regularExpression)
        }
    }
}
