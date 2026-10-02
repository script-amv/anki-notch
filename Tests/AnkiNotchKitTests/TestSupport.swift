import Foundation
@testable import AnkiNotchKit

func makeCard(_ id: Int64, deck: String = "A", buttons: [Int] = [1, 2, 3, 4]) -> CurrentCard {
    CurrentCard(cardId: id, question: "Q\(id)", answer: "Q\(id)<hr id=answer>A\(id)",
                css: "", buttons: buttons, deckName: deck)
}
