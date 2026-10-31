// ChallengeSheet.swift
import SwiftUI
struct ChallengeSheet: View {
    let challenge: PendingChallenge
    let dismiss: () -> Void
    var body: some View { Button("Dismiss", action: dismiss).padding() }
}
