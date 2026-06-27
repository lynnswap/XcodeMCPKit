import Darwin
import Foundation

/// In-process replacements for pgrep/ps lookups, built on libproc so that
/// callers never block on a spawned subprocess.
package enum ProcessEnumeration {
    /// Equivalent of `pgrep -x name`.
    package static func processIDs(named processName: String) -> [pid_t] {
        let estimatedByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimatedByteCount > 0 else {
            return []
        }
        var pids = [pid_t](
            repeating: 0,
            count: Int(estimatedByteCount) / MemoryLayout<pid_t>.size + 32
        )
        let byteCount = unsafe pids.withUnsafeMutableBufferPointer { buffer in
            unsafe proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard byteCount > 0 else {
            return []
        }
        var result: [pid_t] = []
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 64)
            let nameLength = unsafe proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard nameLength > 0 else {
                continue
            }
            let name = unsafe nameBuffer.withUnsafeBufferPointer { pointer in
                unsafe pointer.baseAddress.map { unsafe String(cString: $0) }
            }
            if name == processName {
                result.append(pid)
            }
        }
        return result
    }

    /// Equivalent of `ps -p pid -o comm=`.
    package static func executablePath(of processID: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro does not import.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = unsafe proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return unsafe buffer.withUnsafeBufferPointer { pointer in
            unsafe pointer.baseAddress.map { unsafe String(cString: $0) }
        }
    }
}
