import Foundation
import IOKit

/// Access to the SMC key table, where Apple Silicon keeps fan speeds.
///
/// ## Why not HID, like temperatures
///
/// `HIDSensorInterface` is the right door for temperatures and the wrong one
/// for fans. Probing an M4 Max Mac Studio -- a machine with two fans that are
/// audibly spinning -- found 39 services on Apple's vendor page at the
/// temperature usage and *nothing* at the fan usage, or at any other usage on
/// that page, across the full 0...255 sweep. `ioreg` has no fan node either.
/// The fans are simply not published to the HID event system on this hardware.
///
/// ## The byte order, which cost the whole investigation
///
/// The classic SMC protocol is well documented and this endpoint speaks it --
/// selector 2, an 80-byte parameter struct -- with one undocumented difference
/// on Apple Silicon: **keys go in with their bytes reversed**. Sending `#KEY`
/// as the obvious big-endian `0x234B4559` returns `kSMCKeyNotFound` (0x84), and
/// so does every other key, which reads exactly like an SMC that has no keys at
/// all rather than like a byte-order bug. What gave it away was asking for
/// index 0 by number instead of by name: it came back named `YEK#`.
///
/// Values keep the classic convention regardless: integers big-endian, `flt`
/// little-endian IEEE 754.
///
/// ## Read-only, deliberately and permanently
///
/// Only `kSMCReadKey` and `kSMCGetKeyInfo` are implemented, and `kSMCWriteKey`
/// deliberately is not. Writing SMC keys can drive fans beyond their rated
/// speed or stop them entirely, and no menu bar app has any business doing
/// that. This is a floor, not a default -- do not add a write path here.
final class SMCInterface: @unchecked Sendable {
    static let shared = SMCInterface()

    /// The parameter struct the AppleSMC user client accepts. Probing every
    /// size from 16 to 168 found exactly two the kernel does not reject, and 80
    /// is the classic one.
    private static let structSize = 80

    // Field offsets within that struct.
    private static let keyOffset = 0
    private static let dataSizeOffset = 28
    private static let dataTypeOffset = 32
    private static let resultOffset = 40
    private static let data8Offset = 42
    private static let data32Offset = 44
    private static let bytesOffset = 48

    private static let readKeyCommand: UInt8 = 5
    private static let keyInfoCommand: UInt8 = 9

    /// `kSMCKeyNotFound`. Routine -- it is how a machine says it has no second
    /// fan -- so callers treat it as absence, not as an error.
    private static let keyNotFound: UInt8 = 0x84

    let isSupported: Bool

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            isSupported = false
            return
        }
        IOObjectRelease(service)
        isSupported = true
    }

    /// A connection to the SMC. The caller owns it and must `close` it.
    func open() -> io_connect_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        return connection
    }

    func close(_ connection: io_connect_t) {
        IOServiceClose(connection)
    }

    /// Reads one SMC key. `nil` when the key does not exist on this machine,
    /// which is the normal answer for a fan index past the last fan.
    func read(_ connection: io_connect_t, key: String) -> Double? {
        guard let (size, type) = keyInfo(connection, key: key), size > 0 else { return nil }

        var input = [UInt8](repeating: 0, count: Self.structSize)
        write(key: key, into: &input)
        writeLittleEndian(UInt32(size), into: &input, at: Self.dataSizeOffset)
        input[Self.data8Offset] = Self.readKeyCommand

        guard let output = call(connection, input: &input), output[Self.resultOffset] == 0 else { return nil }
        let payload = Array(output[Self.bytesOffset ..< Self.bytesOffset + min(size, 32)])
        return decode(type: type, bytes: payload)
    }

    private func keyInfo(_ connection: io_connect_t, key: String) -> (size: Int, type: String)? {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        write(key: key, into: &input)
        input[Self.data8Offset] = Self.keyInfoCommand

        guard let output = call(connection, input: &input) else { return nil }
        let result = output[Self.resultOffset]
        guard result == 0 else { return nil }

        let size = Int(readLittleEndian(output, at: Self.dataSizeOffset))
        let type = String(
            bytes: output[Self.dataTypeOffset ..< Self.dataTypeOffset + 4].reversed(),
            encoding: .ascii
        )
        guard let type else { return nil }
        return (size, type)
    }

    private func call(_ connection: io_connect_t, input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize

        let status = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,                                  // kSMCHandleYPCEvent
                    inputPointer.baseAddress!,
                    Self.structSize,
                    outputPointer.baseAddress!,
                    &outputSize
                )
            }
        }
        return status == KERN_SUCCESS ? output : nil
    }

    /// Keys go in reversed. See the note at the top of this file.
    private func write(key: String, into buffer: inout [UInt8]) {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return }
        for (offset, byte) in bytes.reversed().enumerated() {
            buffer[Self.keyOffset + offset] = byte
        }
    }

    private func writeLittleEndian(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func readLittleEndian(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    /// Integers are big-endian, floats little-endian. Mixing these up produces
    /// plausible-looking nonsense rather than a failure, so both are spelled
    /// out rather than inferred.
    private func decode(type: String, bytes: [UInt8]) -> Double? {
        let name = type.trimmingCharacters(in: .whitespaces)
        switch name {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8", "si8":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "ui16", "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int(bytes[0]) << 8 | Int(bytes[1]))
        case "ui32", "si32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            )
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 8 | Int(bytes[1])) >> 2)
        default:
            return nil
        }
    }
}
