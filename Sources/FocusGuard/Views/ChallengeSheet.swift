import FocusGuardCore
import SwiftUI

/// Type-the-sentence gate. The sentence is drawn on a Canvas (not selectable, no text layer to
/// copy) with per-glyph jitter, mixed typefaces, strike lines and speckle so a screenshot is hard
/// to OCR. The field refuses any change that adds more than one character, so paste and drag do
/// nothing.
struct ChallengeSheet: View {
    let challenge: PendingChallenge
    let dismiss: () -> Void

    @State private var typed = ""
    @FocusState private var focused: Bool

    private static let width: CGFloat = 560
    private static let padding: CGFloat = 20
    private let captcha: CaptchaText

    init(challenge: PendingChallenge, dismiss: @escaping () -> Void) {
        self.challenge = challenge
        self.dismiss = dismiss
        captcha = CaptchaText(sentence: challenge.sentence, width: Self.width - 2 * Self.padding)
    }

    private var matches: Bool { Challenge.matches(typed: typed, sentence: challenge.sentence) }
    private var captchaHeight: CGFloat { max(80, CGFloat(captcha.lines) * CaptchaText.lineHeight + 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type this sentence to continue").font(.headline)
            Text("This window uses the Friction unlock mode. Copying, pasting and autocorrect will not work; spaces and lowercase must match.")
                .font(.callout).foregroundStyle(.secondary)
            Text("VoiceOver users: set the window's unlock mode to Basic.")
                .font(.caption).foregroundStyle(.secondary)
            captcha
                .frame(height: captchaHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            TextField("Type here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onChange(of: typed) { old, new in
                    if new.count > old.count + 1 {   // paste / drop / dictation burst
                        typed = old
                        NSApp.keyWindow?.undoManager?.removeAllActions()   // ⌘Z must not bring it back
                    }
                }
            HStack {
                Text(progress).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Unlock") { challenge.onSuccess(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .onAppear { focused = true }
    }

    private var progress: String {
        let ok = zip(typed, challenge.sentence).prefix { $0 == $1 }.count
        if matches { return "Matches." }
        if typed.isEmpty { return "\(challenge.sentence.count) characters" }
        return ok == typed.count ? "\(ok)/\(challenge.sentence.count) correct so far" : "Mismatch at character \(ok + 1)"
    }
}

/// Deterministic jitter so the drawing is stable across redraws (seeded from the sentence).
private struct JitterRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: String) { state = seed.unicodeScalars.reduce(0x9E3779B97F4A7C15) { ($0 &* 31) &+ UInt64($1.value) } }
    init(state: UInt64) { self.state = state }
    /// Uniform integer-valued offset in `0..<max(n, 1)`.
    mutating func below(_ n: CGFloat) -> CGFloat { CGFloat(Int(next() % UInt64(max(Int(n), 1)))) }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One drawn glyph: typeface, position and jitter decided up front so the line count is known
/// before the view is sized.
private struct CaptchaGlyph {
    let text: String
    let design: Font.Design
    let weight: Font.Weight
    let x: CGFloat
    let y: CGFloat
    let angle: Angle
    let opacity: Double
}

struct CaptchaText: View {
    static let lineHeight: CGFloat = 36
    static let fontSize: CGFloat = 22
    private static let inset: CGFloat = 14
    private static let designs: [Font.Design] = [.serif, .rounded, .monospaced, .default]

    let sentence: String
    let width: CGFloat
    /// Number of lines the sentence wraps to at `width`; the sheet sizes the frame from it.
    let lines: Int
    private let glyphs: [CaptchaGlyph]
    /// RNG state after the glyph pass, so the strike lines and speckle stay deterministic too.
    private let decorationSeed: UInt64

    init(sentence: String, width: CGFloat) {
        self.sentence = sentence
        self.width = width
        var rng = JitterRNG(seed: sentence)
        var glyphs: [CaptchaGlyph] = []
        var x = Self.inset, y: CGFloat = 26
        var lines = 1
        let words = sentence.split(separator: " ").map(String.init)
        for (wi, word) in words.enumerated() {
            // Decide each glyph's face first and measure it, then wrap on the real width.
            let faces = word.map { ch -> (String, Font.Design, Font.Weight, CGFloat) in
                let design = Self.designs[Int(rng.next() % UInt64(Self.designs.count))]
                let weight: Font.Weight = rng.next() % 2 == 0 ? .semibold : .regular
                return (String(ch), design, weight, Self.measure(String(ch), design: design, weight: weight))
            }
            let wordWidth = faces.reduce(0) { $0 + $1.3 + 1.5 }
            if x > Self.inset, x + wordWidth > width - Self.inset { x = Self.inset; y += Self.lineHeight; lines += 1 }
            for (text, design, weight, w) in faces {
                let angle = Angle.degrees(Double(rng.below(29)) - 14)
                let dy = rng.below(9) - 4
                let opacity = 0.75 + Double(rng.below(25)) / 100
                glyphs.append(CaptchaGlyph(text: text, design: design, weight: weight,
                                           x: x + w / 2, y: y + dy, angle: angle, opacity: opacity))
                x += w + 1.5
            }
            if wi < words.count - 1 { x += 9 }
        }
        self.glyphs = glyphs
        self.lines = lines
        decorationSeed = rng.state
    }

    var body: some View {
        Canvas { ctx, size in
            for g in glyphs {
                let resolved = ctx.resolve(Text(g.text).font(.system(size: Self.fontSize, weight: g.weight, design: g.design)))
                ctx.drawLayer { layer in
                    layer.translateBy(x: g.x, y: g.y)
                    layer.rotate(by: g.angle)
                    layer.opacity = g.opacity
                    layer.draw(resolved, at: .zero, anchor: .center)
                }
            }
            var rng = JitterRNG(state: decorationSeed)
            // Strike lines through the text band.
            for _ in 0..<7 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: rng.below(size.height)))
                let end = CGPoint(x: size.width, y: rng.below(size.height))
                p.addQuadCurve(to: end, control: CGPoint(x: size.width / 2, y: rng.below(size.height)))
                ctx.stroke(p, with: .color(.primary.opacity(0.55)), lineWidth: 1.4)
            }
            // Speckle.
            for _ in 0..<350 {
                let px = rng.below(size.width), py = rng.below(size.height)
                ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.5)))
            }
        }
        .accessibilityHidden(true)   // no accessible text to read out or copy
    }

    /// Width of one glyph in the same system face SwiftUI resolves for `.system(size:weight:design:)`.
    private static func measure(_ text: String, design: Font.Design, weight: Font.Weight) -> CGFloat {
        let base = NSFont.systemFont(ofSize: fontSize, weight: weight == .semibold ? .semibold : .regular)
        let nsDesign: NSFontDescriptor.SystemDesign = switch design {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: .default
        }
        let font = base.fontDescriptor.withDesign(nsDesign).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
