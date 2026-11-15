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
    func testSentenceHasRequestedLengthFromAlphabetWithNoSpaces() {
        var rng = SeededRNG(state: 1)
        let s = Challenge.sentence(length: 40, using: &rng)
        XCTAssertEqual(s.count, 40)
        XCTAssertFalse(s.contains(" "), "no chunks to type from memory")
        XCTAssertTrue(s.allSatisfy { Challenge.alphabet.contains($0) }, s)
        XCTAssertEqual(Challenge.sentence().count, Challenge.defaultLength)
    }

    func testSentenceIsDeterministicForSeedAndVariesAcrossSeeds() {
        var a = SeededRNG(state: 7), b = SeededRNG(state: 7), c = SeededRNG(state: 8)
        XCTAssertEqual(Challenge.sentence(length: 8, using: &a), Challenge.sentence(length: 8, using: &b))
        var a2 = SeededRNG(state: 7)
        XCTAssertNotEqual(Challenge.sentence(length: 8, using: &a2), Challenge.sentence(length: 8, using: &c))
    }

    func testAlphabetIsLowercaseUniqueAndDropsTheAmbiguousL() {
        XCTAssertEqual(Set(Challenge.alphabet).count, Challenge.alphabet.count)
        XCTAssertTrue(Challenge.alphabet.allSatisfy { $0.isLowercase && $0.isASCII && $0.isLetter })
        XCTAssertFalse(Challenge.alphabet.contains("l"))
        XCTAssertEqual(Challenge.alphabet.count, 25)
    }

    func testMatchesIsExactExceptSurroundingWhitespace() {
        XCTAssertTrue(Challenge.matches(typed: "river stone clock", sentence: "river stone clock"))
        XCTAssertTrue(Challenge.matches(typed: " river stone clock \n", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "River stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river  stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river stone", sentence: "river stone clock"))
    }
}
