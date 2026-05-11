//
//  NetworkGatewayResolver.swift
//  PingWarden
//
//  Resolves the active default IPv4 gateway by shelling out to `route -n get
//  default`. Used by the dashboard to offer "my router" as a ping target.
//

import Foundation

enum NetworkGatewayResolver {
    static func defaultGatewayAddress() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        process.arguments = ["-n", "get", "default"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // Discard stderr so its pipe buffer can never fill up and block route.
        process.standardError = FileHandle.nullDevice

        let data: Data
        do {
            try process.run()
            // Read until EOF first; reversing the order risks deadlock if a
            // subprocess writes more output than the pipe buffer can hold.
            data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("gateway:") else { continue }

            let gateway = line.replacingOccurrences(of: "gateway:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !gateway.isEmpty, !gateway.hasPrefix("link#") else {
                return nil
            }

            return gateway
        }

        return nil
    }
}
