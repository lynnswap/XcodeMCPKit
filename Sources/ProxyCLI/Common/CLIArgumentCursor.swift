import Foundation

package struct CLIArgumentCursor {
    private let args: [String]
    package private(set) var index: Int

    package init(args: [String], startIndex: Int = 1) {
        self.args = args
        self.index = startIndex
    }

    package var current: String? {
        guard index < args.count else { return nil }
        return args[index]
    }

    package var next: String? {
        let nextIndex = index + 1
        guard nextIndex < args.count else { return nil }
        return args[nextIndex]
    }

    package mutating func advance(by amount: Int = 1) {
        index = min(args.count, index + amount)
    }

    package mutating func advancePastCurrentAndOptionalValue(
        where shouldConsume: (String) -> Bool
    ) {
        if let next, shouldConsume(next) {
            advance(by: 2)
        } else {
            advance()
        }
    }

    package mutating func requiredValue<E: Error>(
        for option: String,
        error: (String) -> E
    ) throws -> String {
        guard let value = next else {
            throw error(option)
        }
        advance(by: 2)
        return value
    }
}
