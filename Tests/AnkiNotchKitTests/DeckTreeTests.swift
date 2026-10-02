import Testing
@testable import AnkiNotchKit

@Suite struct DeckTreeTests {
    @Test func flatNamesBecomeSortedRoots() {
        let tree = DeckTree.build(from: ["Zeta", "alpha", "Beta"])
        #expect(tree.map(\.name) == ["alpha", "Beta", "Zeta"])
        #expect(tree.map(\.path) == ["alpha", "Beta", "Zeta"])
        #expect(tree.allSatisfy { $0.children.isEmpty })
    }

    @Test func nestsByDoubleColon() {
        let tree = DeckTree.build(from: [
            "Languages", "Languages::Japanese", "Languages::Japanese::Core", "Languages::French",
        ])
        #expect(tree.count == 1)
        let languages = tree[0]
        #expect(languages.path == "Languages")
        #expect(languages.children.map(\.name) == ["French", "Japanese"])
        let japanese = languages.children[1]
        #expect(japanese.path == "Languages::Japanese")
        #expect(japanese.children.map(\.path) == ["Languages::Japanese::Core"])
        #expect(japanese.children[0].name == "Core")
    }

    @Test func missingParentsAreSynthesised() {
        let tree = DeckTree.build(from: ["A::B::C"])
        #expect(tree.map(\.path) == ["A"])
        #expect(tree[0].children.map(\.path) == ["A::B"])
        #expect(tree[0].children[0].children.map(\.path) == ["A::B::C"])
    }

    @Test func duplicatesAreMergedAndEmptyInputGivesNoRoots() {
        #expect(DeckTree.build(from: ["A", "A", "A::B", "A::B"]).count == 1)
        #expect(DeckTree.build(from: []).isEmpty)
    }

    @Test func numbersSortNaturally() {
        let tree = DeckTree.build(from: ["Unit 10", "Unit 2"])
        #expect(tree.map(\.name) == ["Unit 2", "Unit 10"])
    }
}
