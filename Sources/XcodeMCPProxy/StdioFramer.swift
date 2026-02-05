import Foundation

public final class StdioFramer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var messages: [Data] = []

        while true {
            if let message = nextContentLengthMessage() {
                messages.append(message)
                continue
            }
            let lines = nextNDJSONMessages()
            if lines.isEmpty {
                if let message = nextJSONValueMessage() {
                    messages.append(message)
                    continue
                }
                break
            }
            messages.append(contentsOf: lines)
        }

        return messages
    }

    private func nextContentLengthMessage() -> Data? {
        let headerPrefix = "Content-Length"
        guard buffer.count >= headerPrefix.count else { return nil }
        guard let prefixString = String(data: buffer.prefix(headerPrefix.count), encoding: .utf8),
              prefixString.caseInsensitiveCompare(headerPrefix) == .orderedSame else {
            return nil
        }

        let delimiterCRLF = Data("\r\n\r\n".utf8)
        let delimiterLF = Data("\n\n".utf8)
        let headerEndRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF)
        guard let headerRange = headerEndRange else { return nil }
        let headerEndIndex = headerRange.upperBound
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength: Int?
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
        }

        guard let length = contentLength, length >= 0 else { return nil }
        guard buffer.count >= headerEndIndex + length else { return nil }

        let bodyRange = headerEndIndex..<(headerEndIndex + length)
        let message = buffer.subdata(in: bodyRange)
        buffer.removeSubrange(0..<(headerEndIndex + length))
        return message
    }

    private func nextNDJSONMessages() -> [Data] {
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        let endIndex = buffer.index(after: lastNewline)
        let completeData = buffer.subdata(in: 0..<endIndex)
        buffer.removeSubrange(0..<endIndex)

        var messages: [Data] = []
        var startIndex = completeData.startIndex
        for index in completeData.indices where completeData[index] == 0x0A {
            let lineData = completeData.subdata(in: startIndex..<index)
            startIndex = completeData.index(after: index)
            let trimmed = trimTrailingCR(lineData)
            if trimmed.isEmpty { continue }
            messages.append(trimmed)
        }
        return messages
    }

    private func trimTrailingCR(_ data: Data) -> Data {
        guard let last = data.last, last == 0x0D else { return data }
        return data.dropLast()
    }

    private func nextJSONValueMessage() -> Data? {
        var index = buffer.startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        if index == buffer.endIndex { return nil }

        let startIndex = index
        let first = buffer[index]
        guard first == 0x7B || first == 0x5B else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var endIndex: Data.Index?

        while index < buffer.endIndex {
            let byte = buffer[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        endIndex = index
                        break
                    }
                }
            }
            index = buffer.index(after: index)
        }

        guard let endIndex, depth == 0, !inString else { return nil }
        let messageEnd = buffer.index(after: endIndex)
        let message = buffer.subdata(in: startIndex..<messageEnd)
        buffer.removeSubrange(0..<messageEnd)
        return message
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
