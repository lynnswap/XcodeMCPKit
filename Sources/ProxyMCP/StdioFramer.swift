import Foundation

package struct StdioFramerProtocolViolation: Sendable {
    package enum Reason: String, Codable, Sendable {
        case unexpectedLeadingByte
        case invalidContentLengthHeader
        case invalidJSON
        case bufferLimitExceeded
    }

    package let reason: Reason
    package let bufferedByteCount: Int
    package let preview: String
    package let previewHex: String
    package let leadingByteHex: String?

    package init(
        reason: Reason,
        bufferedByteCount: Int,
        preview: String,
        previewHex: String,
        leadingByteHex: String?
    ) {
        self.reason = reason
        self.bufferedByteCount = bufferedByteCount
        self.preview = preview
        self.previewHex = previewHex
        self.leadingByteHex = leadingByteHex
    }

    package init(reason: Reason, bufferedByteCount: Int, preview: String) {
        self.init(
            reason: reason,
            bufferedByteCount: bufferedByteCount,
            preview: preview,
            previewHex: "",
            leadingByteHex: nil
        )
    }
}

package struct StdioFramerAppendResult: Sendable {
    package let messages: [Data]
    package let protocolViolation: StdioFramerProtocolViolation?
    package let bufferedByteCount: Int

    package init(
        messages: [Data],
        protocolViolation: StdioFramerProtocolViolation?,
        bufferedByteCount: Int
    ) {
        self.messages = messages
        self.protocolViolation = protocolViolation
        self.bufferedByteCount = bufferedByteCount
    }
}

package final class StdioFramer {
    private enum JSONPrefixParseResult {
        case complete(Data.Index)
        case incomplete
        case invalid
    }

    private let bufferHardLimit = 4 * 1024 * 1024
    private let previewLimit = 200

    private var buffer = Data()

    package init() {}

    package func append(_ data: Data) -> StdioFramerAppendResult {
        if !data.isEmpty {
            buffer.append(data)
        }

        var messages: [Data] = []
        while true {
            if let message = nextContentLengthMessage() {
                messages.append(message)
                continue
            }
            if let message = nextJSONValueMessage() {
                messages.append(message)
                continue
            }
            break
        }

        let protocolViolation = protocolViolationIfNeeded()
        return StdioFramerAppendResult(
            messages: messages,
            protocolViolation: protocolViolation,
            bufferedByteCount: buffer.count
        )
    }

    private func nextJSONValueMessage() -> Data? {
        guard let startIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }

        let first = buffer[startIndex]
        guard first == 0x7B || first == 0x5B else {
            return nil
        }

        guard case .complete(let messageEnd) = jsonPrefixParseResult(from: startIndex) else {
            return nil
        }

        let message = buffer.subdata(in: startIndex..<messageEnd)
        guard isValidJSONObjectOrArray(message) else {
            return nil
        }

        buffer.removeSubrange(0..<messageEnd)
        return message
    }

    private func nextContentLengthMessage() -> Data? {
        guard let startIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }
        guard startsWithContentLengthHeader(at: startIndex) else {
            return nil
        }
        guard let headerEndIndex = contentLengthHeaderEndIndex(from: startIndex) else {
            return nil
        }

        let headerData = buffer.subdata(in: startIndex..<headerEndIndex)
        guard
            let headerText = String(data: headerData, encoding: .utf8),
            let length = parseContentLength(from: headerText)
        else {
            return nil
        }
        guard buffer.count >= headerEndIndex + length else {
            return nil
        }

        let bodyRange = headerEndIndex..<(headerEndIndex + length)
        guard let message = validatedJSONObjectOrArray(in: bodyRange) else {
            return nil
        }

        buffer.removeSubrange(0..<bodyRange.upperBound)
        return message
    }

    private func protocolViolationIfNeeded() -> StdioFramerProtocolViolation? {
        guard let firstIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            if buffer.count > bufferHardLimit {
                return makeProtocolViolation(reason: .bufferLimitExceeded)
            }
            return nil
        }

        if isPotentialContentLengthHeaderPrefix(at: firstIndex) {
            guard let headerEndIndex = contentLengthHeaderEndIndex(from: firstIndex) else {
                if hasMalformedContentLengthPrefixWithoutDelimiter(from: firstIndex) {
                    return makeProtocolViolation(reason: .invalidContentLengthHeader)
                }
                if buffer.count > bufferHardLimit {
                    return makeProtocolViolation(reason: .bufferLimitExceeded)
                }
                return nil
            }

            let headerData = buffer.subdata(in: firstIndex..<headerEndIndex)
            guard
                let headerText = String(data: headerData, encoding: .utf8),
                let length = parseContentLength(from: headerText)
            else {
                return makeProtocolViolation(reason: .invalidContentLengthHeader)
            }

            guard buffer.count >= headerEndIndex + length else {
                return nil
            }

            let bodyRange = headerEndIndex..<(headerEndIndex + length)
            guard validatedJSONObjectOrArray(in: bodyRange) != nil else {
                return makeProtocolViolation(reason: .invalidJSON)
            }

            return nil
        }

        let rootByte = buffer[firstIndex]
        guard rootByte == 0x7B || rootByte == 0x5B else {
            return makeProtocolViolation(reason: .unexpectedLeadingByte)
        }

        switch jsonPrefixParseResult(from: firstIndex) {
        case .complete(let messageEnd):
            let message = buffer.subdata(in: firstIndex..<messageEnd)
            if isValidJSONObjectOrArray(message) {
                return nil
            }
            return makeProtocolViolation(reason: .invalidJSON)
        case .incomplete:
            if buffer.count > bufferHardLimit {
                return makeProtocolViolation(reason: .bufferLimitExceeded)
            }
            return nil
        case .invalid:
            return makeProtocolViolation(reason: .invalidJSON)
        }
    }

    private func makeProtocolViolation(reason: StdioFramerProtocolViolation.Reason)
        -> StdioFramerProtocolViolation
    {
        StdioFramerProtocolViolation(
            reason: reason,
            bufferedByteCount: buffer.count,
            preview: preview(of: buffer),
            previewHex: previewHex(of: buffer),
            leadingByteHex: firstNonWhitespaceByteHex()
        )
    }

    private func isValidJSONObjectOrArray(_ data: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return any is [String: Any] || any is [Any]
    }

    private func validatedJSONObjectOrArray(in range: Range<Data.Index>) -> Data? {
        guard let startIndex = firstNonWhitespaceIndex(in: range) else {
            return nil
        }
        let rootByte = buffer[startIndex]
        guard rootByte == 0x7B || rootByte == 0x5B else {
            return nil
        }
        guard case .complete(let messageEnd) = jsonPrefixParseResult(from: startIndex) else {
            return nil
        }
        guard messageEnd <= range.upperBound else {
            return nil
        }
        guard buffer[messageEnd..<range.upperBound].allSatisfy(isWhitespace) else {
            return nil
        }

        let message = buffer.subdata(in: startIndex..<messageEnd)
        guard isValidJSONObjectOrArray(message) else {
            return nil
        }
        return message
    }

    private func firstNonWhitespaceIndex(from startIndex: Data.Index) -> Data.Index? {
        var index = startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else { return nil }
        return index
    }

    private func firstNonWhitespaceIndex(in range: Range<Data.Index>) -> Data.Index? {
        var index = range.lowerBound
        while index < range.upperBound, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        guard index < range.upperBound else { return nil }
        return index
    }

    private func contentLengthHeaderEndIndex(from startIndex: Data.Index) -> Data.Index? {
        let delimiterCRLF = Data("\r\n\r\n".utf8)
        let delimiterLF = Data("\n\n".utf8)
        let headerRange =
            buffer.range(of: delimiterCRLF, in: startIndex..<buffer.endIndex)
            ?? buffer.range(of: delimiterLF, in: startIndex..<buffer.endIndex)
        return headerRange?.upperBound
    }

    private func startsWithContentLengthHeader(at startIndex: Data.Index) -> Bool {
        let headerPrefix = "Content-Length"
        let available = buffer.distance(from: startIndex, to: buffer.endIndex)
        guard available >= headerPrefix.utf8.count else {
            return false
        }
        let prefixEnd = buffer.index(startIndex, offsetBy: headerPrefix.utf8.count)
        guard let prefixString = String(data: buffer.subdata(in: startIndex..<prefixEnd), encoding: .utf8) else {
            return false
        }
        return prefixString.caseInsensitiveCompare(headerPrefix) == .orderedSame
    }

    private func hasMalformedContentLengthPrefixWithoutDelimiter(from startIndex: Data.Index)
        -> Bool
    {
        guard let firstLineEnd = buffer.range(of: Data("\n".utf8), in: startIndex..<buffer.endIndex)?.lowerBound else {
            return false
        }
        let nextLineStart = buffer.index(after: firstLineEnd)
        guard nextLineStart < buffer.endIndex else {
            return false
        }
        let nextNonWhitespace = skipWhitespace(from: nextLineStart)
        guard nextNonWhitespace < buffer.endIndex else {
            return false
        }

        let nextByte = buffer[nextNonWhitespace]
        return nextByte == 0x7B || nextByte == 0x5B
    }

    private func isPotentialContentLengthHeaderPrefix(at startIndex: Data.Index) -> Bool {
        let headerPrefix = "Content-Length"
        let available = buffer.distance(from: startIndex, to: buffer.endIndex)
        let count = min(available, headerPrefix.utf8.count)
        guard count > 0 else { return false }
        let end = buffer.index(startIndex, offsetBy: count)
        guard let prefix = String(data: buffer.subdata(in: startIndex..<end), encoding: .utf8) else {
            return false
        }
        return headerPrefix.lowercased().hasPrefix(prefix.lowercased())
    }

    private func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), length >= 0 else {
                    return nil
                }
                return length
            }
        }
        return nil
    }

    private func jsonPrefixParseResult(from startIndex: Data.Index) -> JSONPrefixParseResult {
        parseJSONValuePrefix(from: startIndex)
    }

    private func parseJSONValuePrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        let index = skipWhitespace(from: startIndex)
        guard index < buffer.endIndex else { return .incomplete }

        switch buffer[index] {
        case 0x7B:
            return parseJSONObjectPrefix(from: index)
        case 0x5B:
            return parseJSONArrayPrefix(from: index)
        case 0x22:
            return parseJSONStringPrefix(from: index)
        case 0x74:
            return parseJSONLiteralPrefix("true", from: index)
        case 0x66:
            return parseJSONLiteralPrefix("false", from: index)
        case 0x6E:
            return parseJSONLiteralPrefix("null", from: index)
        case 0x2D, 0x30 ... 0x39:
            return parseJSONNumberPrefix(from: index)
        default:
            return .invalid
        }
    }

    private func parseJSONObjectPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = skipWhitespace(from: buffer.index(after: startIndex))
        guard index < buffer.endIndex else { return .incomplete }
        if buffer[index] == 0x7D {
            return .complete(buffer.index(after: index))
        }

        while true {
            switch parseJSONStringPrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            guard buffer[index] == 0x3A else { return .invalid }
            index = skipWhitespace(from: buffer.index(after: index))

            switch parseJSONValuePrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            let byte = buffer[index]
            if byte == 0x2C {
                index = skipWhitespace(from: buffer.index(after: index))
                guard index < buffer.endIndex else { return .incomplete }
                continue
            }
            if byte == 0x7D {
                return .complete(buffer.index(after: index))
            }
            return .invalid
        }
    }

    private func parseJSONArrayPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = skipWhitespace(from: buffer.index(after: startIndex))
        guard index < buffer.endIndex else { return .incomplete }
        if buffer[index] == 0x5D {
            return .complete(buffer.index(after: index))
        }

        while true {
            switch parseJSONValuePrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            let byte = buffer[index]
            if byte == 0x2C {
                index = skipWhitespace(from: buffer.index(after: index))
                guard index < buffer.endIndex else { return .incomplete }
                continue
            }
            if byte == 0x5D {
                return .complete(buffer.index(after: index))
            }
            return .invalid
        }
    }

    private func parseJSONStringPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        guard startIndex < buffer.endIndex, buffer[startIndex] == 0x22 else { return .invalid }

        var index = buffer.index(after: startIndex)
        var isEscaped = false
        var pendingUnicodeDigits = 0

        while index < buffer.endIndex {
            let byte = buffer[index]
            if pendingUnicodeDigits > 0 {
                guard isHexDigit(byte) else { return .invalid }
                pendingUnicodeDigits -= 1
            } else if isEscaped {
                switch byte {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    isEscaped = false
                case 0x75:
                    isEscaped = false
                    pendingUnicodeDigits = 4
                default:
                    return .invalid
                }
            } else if byte == 0x5C {
                isEscaped = true
            } else if byte == 0x22 {
                return .complete(buffer.index(after: index))
            } else if byte < 0x20 {
                return .invalid
            }

            index = buffer.index(after: index)
        }

        return .incomplete
    }

    private func parseJSONLiteralPrefix(_ literal: StaticString, from startIndex: Data.Index)
        -> JSONPrefixParseResult
    {
        let bytes = Array(String(describing: literal).utf8)
        var index = startIndex

        for expected in bytes {
            guard index < buffer.endIndex else { return .incomplete }
            guard buffer[index] == expected else { return .invalid }
            index = buffer.index(after: index)
        }

        if index < buffer.endIndex, !isJSONValueTerminator(buffer[index]) {
            return .invalid
        }
        return .complete(index)
    }

    private func parseJSONNumberPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = startIndex
        let start = index

        if buffer[index] == 0x2D {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
        }

        guard index < buffer.endIndex else { return .incomplete }
        switch buffer[index] {
        case 0x30:
            index = buffer.index(after: index)
            if index < buffer.endIndex, isDigit(buffer[index]) {
                return .invalid
            }
        case 0x31 ... 0x39:
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        default:
            return index == start ? .invalid : .incomplete
        }

        if index < buffer.endIndex, buffer[index] == 0x2E {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
            guard isDigit(buffer[index]) else { return .invalid }
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        }

        if index < buffer.endIndex, buffer[index] == 0x45 || buffer[index] == 0x65 {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
            if buffer[index] == 0x2B || buffer[index] == 0x2D {
                index = buffer.index(after: index)
                guard index < buffer.endIndex else { return .incomplete }
            }
            guard isDigit(buffer[index]) else { return .invalid }
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        }

        if index < buffer.endIndex, !isJSONValueTerminator(buffer[index]) {
            return .invalid
        }
        return .complete(index)
    }

    private func skipWhitespace(from startIndex: Data.Index) -> Data.Index {
        var index = startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        return index
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    private func isJSONValueTerminator(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D
    }

    private func preview(of data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let slice = data.count <= previewLimit ? data : data.prefix(previewLimit)
        let text = String(decoding: slice, as: UTF8.self)
        return data.count > previewLimit ? text + "..." : text
    }

    private func previewHex(of data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let slice = data.count <= previewLimit ? data : data.prefix(previewLimit)
        let hex = slice.map(Self.hexString).joined(separator: " ")
        return data.count > previewLimit ? hex + " ..." : hex
    }

    private func firstNonWhitespaceByteHex() -> String? {
        guard let firstIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }
        return Self.hexString(buffer[firstIndex])
    }

    private static func hexString(_ byte: UInt8) -> String {
        let hex = String(byte, radix: 16, uppercase: false)
        return hex.count == 1 ? "0" + hex : hex
    }
}
