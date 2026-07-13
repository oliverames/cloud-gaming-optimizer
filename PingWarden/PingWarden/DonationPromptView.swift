//
//  DonationPromptView.swift
//  PingWarden
//
//  Contextual sheet that asks for support after Ping Warden has demonstrated
//  value. Eligibility lives in SupportPromptPolicy so it stays testable.
//

import SwiftUI

struct DonationPromptView: View {
    static let donationURL = URL(string: "https://buymeacoffee.com/oliverames")!
    static let contentSize = CGSize(width: 420, height: 520)

    let onSupport: () -> Void
    let onMaybeLater: () -> Void
    let onDontAskAgain: () -> Void
    var completedSessionCount: Int = 0
    var lifetimeInterventionCount: Int = 0

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: heroIconSize, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .padding(.top, 28)

            VStack(spacing: 12) {
                Text("Enjoying Ping Warden?")
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
                    Label("Support Ping Warden", systemImage: "cup.and.saucer")
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
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private var messageBody: String {
        let proof: String
        if lifetimeInterventionCount > 0 {
            let noun = lifetimeInterventionCount == 1 ? "interruption" : "interruptions"
            proof = "The helper has recorded \(lifetimeInterventionCount) wireless \(noun) on this Mac."
        } else if completedSessionCount > 0 {
            let noun = completedSessionCount == 1 ? "session" : "sessions"
            proof = "You have completed \(completedSessionCount) protected \(noun) on this Mac."
        } else {
            proof = "You have been using Ping Warden."
        }

        return """
        \(proof)

        If you find it useful, you can support the next release.

        Ping Warden stays free either way.
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
