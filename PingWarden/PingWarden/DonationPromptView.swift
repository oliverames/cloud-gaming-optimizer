//
//  DonationPromptView.swift
//  PingWarden
//
//  One-shot sheet that asks the user to chip in via Buy Me a Coffee.
//  Surfaced on first launch and once per minor version after that; the
//  decision lives in `VersionPromptPolicy` so it's exercised by the test
//  suite, not buried in view code.
//

import SwiftUI

struct DonationPromptView: View {
    static let donationURL = URL(string: "https://www.buymeacoffee.com/oliverames")!

    let onSupport: () -> Void
    let onMaybeLater: () -> Void
    let onDontAskAgain: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 28)

            VStack(spacing: 12) {
                Text("Like Ping Warden?")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(messageBody)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                Button {
                    onSupport()
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Maybe later") {
                    onMaybeLater()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.cancelAction)

                Button("Don't ask again") {
                    onDontAskAgain()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    /// First-person ask in plain language. No em dashes, no corporate
    /// register, no guilt-trip. The "no pressure" close is load-bearing —
    /// without it the rest reads as cornering the user.
    private var messageBody: String {
        """
        Ping Warden is a one-person side project. I work on it around a full-time job and a young family, and I keep at it because you're using it.

        If it has saved your evening once or twice, a few bucks at the coffee link helps me justify the next feature instead of guiltily glancing at my todo list at 11pm.

        No pressure. It's free either way.
        """
    }
}

#Preview("Donation Prompt") {
    DonationPromptView(
        onSupport: {},
        onMaybeLater: {},
        onDontAskAgain: {}
    )
}
