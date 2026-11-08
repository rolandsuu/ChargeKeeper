import Foundation
import IOKit

/// All of ChargeKeeper's access to the SMC is in this file. Reading is open to the rest of the
/// module. The one write is `fileprivate`, so only `MagSafeLight` below can reach it, and that
/// allows a single key and two values.
final class SMCConnection {
    struct Value {
        var type: String
        var bytes: [UInt8]
    }

    /// The SMC's 80-byte call structure. The padding fields are explicit because Swift would
    /// otherwise pack fields into the gaps C leaves.
    private struct KeyData {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var padding0: UInt16 = 0
        var powerLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding1: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var result: UInt8 = 0
        var status: UInt8 = 0
        var selector: UInt8 = 0
        var padding2: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let selectorRead: UInt8 = 5
    private static let selectorWrite: UInt8 = 6
    private static let selectorKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func text(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }

    private func call(_ input: inout KeyData) -> (status: kern_return_t, output: KeyData) {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &size)
        return (status, output)
    }

    private func info(_ key: String) -> KeyData? {
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.selector = Self.selectorKeyInfo
        let (status, output) = call(&input)
        guard status == KERN_SUCCESS, output.result == 0, output.dataSize > 0 else { return nil }
        return output
    }

    func read(_ key: String) -> Value? {
        guard let info = info(key) else { return nil }
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.dataSize = info.dataSize
        input.dataType = info.dataType
        input.selector = Self.selectorRead
        let (status, output) = call(&input)
        guard status == KERN_SUCCESS, output.result == 0 else { return nil }

        var bytes = output.bytes
        let count = min(Int(info.dataSize), MemoryLayout.size(ofValue: bytes))
        let data = withUnsafeBytes(of: &bytes) { Array($0.prefix(count)) }
        return Value(type: Self.text(info.dataType), bytes: data)
    }

    /// Writes a one-byte key, after checking the key really is one byte of the expected type.
    /// Returns nil on success, or the IOKit status or SMC result code on failure.
    fileprivate func writeByte(_ key: String, _ value: UInt8, type: String) -> Int32? {
        guard let info = info(key), info.dataSize == 1, Self.text(info.dataType) == type else { return -1 }
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.dataSize = 1
        input.dataType = info.dataType
        input.selector = Self.selectorWrite
        input.bytes.0 = UInt64(value)
        let (status, output) = call(&input)
        if status != KERN_SUCCESS { return status }
        return output.result == 0 ? nil : Int32(output.result)
    }
}

/// The MagSafe charging light, controlled through the SMC key `ACLC`.
/// This is the only SMC key ChargeKeeper writes, and only the two values in `Mode` can be written.
public final class MagSafeLight {
    public enum Mode: UInt8, CaseIterable {
        /// macOS chooses the light, as it normally would.
        case system = 0x00
        case off = 0x01
    }

    public enum Failure: LocalizedError, Equatable {
        case needsRoot
        case writeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .needsRoot:
                return "Changing the MagSafe light needs the background service."
            case .writeFailed(let code):
                return "Couldn't change the MagSafe light (error \(String(format: "0x%08x", UInt32(bitPattern: code))))."
            }
        }
    }

    private static let key = "ACLC"
    private static let type = "ui8 "
    private let smc: SMCConnection

    /// Nil on a Mac without a MagSafe light that can be controlled.
    public init?() {
        guard let smc = SMCConnection(),
              let value = smc.read(Self.key), value.type == Self.type, value.bytes.count == 1 else { return nil }
        self.smc = smc
    }

    /// The raw value the SMC reports. macOS writes its own colours here, such as 0x03 for green.
    public func current() -> UInt8? {
        smc.read(Self.key)?.bytes.first
    }

    public func set(_ mode: Mode) throws {
        guard geteuid() == 0 else { throw Failure.needsRoot }
        if let code = smc.writeByte(Self.key, mode.rawValue, type: Self.type) {
            throw Failure.writeFailed(code)
        }
    }

    /// What to write so the light matches the setting, or nil to leave it alone.
    /// When the light should be off, it's only switched off while plugged in, since it isn't lit otherwise.
    public static func change(showLight: Bool, current: UInt8, isPluggedIn: Bool) -> Mode? {
        let isOff = current == Mode.off.rawValue
        if showLight { return isOff ? .system : nil }
        return isPluggedIn && !isOff ? .off : nil
    }
}
