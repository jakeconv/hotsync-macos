import Foundation

/// The attribute byte of a Palm database record (`dlpRecAttributes`).
public struct PalmRecordAttributes: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Deleted on the Palm; the record stays (often without data) until the
    /// next sync removes it (`resetflags`).
    public static let deleted = PalmRecordAttributes(rawValue: 0x80)
    /// Changed on the Palm since the last sync.
    public static let dirty = PalmRecordAttributes(rawValue: 0x40)
    /// Open in an application on the Palm.
    public static let busy = PalmRecordAttributes(rawValue: 0x20)
    /// Marked private ("secret" in the Palm OS documentation).
    public static let secret = PalmRecordAttributes(rawValue: 0x10)
    /// Deleted on the Palm with "save archive copy on PC".
    public static let archived = PalmRecordAttributes(rawValue: 0x08)
}

/// One record of a Palm database, as `readall` / `readchanged` report it.
/// What `data` means depends on the database (see the calendar codecs).
public struct PalmRecord: Equatable, Sendable {
    /// Unique ID within the database (24 bits on the Palm), never 0.
    public let id: UInt32
    /// Position in the database at the time it was read.
    public let index: Int
    public let attributes: PalmRecordAttributes
    /// Category 0...15; 0 is "Unfiled" in the Palm's own applications.
    public let category: Int
    public let data: Data

    public init(id: UInt32, index: Int, attributes: PalmRecordAttributes, category: Int, data: Data) {
        self.id = id
        self.index = index
        self.attributes = attributes
        self.category = category
        self.data = data
    }

    /// Deleted or archived on the Palm: gone there, to be removed on the
    /// Mac too (an archived record is also kept by the Mac, if wanted).
    public var isRemoved: Bool { !attributes.isDisjoint(with: [.deleted, .archived]) }
}

/// A database in the Palm's RAM, as `listdbs` reports it.
public struct PalmDatabaseInfo: Equatable, Sendable {
    public let name: String
    /// Four-character codes, e.g. "DATA" / "date" for the Date Book.
    public let type: String
    public let creator: String
    /// `dlpDBFlags`; 0x0001 is a resource database (.prc).
    public let flags: Int
    public let version: Int
    /// Increased by the Palm with every change.
    public let modificationNumber: Int
    public let created: Date?
    public let modified: Date?
    public let backedUp: Date?

    public init(name: String, type: String, creator: String, flags: Int, version: Int,
                modificationNumber: Int, created: Date?, modified: Date?, backedUp: Date?) {
        self.name = name
        self.type = type
        self.creator = creator
        self.flags = flags
        self.version = version
        self.modificationNumber = modificationNumber
        self.created = created
        self.modified = modified
        self.backedUp = backedUp
    }

    public var isResourceDatabase: Bool { flags & 0x0001 != 0 }
}

/// Which computer the Palm last synced with, and when (`syncinfo`).
public struct PalmSyncInfo: Equatable, Sendable {
    /// The ID that computer wrote with `setsyncpc`; 0 if none did.
    public let lastSyncPC: UInt32
    public let lastSync: Date?
    public let lastSuccessfulSync: Date?

    public init(lastSyncPC: UInt32, lastSync: Date?, lastSuccessfulSync: Date?) {
        self.lastSyncPC = lastSyncPC
        self.lastSync = lastSync
        self.lastSuccessfulSync = lastSuccessfulSync
    }

    /// true if the Palm's change flags are relative to the last sync with
    /// the computer `pcId`: then the changed records are enough (fast
    /// sync). Otherwise every record has to be compared (slow sync).
    public func canFastSync(withPC pcId: UInt32) -> Bool {
        pcId != 0 && lastSyncPC == pcId
    }
}

/// Four-character codes ("appl", "DATA") as the Palm stores them: a
/// big-endian 32-bit number.
public enum FourCC {
    public static func string(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        // printable ASCII as is; anything else as a byte from Latin-1, so the
        // conversion never fails
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    public static func value(_ string: String) -> UInt32? {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | $1.value }
    }
}

/// Record data travels as hex in the session's JSON lines and commands.
public enum Hex {
    public static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// nil for an odd length or anything that is not a hex digit
    public static func decode(_ hex: String) -> Data? {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var data = Data(capacity: utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}
