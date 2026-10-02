import Testing
@testable import AnkiNotchKit

@Suite struct CardDocumentTests {
    @Test func wrapsCardInAnkisReviewerDOM() {
        let html = CardDocument.html(side: "<b>hi</b>", css: ".x{}")
        #expect(html.contains(#"<body class="card isMac"><div id="qa"><b>hi</b></div>"#))
        #expect(html.contains("<style>.x{}</style>"))
    }

    @Test func stripsSoundAndPlayMarkers() {
        let stripped = CardDocument.stripAudioMarkers(
            "a [sound:x.mp3] b [anki:play:q:0] c [anki:play:a:1]")
        #expect(stripped == "a  b  c ")
    }

    @Test func stripsTTSBlocksIncludingTheirText() {
        let stripped = CardDocument.stripAudioMarkers(
            "x [anki:tts lang=ja_JP]こんにちは[/anki:tts] y")
        #expect(stripped == "x  y")
        let multiline = CardDocument.stripAudioMarkers(
            "x [anki:tts lang=en_US]one\ntwo[/anki:tts] y")
        #expect(multiline == "x  y")
    }

    @Test func leavesOrdinaryBracketsAlone() {
        #expect(CardDocument.stripAudioMarkers("[1] and [note]") == "[1] and [note]")
    }

    @Test func htmlStripsMarkersItself() {
        let html = CardDocument.html(side: "word [sound:w.mp3]", css: "")
        #expect(!html.contains("[sound:"))
        #expect(html.contains("word "))
    }
}
