// Verify a complete Sparkle feed against the public key embedded in the app.
// This runs in CI without any private key or Keychain access.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3,
      let publicBytes = Data(base64Encoded: CommandLine.arguments[2]) else {
    fatalError("Usage: swift verify_sparkle.swift feed.xml PUBLIC_KEY")
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let text = String(decoding: data, as: UTF8.self)
let pattern = #"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$"#
let regex = try NSRegularExpression(pattern: pattern)
guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let signatureRange = Range(match.range(at: 1), in: text),
      let lengthRange = Range(match.range(at: 2), in: text),
      let blockRange = Range(match.range, in: text),
      let signature = Data(base64Encoded: String(text[signatureRange])),
      let length = Int(text[lengthRange]), length > 0, length <= data.count else {
    fatalError("Feed is missing a valid Sparkle signature block")
}
let prefixBytes = text[..<blockRange.lowerBound].utf8.count
guard prefixBytes == length else { fatalError("Feed contains unsigned content before its signature") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
guard key.isValidSignature(signature, for: data.prefix(length)) else {
    fatalError("Feed signature does not match the app public key")
}
print("Verified \(URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent) against the app public key")
