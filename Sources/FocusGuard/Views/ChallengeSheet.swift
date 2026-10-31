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

    private var matches: Bool { Challenge.matches(typed: typed, sentence: challenge.sentence) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type this sentence to continue").font(.headline)
            Text("This window uses the Friction unlock mode. Copying, pasting and autocorrect will not work; spaces and lowercase must match.")
                .font(.callout).foregroundStyle(.secondary)
            CaptchaText(sentence: challenge.sentence)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            TextField("Type here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onChange(of: typed) { old, new in
                    if new.count > old.count + 1 { typed = old }   // paste / drop / dictation burst
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
        .padding(20)
        .frame(width: 560)
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
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct CaptchaText: View {
    let sentence: String

    var body: some View {
        Canvas { ctx, size in
            var rng = JitterRNG(seed: sentence)
            let designs: [Font.Design] = [.serif, .rounded, .monospaced, .default]
            let lineHeight: CGFloat = 36
            var x: CGFloat = 14, y: CGFloat = 26
            let words = sentence.split(separator: " ").map(String.init)
            for (wi, word) in words.enumerated() {
                let wordWidth = CGFloat(word.count) * 13.5
                if x + wordWidth > size.width - 14 { x = 14; y += lineHeight }
                for ch in word {
                    let design = designs[Int(rng.next() % UInt64(designs.count))]
                    let weight: Font.Weight = rng.next() % 2 == 0 ? .semibold : .regular
                    let resolved = ctx.resolve(Text(String(ch)).font(.system(size: 22, weight: weight, design: design)))
                    let w = resolved.measure(in: CGSize(width: 60, height: 60)).width
                    let angle = Angle.degrees(Double(Int(rng.next() % 29)) - 14)
                    let dy = CGFloat(Int(rng.next() % 9)) - 4
                    ctx.drawLayer { layer in
                        layer.translateBy(x: x + w / 2, y: y + dy)
                        layer.rotate(by: angle)
                        layer.opacity = 0.75 + Double(rng.next() % 25) / 100
                        layer.draw(resolved, at: .zero, anchor: .center)
                    }
                    x += w + 1.5
                }
                if wi < words.count - 1 { x += 9 }
            }
            // Strike lines through the text band.
            for _ in 0..<7 {
                var p = Path()
                let y0 = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                let y1 = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                p.move(to: CGPoint(x: 0, y: y0))
                p.addQuadCurve(to: CGPoint(x: size.width, y: y1),
                               control: CGPoint(x: size.width / 2, y: CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))))
                ctx.stroke(p, with: .color(.primary.opacity(0.55)), lineWidth: 1.4)
            }
            // Speckle.
            for _ in 0..<350 {
                let px = CGFloat(Int(rng.next() % UInt64(max(Int(size.width), 1))))
                let py = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.5)))
            }
        }
        .accessibilityHidden(true)   // no accessible text to read out or copy
    }
}
