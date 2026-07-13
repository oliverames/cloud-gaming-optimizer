import Foundation

enum DiagnosticsPrivacy {
    static func targetDescription(
        selectedTargetID: String?,
        customTargetIDs: Set<String>
    ) -> String {
        guard let selectedTargetID, !selectedTargetID.isEmpty else {
            return "not selected"
        }
        return customTargetIDs.contains(selectedTargetID.lowercased())
            ? "custom (redacted)"
            : "built-in"
    }
}
