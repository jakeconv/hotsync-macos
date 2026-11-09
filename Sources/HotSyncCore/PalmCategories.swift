import Foundation

/// The categories at the start of the AppInfo block of a Palm database
/// (`readappinfo`), the same in every categorised database:
///
///   renamed          16 bits, one per category: changed since the last sync
///   names            16 × 16 bytes, Windows-1252, NUL-padded ("" = unused)
///   IDs              16 bytes, unique per database
///   last unique ID   the last ID the Palm handed out
///   padding          1 byte
///   ...              what the application keeps after it (`extra`)
///
/// Category 0 is "Unfiled". IDs 0...127 are the Palm's own, 128...255 are
/// for categories a desktop creates.
public struct PalmCategories: Equatable, Sendable {
    public static let count = 16
    /// Bytes before `extra`.
    public static let size = 2 + 16 * 16 + 16 + 2
    public static let maximumNameLength = 15

    public var renamed: UInt16
    /// 16 bytes each, as stored (what follows the NUL is kept, too).
    private var nameBytes: [[UInt8]]
    public private(set) var ids: [UInt8]
    public var lastUniqueID: UInt8
    public var padding: UInt8
    /// The application's own settings after the categories (the Date Book's
    /// start of the week, ...), kept as found.
    public var extra: Data

    public init(appInfo: Data) throws {
        let bytes = [UInt8](appInfo)
        guard bytes.count >= Self.size else { throw PalmRecordError.appInfoTooShort(bytes: bytes.count) }
        renamed = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        nameBytes = (0..<Self.count).map { Array(bytes[2 + 16 * $0 ..< 18 + 16 * $0]) }
        ids = Array(bytes[258..<274])
        lastUniqueID = bytes[274]
        padding = bytes[275]
        extra = Data(bytes[Self.size...])
    }

    public var appInfo: Data {
        var bytes = [UInt8]()
        bytes.appendBigEndian(renamed)
        for name in nameBytes { bytes += name }
        bytes += ids
        bytes.append(lastUniqueID)
        bytes.append(padding)
        bytes += extra
        return Data(bytes)
    }

    /// The name of category `index` (0...15), "" if unused.
    public func name(at index: Int) -> String {
        guard (0..<Self.count).contains(index) else { return "" }
        let bytes = nameBytes[index]
        return PalmText.decode(bytes.prefix { $0 != 0 })
    }

    public func id(at index: Int) -> UInt8? {
        (0..<Self.count).contains(index) ? ids[index] : nil
    }

    /// The categories in use, by index.
    public var used: [(index: Int, id: UInt8, name: String)] {
        (0..<Self.count).compactMap { index in
            let label = self.name(at: index)
            return label.isEmpty ? nil : (index, ids[index], label)
        }
    }

    /// The index of the category with this name, exactly as the Palm stores
    /// it (as far as the Palm can hold it: at most 15 characters of
    /// Windows-1252). Case matters, as on the Palm.
    public func index(named name: String) -> Int? {
        let wanted = Self.palmName(name)
        guard !wanted.isEmpty else { return nil }
        return (0..<Self.count).first { self.name(at: $0) == wanted }
    }

    /// Adds a category in the first unused place, with the first ID free
    /// for a desktop (128...255), and marks it renamed. Returns its index,
    /// the existing index if there is one with that name already, or nil if
    /// all 16 are used (or the name is empty).
    public mutating func add(named name: String) -> Int? {
        if let existing = index(named: name) { return existing }
        let palmName = Self.palmName(name)
        guard !palmName.isEmpty,
              let index = (1..<Self.count).first(where: { self.name(at: $0).isEmpty }),
              let id = (UInt8(128)...UInt8(255)).first(where: { !ids.contains($0) }) else { return nil }
        setName(palmName, at: index)
        ids[index] = id
        return index
    }

    /// Renames category `index` (not 0, "Unfiled") and marks it renamed.
    public mutating func rename(at index: Int, to name: String) {
        guard (1..<Self.count).contains(index) else { return }
        setName(Self.palmName(name), at: index)
    }

    private mutating func setName(_ name: String, at index: Int) {
        var bytes = PalmText.encode(name)
        bytes += [UInt8](repeating: 0, count: 16 - bytes.count)
        nameBytes[index] = bytes
        renamed |= 1 << UInt16(index)
    }

    /// What the Palm keeps of a name: Windows-1252, at most 15 bytes.
    public static func palmName(_ name: String) -> String {
        PalmText.decode(PalmText.encode(name).prefix(maximumNameLength))
    }
}
