import Foundation

actor StdioWriter {
    private let framing: StdioFraming
    private let output = FileHandle.standardOutput

    init(framing: StdioFraming) {
        self.framing = framing
    }

    func send(_ data: Data) {
        let payload: Data
        switch framing {
        case .ndjson:
            if data.last == 0x0A {
                payload = data
            } else {
                var buffer = data
                buffer.append(0x0A)
                payload = buffer
            }
        case .contentLength:
            let header = "Content-Length: \(data.count)\r\n\r\n"
            var buffer = Data(header.utf8)
            buffer.append(data)
            payload = buffer
        }
        output.write(payload)
    }
}

final class SSEParser {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var results: [Data] = []
        while true {
            guard let range = nextDelimiterRange() else { break }
            let block = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard !block.isEmpty else { continue }
            let payloads = parseBlock(block)
            results.append(contentsOf: payloads)
        }
        return results
    }

    private func nextDelimiterRange() -> Range<Data.Index>? {
        let crlf = Data("\r\n\r\n".utf8)
        let lf = Data("\n\n".utf8)
        let crlfRange = buffer.range(of: crlf)
        let lfRange = buffer.range(of: lf)
        switch (crlfRange, lfRange) {
        case (nil, nil):
            return nil
        case (let range?, nil):
            return range
        case (nil, let range?):
            return range
        case (let range1?, let range2?):
            return range1.lowerBound < range2.lowerBound ? range1 : range2
        }
    }

    private func parseBlock(_ block: Data) -> [Data] {
        guard let text = String(data: block, encoding: .utf8) else { return [] }
        var dataLines: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    dataLines.append(value)
                }
            }
        }
        guard !dataLines.isEmpty else { return [] }
        let combined = dataLines.joined(separator: "\n")
        return [Data(combined.utf8)]
    }
}
