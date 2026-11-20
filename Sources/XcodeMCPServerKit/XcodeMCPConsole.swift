import Foundation

package enum XcodeMCPConsole {
    package static func writeStandardErrorLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
