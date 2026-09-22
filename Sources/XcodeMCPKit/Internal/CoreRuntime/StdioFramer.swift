import Foundation

package final class StdioFramer {
    package struct ProtocolViolation: Sendable {
        package enum Reason: String, Codable, Sendable {
            case unexpectedLeadingByte
            case unexpectedTopLevelArray
            case invalidContentLengthHeader
            case headerTooLarge
            case invalidJSON
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

    package struct AppendResult: Sendable {
        package let messages: [Data]
        package let protocolViolation: StdioFramer.ProtocolViolation?
        package let bufferedByteCount: Int

        package init(
            messages: [Data],
            protocolViolation: StdioFramer.ProtocolViolation?,
            bufferedByteCount: Int
        ) {
            self.messages = messages
            self.protocolViolation = protocolViolation
            self.bufferedByteCount = bufferedByteCount
        }
    }

    private enum JSONPrefixParseResult {
        case complete(Data.Index)
        case incomplete
        case invalid
    }

    private let maximumHeaderBytes = 4 * 1024 * 1024
    private let previewLimit = 200

    private var buffer = Data()
    private var rawJSONScanner: JSONBoundaryScanner?

    package init() {}

    package func append(_ data: Data) -> StdioFramer.AppendResult {
        if !data.isEmpty {
            buffer.append(data)
        }

        var messages: [Data] = []
        while true {
            if rawJSONScanner == nil,
               let first = firstNonWhitespaceIndex(from: buffer.startIndex),
               first > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<first)
            }
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

        if firstNonWhitespaceIndex(from: buffer.startIndex) == nil {
            buffer.removeAll(keepingCapacity: false)
            rawJSONScanner = nil
        }

        let protocolViolation = protocolViolationIfNeeded()
        return StdioFramer.AppendResult(
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

        guard case .complete(let messageEnd) = scanRawJSON(from: startIndex) else {
            return nil
        }

        let message = buffer.subdata(in: startIndex..<messageEnd)
        guard isValidJSONObjectOrArray(message) else {
            return nil
        }

        buffer.removeSubrange(0..<messageEnd)
        rawJSONScanner = nil
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

        guard headerEndIndex - startIndex <= maximumHeaderBytes else { return nil }
        let headerData = buffer.subdata(in: startIndex..<headerEndIndex)
        guard
            let headerText = String(data: headerData, encoding: .utf8),
            let length = parseContentLength(from: headerText)
        else {
            return nil
        }
        guard length <= buffer.endIndex - headerEndIndex else {
            return nil
        }

        let bodyRange = headerEndIndex..<(headerEndIndex + length)
        guard let message = validatedJSONObjectOrArray(in: bodyRange) else {
            return nil
        }

        buffer.removeSubrange(0..<bodyRange.upperBound)
        return message
    }

    private func protocolViolationIfNeeded() -> StdioFramer.ProtocolViolation? {
        guard let firstIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }

        if isPotentialContentLengthHeaderPrefix(at: firstIndex) {
            guard let headerEndIndex = contentLengthHeaderEndIndex(from: firstIndex) else {
                if buffer.endIndex - firstIndex > maximumHeaderBytes {
                    return makeProtocolViolation(reason: .headerTooLarge)
                }
                if hasMalformedContentLengthPrefixWithoutDelimiter(from: firstIndex) {
                    return makeProtocolViolation(reason: .invalidContentLengthHeader)
                }
                return nil
            }

            guard headerEndIndex - firstIndex <= maximumHeaderBytes else {
                return makeProtocolViolation(reason: .headerTooLarge)
            }
            let headerData = buffer.subdata(in: firstIndex..<headerEndIndex)
            guard
                let headerText = String(data: headerData, encoding: .utf8),
                let length = parseContentLength(from: headerText)
            else {
                return makeProtocolViolation(reason: .invalidContentLengthHeader)
            }

            guard length <= Int.max - headerEndIndex else {
                return makeProtocolViolation(reason: .invalidContentLengthHeader)
            }
            guard length <= buffer.endIndex - headerEndIndex else {
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

        switch scanRawJSON(from: firstIndex) {
        case .complete(let messageEnd):
            let message = buffer.subdata(in: firstIndex..<messageEnd)
            if isValidJSONObjectOrArray(message) {
                return nil
            }
            return makeProtocolViolation(reason: .invalidJSON)
        case .incomplete:
            return nil
        case .invalid:
            return makeProtocolViolation(reason: .invalidJSON)
        }
    }

    private func makeProtocolViolation(reason: StdioFramer.ProtocolViolation.Reason)
        -> StdioFramer.ProtocolViolation
    {
        StdioFramer.ProtocolViolation(
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
        var scanner = JSONBoundaryScanner(cursor: startIndex)
        guard case .complete(let messageEnd) = scanner.scan(in: buffer, through: range.upperBound) else {
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

    private func scanRawJSON(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var scanner = rawJSONScanner ?? JSONBoundaryScanner(cursor: startIndex)
        let result = scanner.scan(in: buffer, through: buffer.endIndex)
        rawJSONScanner = scanner
        return result
    }

    // Keep lexical and container state across appends so invalid prefixes fail
    // promptly without rescanning the accumulated body. Foundation validates
    // the completed payload's encoding after strict JSON framing succeeds.
    private struct JSONBoundaryScanner {
        private enum ObjectState { case keyOrEnd, key, colon, value, commaOrEnd }
        private enum ArrayState { case valueOrEnd, value, commaOrEnd }
        private enum Frame { case object(ObjectState), array(ArrayState) }
        private enum Token {
            case string(isKey: Bool, escaped: Bool, unicodeDigits: Int)
            case literal([UInt8], next: Int)
            case number(NumberState)
        }
        private enum NumberState {
            case minus, zero, integer, decimalPoint, fraction, exponent, exponentSign, exponentDigits

            var canEnd: Bool {
                switch self {
                case .zero, .integer, .fraction, .exponentDigits: true
                case .minus, .decimalPoint, .exponent, .exponentSign: false
                }
            }

            func next(_ byte: UInt8) -> Self? {
                switch self {
                case .minus:
                    if byte == 0x30 { return .zero }
                    if (0x31...0x39).contains(byte) { return .integer }
                case .zero, .integer:
                    if self == .integer, (0x30...0x39).contains(byte) { return .integer }
                    if byte == 0x2E { return .decimalPoint }
                    if byte == 0x65 || byte == 0x45 { return .exponent }
                case .decimalPoint, .fraction:
                    if (0x30...0x39).contains(byte) { return .fraction }
                    if self == .fraction, byte == 0x65 || byte == 0x45 { return .exponent }
                case .exponent:
                    if byte == 0x2B || byte == 0x2D { return .exponentSign }
                    if (0x30...0x39).contains(byte) { return .exponentDigits }
                case .exponentSign, .exponentDigits:
                    if (0x30...0x39).contains(byte) { return .exponentDigits }
                }
                return nil
            }
        }

        var cursor: Data.Index
        private var frames: [Frame] = []
        private var token: Token?
        private var terminalResult: JSONPrefixParseResult?

        init(cursor: Data.Index) { self.cursor = cursor }

        mutating func scan(in data: Data, through endIndex: Data.Index) -> JSONPrefixParseResult {
            if let terminalResult { return terminalResult }
            while cursor < endIndex {
                let byte = data[cursor]
                if case .number(let number) = token {
                    if let next = number.next(byte) {
                        token = .number(next)
                        cursor += 1
                    } else if number.canEnd,
                              Self.isWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D {
                        token = nil
                        finishValue()
                    } else {
                        return finish(.invalid)
                    }
                    continue
                }

                cursor += 1
                if let token {
                    switch token {
                    case .string(let isKey, let escaped, let unicodeDigits):
                        if unicodeDigits > 0 {
                            guard (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
                                || (0x61...0x66).contains(byte) else { return finish(.invalid) }
                            self.token = .string(isKey: isKey, escaped: false, unicodeDigits: unicodeDigits - 1)
                        } else if escaped {
                            switch byte {
                            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                                self.token = .string(isKey: isKey, escaped: false, unicodeDigits: 0)
                            case 0x75:
                                self.token = .string(isKey: isKey, escaped: false, unicodeDigits: 4)
                            default:
                                return finish(.invalid)
                            }
                        } else if byte == 0x5C {
                            self.token = .string(isKey: isKey, escaped: true, unicodeDigits: 0)
                        } else if byte == 0x22 {
                            self.token = nil
                            if isKey { frames[frames.count - 1] = .object(.colon) }
                            else { finishValue() }
                        } else if byte < 0x20 {
                            return finish(.invalid)
                        }
                    case .literal(let bytes, let next):
                        guard byte == bytes[next] else { return finish(.invalid) }
                        if next + 1 == bytes.count {
                            self.token = nil
                            finishValue()
                        } else {
                            self.token = .literal(bytes, next: next + 1)
                        }
                    case .number:
                        break
                    }
                    continue
                }

                if Self.isWhitespace(byte) { continue }
                switch frames.last {
                case .object(.keyOrEnd) where byte == 0x7D,
                     .object(.commaOrEnd) where byte == 0x7D,
                     .array(.valueOrEnd) where byte == 0x5D,
                     .array(.commaOrEnd) where byte == 0x5D:
                    frames.removeLast()
                    if frames.isEmpty { return finish(.complete(cursor)) }
                    finishValue()
                case .object(.keyOrEnd), .object(.key):
                    guard byte == 0x22 else { return finish(.invalid) }
                    token = .string(isKey: true, escaped: false, unicodeDigits: 0)
                case .object(.colon):
                    guard byte == 0x3A else { return finish(.invalid) }
                    frames[frames.count - 1] = .object(.value)
                case .object(.commaOrEnd):
                    guard byte == 0x2C else { return finish(.invalid) }
                    frames[frames.count - 1] = .object(.key)
                case .array(.commaOrEnd):
                    guard byte == 0x2C else { return finish(.invalid) }
                    frames[frames.count - 1] = .array(.value)
                case .object(.value), .array(.value), .array(.valueOrEnd):
                    guard beginValue(byte) else { return finish(.invalid) }
                case nil:
                    guard byte == 0x7B || byte == 0x5B, beginValue(byte) else {
                        return finish(.invalid)
                    }
                }
            }
            return .incomplete
        }

        private mutating func beginValue(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x7B: frames.append(.object(.keyOrEnd))
            case 0x5B: frames.append(.array(.valueOrEnd))
            case 0x22: token = .string(isKey: false, escaped: false, unicodeDigits: 0)
            case 0x74: token = .literal(Array("true".utf8), next: 1)
            case 0x66: token = .literal(Array("false".utf8), next: 1)
            case 0x6E: token = .literal(Array("null".utf8), next: 1)
            case 0x2D: token = .number(.minus)
            case 0x30: token = .number(.zero)
            case 0x31...0x39: token = .number(.integer)
            default: return false
            }
            return true
        }

        private mutating func finishValue() {
            switch frames[frames.count - 1] {
            case .object: frames[frames.count - 1] = .object(.commaOrEnd)
            case .array: frames[frames.count - 1] = .array(.commaOrEnd)
            }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private mutating func finish(_ result: JSONPrefixParseResult) -> JSONPrefixParseResult {
            terminalResult = result
            return result
        }
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
