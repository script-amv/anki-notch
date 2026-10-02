import Testing
@testable import AnkiNotchKit

@Suite struct DeckRouteTests {
    @Test func splitsOnDoubleColon() {
        #expect(DeckRoute.components(of: "Languages::Japanese::Core")
                == ["Languages", "Japanese", "Core"])
    }

    @Test func trimsWhitespaceAndDropsEmptyComponents() {
        #expect(DeckRoute.components(of: " A :: ::B::") == ["A", "B"])
        #expect(DeckRoute.components(of: "") == [])
        #expect(DeckRoute.components(of: "::") == [])
    }

    @Test func singleComponentIsItsOnlyCandidate() {
        #expect(DeckRoute.candidates(for: "Sample") == ["Sample"])
    }

    @Test func emptyNameHasNoCandidates() {
        #expect(DeckRoute.candidates(for: "") == [])
    }

    @Test func twoComponentsOfferFullThenLeafOnly() {
        #expect(DeckRoute.candidates(for: "Languages::Japanese")
                == ["Languages › Japanese", "… › Japanese"])
    }

    @Test func deepPathsShrinkFromTheMiddle() {
        #expect(DeckRoute.candidates(for: "A::B::C::D")
                == ["A › B › C › D", "A › … › D", "… › D"])
    }

    @Test func threeComponentsHaveNoDuplicateMiddleForm() {
        #expect(DeckRoute.candidates(for: "A::B::C")
                == ["A › B › C", "A › … › C", "… › C"])
    }
}
