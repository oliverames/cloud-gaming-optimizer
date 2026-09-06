//
//  GameModeActivationPolicy.swift
//  PingWarden
//
//  Pure decision logic for Game Mode auto-detect. A game can be noticed two
//  ways: the frontmost app declares itself a game, or a game owns a
//  fullscreen window. The first needs no permission; the second needs Screen
//  Recording. Either is enough. Engagement is then gated on the network path,
//  because AWDL shares the Wi-Fi radio and cannot disturb a wired connection.
//

import Foundation

enum GameModeActivationPolicy {
    /// Coarse view of the primary network path.
    enum PathInterface: Equatable {
        case wifi
        case wired
        case other
        case unknown
    }

    /// A game is present when either observation path sees one.
    static func gamePresent(frontmostIsGame: Bool, fullscreenGamePresent: Bool) -> Bool {
        frontmostIsGame || fullscreenGamePresent
    }

    /// A wired path skips engagement. An unknown or other path fails toward
    /// protection, since a wrong "no" costs the user a stuttering session and
    /// a wrong "yes" only costs them AirDrop until the game closes.
    static func shouldEngage(gamePresent: Bool, pathInterface: PathInterface) -> Bool {
        guard gamePresent else { return false }
        return pathInterface != .wired
    }

    static func shouldEngage(
        frontmostIsGame: Bool,
        fullscreenGamePresent: Bool,
        pathInterface: PathInterface
    ) -> Bool {
        shouldEngage(
            gamePresent: gamePresent(
                frontmostIsGame: frontmostIsGame,
                fullscreenGamePresent: fullscreenGamePresent
            ),
            pathInterface: pathInterface
        )
    }
}
