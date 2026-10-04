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
}
