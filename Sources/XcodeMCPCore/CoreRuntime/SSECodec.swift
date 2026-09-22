import Foundation

package enum SSECodec {
    /// Encodes a single SSE event containing one logical `data` payload.
    ///
    /// If the payload contains newlines, they are emitted as multiple `data:` lines per the SSE spec.
    /// Returns `nil` if the payload is not valid UTF-8.
    package static func encodeDataEvent(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Rough over-allocation: "data: " prefix + "\n" per line + final "\n".
        var out = String()
        out.reserveCapacity(text.utf8.count + 16)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            out += "data: "
            out += line
            out += "\n"
        }
        out += "\n"
        return out
    }
}

package struct SSEDecoder {
    private var dataLines: [String] = []

    package init() {}

    package mutating func feed(line: String) -> Data? {
        let normalized: Substring
        if line.last == "\r" {
            normalized = line.dropLast()
        } else {
            normalized = Substring(line)
        }

        // Empty line ends the current event.
        if normalized.isEmpty {
            return flushIfNeeded()
        }

        // Comment line.
        if normalized.first == ":" {
            return nil
        }

        guard normalized.hasPrefix("data:") else {
            return nil
        }

        var payload = normalized.dropFirst(5)
        if payload.first == " " {
            payload = payload.dropFirst()
        }
        dataLines.append(String(payload))
        return nil
    }

    package mutating func flushIfNeeded() -> Data? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return Data(payload.utf8)
    }
}
