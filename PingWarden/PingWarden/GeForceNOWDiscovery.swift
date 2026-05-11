//
//  GeForceNOWDiscovery.swift
//  PingWarden
//
//  Asynchronously discovers GeForce NOW datacenter zones from the public
//  status API and returns them as PingTarget entries the dashboard can probe.
//

import Foundation

enum GeForceNOWDiscovery {
    private static let endpoint = URL(string: "https://status.geforcenow.com/api/v2/components.json")
    private static let zoneCodePattern = #"\bNP[A]?-[A-Z0-9-]+\b"#

    private struct ComponentsResponse: Decodable {
        let components: [Component]
    }

    private struct Component: Decodable {
        let name: String
    }

    static func fetchTargets() async -> [PingTarget] {
        guard let endpoint else { return [] }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            let payload = try JSONDecoder().decode(ComponentsResponse.self, from: data)
            let codes = extractZoneCodes(from: payload.components.map(\.name))

            return codes.sorted().map { code in
                PingTarget(
                    displayName: "GeForce NOW (\(code))",
                    host: "\(code.lowercased()).cloudmatchbeta.nvidiagrid.net",
                    port: 443,
                    source: .geforceNow
                )
            }
        } catch {
            return []
        }
    }

    private static func extractZoneCodes(from componentNames: [String]) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: zoneCodePattern) else {
            return []
        }

        var codes = Set<String>()

        for name in componentNames {
            let uppercasedName = name.uppercased()
            let nameNSString = uppercasedName as NSString
            let range = NSRange(location: 0, length: nameNSString.length)
            let matches = regex.matches(in: uppercasedName, range: range)

            for match in matches {
                codes.insert(nameNSString.substring(with: match.range))
            }
        }

        return codes
    }
}
