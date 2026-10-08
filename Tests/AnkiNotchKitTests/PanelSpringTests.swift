import CoreGraphics
import Testing
@testable import AnkiNotchKit

@Suite struct PanelSpringTests {
    private let notch = CGSize(width: 200, height: 32)
    private let card = CGSize(width: 480, height: 300)
    private let limits = CGSize(width: 544, height: 982)

    @Test func expansionOvershootsAndSettlesExactly() {
        let sizes = PanelSpring.sizes(from: notch, to: card, maximumSize: limits)
        #expect(sizes.first == notch)
        #expect(sizes.last == card)
        #expect(sizes.contains { $0.width > 480 && $0.height > 300 })
    }

    @Test func collapseUndershootsAndSettlesExactly() {
        let sizes = PanelSpring.sizes(from: card, to: notch, maximumSize: limits)
        #expect(sizes.first == card)
        #expect(sizes.last == notch)
        #expect(sizes.contains { $0.width < 200 && $0.height < 32 })
    }

    @Test func tallCardsAndCollapseNeverLeaveTheStageOrGoNegative() {
        let tall = CGSize(width: 480, height: 982)
        for (from, to) in [(notch, tall), (tall, notch)] {
            let sizes = PanelSpring.sizes(from: from, to: to, maximumSize: limits)
            #expect(sizes.allSatisfy {
                $0.width > 0 && $0.width <= 544 && $0.height > 0 && $0.height <= 982
            })
            #expect(sizes.last == to)
        }
    }

    @Test func reversalStartsAtTheCurrentShape() {
        let opening = PanelSpring.sizes(from: notch, to: card, maximumSize: limits)
        let current = opening[opening.count / 3]
        let closing = PanelSpring.sizes(from: current, to: notch, maximumSize: limits)
        #expect(closing.first == current)
        let reversed = closing[closing.count / 3]
        let reopening = PanelSpring.sizes(from: reversed, to: card, maximumSize: limits)
        #expect(reopening.first == reversed)
        #expect(reopening.last == card)
    }
}
