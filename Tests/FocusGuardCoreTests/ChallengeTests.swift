import XCTest
@testable import FocusGuardCore

/// Deterministic generator so sentences are reproducible in tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ChallengeTests: XCTestCase {
    func testSentenceHasRequestedWordCountFromWordList() {
        var rng = SeededRNG(state: 1)
        let s = Challenge.sentence(wordCount: 10, using: &rng)
        let words = s.split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, 10)
        XCTAssertTrue(words.allSatisfy { Challenge.words.contains($0) }, s)
    }

    func testSentenceIsDeterministicForSeedAndVariesAcrossSeeds() {
        var a = SeededRNG(state: 7), b = SeededRNG(state: 7), c = SeededRNG(state: 8)
        XCTAssertEqual(Challenge.sentence(wordCount: 8, using: &a), Challenge.sentence(wordCount: 8, using: &b))
        var a2 = SeededRNG(state: 7)
        XCTAssertNotEqual(Challenge.sentence(wordCount: 8, using: &a2), Challenge.sentence(wordCount: 8, using: &c))
    }

    func testWordListIsLargeLowercaseAndUnique() {
        XCTAssertGreaterThanOrEqual(Challenge.words.count, 200)
        XCTAssertEqual(Set(Challenge.words).count, Challenge.words.count)
        XCTAssertTrue(Challenge.words.allSatisfy { $0 == $0.lowercased() && $0.count >= 3 && $0.count <= 8 })
    }

    func testWordListAvoidsUSUKDivergentSpellings() {
        let divergent: Set<String> = ["color", "colour", "center", "centre", "harbor", "harbour", "favor", "favour",
                                      "flavor", "flavour", "gray", "grey", "honor", "honour", "labor", "labour",
                                      "neighbor", "neighbour", "meter", "metre", "theater", "theatre"]
        XCTAssertTrue(divergent.isDisjoint(with: Challenge.words), "\(divergent.intersection(Challenge.words))")
    }

    func testMatchesIsExactExceptSurroundingWhitespace() {
        XCTAssertTrue(Challenge.matches(typed: "river stone clock", sentence: "river stone clock"))
        XCTAssertTrue(Challenge.matches(typed: " river stone clock \n", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "River stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river  stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river stone", sentence: "river stone clock"))
    }
}
