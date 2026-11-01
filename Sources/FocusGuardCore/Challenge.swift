import Foundation

/// The Friction unlock: a random sentence the user must type word for word (spec §10.4).
public enum Challenge {
    public static let defaultWordCount = 10

    /// Common, easy-to-type words (3–8 letters, lowercase). Spellings that differ between US and
    /// Canadian/UK English are left out so the sentence has exactly one correct typing.
    public static let words: [String] = """
    about above across after again against along among animal answer around arrive basket beach \
    before begin behind below beside better between beyond bottle branch bread bridge bright broken \
    brother butter button camera candle carpet castle cattle chance change cheese circle \
    class clock cloud coffee corner cotton count country cousin cover crowd dance danger \
    daughter decide desert dinner doctor dollar double dragon dream dress drink early earth eight \
    either empty enemy engine enough evening every expect family famous farmer father field fight \
    figure finger finish flower follow forest forget forward friend front fruit future garden gather \
    gentle giant glass golden grass green ground guard guess hammer happen heavy hidden \
    history honey horse hotel hundred hunger hurry island jacket journey jungle kitchen ladder \
    language large laugh leader learn leather letter level light listen little lonely machine magic \
    manner marble market master matter meadow member memory metal middle minute mirror modern \
    moment money monkey morning mother mountain music narrow nation nature needle never night \
    noise north notice number object ocean office orange order other paint palace paper parent \
    pattern pencil people pepper person picture pillow planet plant pocket point police potato \
    powder power pretty prince prison pupil puzzle quarter question quick quiet rabbit rather reach \
    reason record remain repeat rescue return ribbon river rocket round saddle salad school second \
    secret seven shadow shelter shout signal silent silver simple single sister sleep smile smoke \
    soldier south speak spider spring square stone story stream street strong sudden sugar summer \
    supper table teacher temple thick thirty thread throat thunder ticket timber tomato tongue \
    tower travel treasure trouble turtle twelve twenty uncle under until valley velvet village \
    voice wagon watch water weather wheel whisper window winter wonder wooden yellow young
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    /// `wordCount` (> 0) words drawn with replacement from `words`, joined by single spaces.
    public static func sentence(wordCount: Int = defaultWordCount, using rng: inout some RandomNumberGenerator) -> String {
        precondition(wordCount > 0, "a challenge sentence needs at least one word")
        return (0..<wordCount).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
    }

    /// Convenience with the system generator.
    public static func sentence(wordCount: Int = defaultWordCount) -> String {
        var rng = SystemRandomNumberGenerator()
        return sentence(wordCount: wordCount, using: &rng)
    }

    /// Exact match after trimming leading/trailing whitespace and newlines. Case and internal
    /// spacing must match.
    public static func matches(typed: String, sentence: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == sentence
    }
}
