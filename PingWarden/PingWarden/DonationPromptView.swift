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
    static let contentSize = CGSize(width: 440, height: 340)

    let onSupport: () -> Void
    let onMaybeLater: () -> Void
    let onDontAskAgain: () -> Void
    var completedSessionCount: Int = 0
    var lifetimeInterventionCount: Int = 0

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: heroIconSize, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                VStack(spacing: 10) {
                    Text("Enjoying Ping Warden?")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(spacing: 8) {
                        Text(proofText)
                        Text("If you find it useful, you can help fund the next release.")
                        Text("Ping Warden stays free either way.")
                    }
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                }
                .padding(.top, 16)
                .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    Button {
                        onSupport()
                    } label: {
                        Label("Donate to Ping Warden", systemImage: "cup.and.saucer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        onMaybeLater()
                    } label: {
                        Text("Maybe later")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)

                    Button("Don't ask again") {
                        onDontAskAgain()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 22)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private var proofText: String {
        if lifetimeInterventionCount > 0 {
            let noun = lifetimeInterventionCount == 1 ? "interruption" : "interruptions"
            return "The helper has recorded \(lifetimeInterventionCount) wireless \(noun) on this Mac."
        } else if completedSessionCount > 0 {
            let noun = completedSessionCount == 1 ? "session" : "sessions"
            return "You have completed \(completedSessionCount) latency \(noun) on this Mac."
        } else {
            return "You have been using Ping Warden."
        }
    }
}

#Preview("Donation Prompt") {
    DonationPromptView(
        onSupport: {},
        onMaybeLater: {},
        onDontAskAgain: {}
    )
}
