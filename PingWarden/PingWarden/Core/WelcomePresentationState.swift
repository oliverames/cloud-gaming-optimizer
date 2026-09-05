// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

import Foundation

/// Keeps the optional introduction separate from privileged-helper setup.
/// Explicit setup actions can still present the welcome after this marker is set.
public struct WelcomePresentationState {
    private let defaults: UserDefaults
    private let presentedKey = "WelcomeHasBeenPresented"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func shouldPresentAutomatically(helperIsRegistered: Bool) -> Bool {
        !helperIsRegistered && !defaults.bool(forKey: presentedKey)
    }

    public func markPresented() {
        defaults.set(true, forKey: presentedKey)
    }
}
