import ArgumentParser

package enum CLICommandParseResult<Command> {
    case command(Command)
    case cleanExit(String)
}

package struct CLICommandError: Error, CustomStringConvertible, Sendable {
    package let message: String
    package let exitCode: Int32

    package var description: String { message }
}

package enum CLICommandParser {
    package static func parse<Command: ParsableCommand>(
        _ command: Command.Type,
        arguments: [String]
    ) throws -> CLICommandParseResult<Command> {
        do {
            return .command(try command.parse(Array(arguments.dropFirst())))
        } catch {
            let exitCode = command.exitCode(for: error)
            let message = command.fullMessage(for: error)
            if exitCode.isSuccess {
                return .cleanExit(message)
            }
            throw CLICommandError(message: message, exitCode: exitCode.rawValue)
        }
    }

    package static func validationError<Command: ParsableCommand>(
        for command: Command.Type,
        message: String
    ) -> CLICommandError {
        let error = ValidationError(message)
        return CLICommandError(
            message: command.fullMessage(for: error),
            exitCode: command.exitCode(for: error).rawValue
        )
    }
}

package struct CLIRequestTimeout: Equatable, Sendable, CustomStringConvertible {
    package let seconds: Double

    package static func parse(_ argument: String) throws -> Self {
        guard let seconds = Double(argument),
            seconds.isFinite,
            seconds >= 0
        else {
            throw ValidationError(
                "--request-timeout must be a finite number greater than or equal to zero"
            )
        }
        let nanoseconds = (seconds * 1_000_000_000).rounded(.up)
        guard nanoseconds <= Double(Int64.max) else {
            throw ValidationError("--request-timeout is too large")
        }
        return Self(seconds: seconds)
    }

    package var duration: Duration? {
        guard seconds > 0 else { return nil }
        return .nanoseconds(Int64((seconds * 1_000_000_000).rounded(.up)))
    }

    package var description: String { String(seconds) }
}
