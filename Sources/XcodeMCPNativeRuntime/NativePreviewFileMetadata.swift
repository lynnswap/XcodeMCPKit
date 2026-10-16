import Darwin
import Foundation

@safe
final class NativePreviewFileMetadata {
    private let capacity = 256 * 1024
    private let buffer: UnsafeMutableRawPointer

    init() {
        unsafe buffer = .allocate(byteCount: capacity, alignment: 8)
    }

    deinit { unsafe buffer.deallocate() }

    // Bulk metadata is used only for regular children. Roots and other kinds
    // keep lstat, whose directory values include mounted roots and firmlink targets.
    // The optional stat contains only fields consumed by snapshots and digest caches.
    func directoryEntries(atPath path: String) throws -> [(name: String, metadata: stat?)] {
        func fallbackNames() throws -> [(name: String, metadata: stat?)] {
            try FileManager.default.contentsOfDirectory(atPath: path).map { ($0, nil) }
        }
        let descriptor = unsafe open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        defer { _ = close(descriptor) }
        let common = attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_CHGTIME) | attrgroup_t(ATTR_CMN_ACCESSMASK) | attrgroup_t(ATTR_CMN_FILEID)
        var requested = attrlist()
        requested.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        requested.commonattr = common | attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
        requested.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        var result: [(name: String, metadata: stat?)] = []
        while true {
            let count = unsafe getattrlistbulk(descriptor, &requested, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let code = errno
                if code == ENOTSUP { return try fallbackNames() }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
            if count == 0 { return result }
            var offset = 0
            for _ in 0..<count {
                // FSOPT_PACK_INVAL_ATTRS fixes this 64-bit prefix at 96 bytes.
                // getattrlist aligns even timespec and inode fields on 4-byte boundaries.
                guard offset <= capacity - 36 else { return try fallbackNames() }
                let length = Int(unsafe buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 36, length <= capacity - offset else { return try fallbackNames() }
                let returned = unsafe buffer.loadUnaligned(fromByteOffset: offset + 4, as: attribute_set_t.self)
                let error = unsafe buffer.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
                let reference = unsafe buffer.loadUnaligned(fromByteOffset: offset + 28, as: attrreference_t.self)
                let nameStart = 28 + Int(reference.attr_dataoffset)
                let nameLength = Int(reference.attr_length)
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0,
                      nameStart >= 0, nameLength > 0, nameStart <= length - nameLength,
                      unsafe buffer.load(fromByteOffset: offset + nameStart + nameLength - 1, as: UInt8.self) == 0 else {
                    return try fallbackNames()
                }
                let name = unsafe String(decoding: UnsafeBufferPointer(
                    start: buffer.advanced(by: offset + nameStart).assumingMemoryBound(to: UInt8.self),
                    count: nameLength - 1), as: UTF8.self)
                defer { offset += length }
                if name == "." || name == ".." { continue }
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0, error != 0 {
                    result.append((name, nil))
                    continue
                }
                guard length >= 96 else { return try fallbackNames() }
                let type = unsafe buffer.loadUnaligned(fromByteOffset: offset + 40, as: fsobj_type_t.self)
                guard type == fsobj_type_t(VREG.rawValue), returned.commonattr & common == common,
                      returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 else {
                    result.append((name, nil))
                    continue
                }
                var value = stat()
                value.st_dev = unsafe buffer.loadUnaligned(fromByteOffset: offset + 36, as: dev_t.self)
                let access = unsafe buffer.loadUnaligned(fromByteOffset: offset + 76, as: UInt32.self)
                value.st_mode = mode_t(access & UInt32(~mode_t(S_IFMT))) | mode_t(S_IFREG)
                value.st_mtimespec = unsafe buffer.loadUnaligned(fromByteOffset: offset + 44, as: timespec.self)
                value.st_ctimespec = unsafe buffer.loadUnaligned(fromByteOffset: offset + 60, as: timespec.self)
                value.st_ino = unsafe buffer.loadUnaligned(fromByteOffset: offset + 80, as: ino_t.self)
                value.st_size = unsafe buffer.loadUnaligned(fromByteOffset: offset + 88, as: off_t.self)
                result.append((name, value))
            }
        }
    }
}
