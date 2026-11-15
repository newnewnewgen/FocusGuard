import Foundation

/// The Friction unlock: a run of random letters the user must type exactly (spec §10.4).
///
/// Letters, not words, and no spaces: a sentence of real words can be read in one glance and
/// typed from memory in chunks, which made Friction a speed bump of a few seconds. A meaningless
/// run has to be copied letter by letter from the drawing, with nothing to predict the next
/// character from, and no word gaps to pace it. 40 letters is about 25–40 s of careful typing.
public enum Challenge {
    public static let defaultLength = 40

    /// Lowercase ASCII letters without `l`, which the drawn, mixed-typeface glyphs can make look
    /// like `i` or `1`; every remaining letter is distinct at a glance in every face used.
    public static let alphabet: [Character] = Array("abcdefghijkmnopqrstuvwxyz")

    /// `length` (> 0) letters drawn with replacement from `alphabet`, with no separators.
    public static func sentence(length: Int = defaultLength, using rng: inout some RandomNumberGenerator) -> String {
        precondition(length > 0, "a challenge needs at least one letter")
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Convenience with the system generator.
    public static func sentence(length: Int = defaultLength) -> String {
        var rng = SystemRandomNumberGenerator()
        return sentence(length: length, using: &rng)
    }

    /// Exact match after trimming leading/trailing whitespace and newlines. Case and internal
    /// spacing must match.
    public static func matches(typed: String, sentence: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == sentence
    }

    /// True when `new` could have come from `old` by one keystroke: any range deleted (backspace,
    /// or typing over a selection) and at most one character put in its place. Paste, drag-and-drop
    /// and dictation insert several characters at once and fail this, including pasting over a
    /// selection of the same length, which a simple "did it grow by more than one" check lets by.
    public static func isSingleKeystroke(from old: String, to new: String) -> Bool {
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        return n.count - prefix - suffix <= 1
    }
}
