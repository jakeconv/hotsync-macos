import Foundation

/// One instruction to `hotsync-session` (a line on its stdin). The tool
/// reads them only after it reported `connected`.
public enum SessionCommand: Equatable, Sendable {
    case install(path: String)
    /// A Palm without a user takes this identity.
    case setUser(id: UInt32, name: String)
    /// A line in the Palm's HotSync log.
    case log(String)
    case backup(directory: String)
    case getROM(directory: String)

    // Records - for syncing. At most one database is open at a time; every
    // record command applies to it.

    /// All databases in RAM: `database` events, then `databaseListFinished`.
    case listDatabases
    /// Opens a database, its private records included: `databaseOpened`.
    case openDatabase(name: String, writable: Bool)
    case closeDatabase
    /// Every record: `record` events, then `recordsFinished`.
    case readAllRecords
    /// Only the records changed, deleted or archived since the last sync.
    case readChangedRecords
    /// Adds a record (`id` 0: the Palm assigns one) or replaces the one with
    /// this ID: `recordWritten` with the ID.
    case writeRecord(id: UInt32, attributes: PalmRecordAttributes, category: Int, data: Data)
    case deleteRecord(id: UInt32)
    /// The AppInfo block (category names, among others): `appInfo`.
    case readAppInfo
    case writeAppInfo(Data)
    /// After a successful sync: removes deleted and archived records and
    /// clears the dirty flags: `flagsReset`.
    case resetSyncFlags
    /// Which computer synced last: `syncInfo`.
    case syncInfo
    /// After a successful sync: this computer (never 0) synced, now.
    case setSyncPC(UInt32)

    case end

    /// The line as the tool reads it, without the newline. nil if the values
    /// cannot be sent: a category outside 0...15, an ID 0 where one is
    /// needed, an empty AppInfo block, or a line break in a text.
    public var line: String? {
        switch self {
        case .install(let path):
            return Self.single("install", path)
        case .setUser(let id, let name):
            guard id != 0 else { return nil }
            return Self.single("setuser \(id)", name)
        case .log(let text):
            return Self.single("log", text)
        case .backup(let directory):
            return Self.single("backup", directory)
        case .getROM(let directory):
            return Self.single("getrom", directory)
        case .listDatabases:
            return "listdbs"
        case .openDatabase(let name, let writable):
            return Self.single("opendb \(writable ? "write" : "read")", name)
        case .closeDatabase:
            return "closedb"
        case .readAllRecords:
            return "readall"
        case .readChangedRecords:
            return "readchanged"
        case .writeRecord(let id, let attributes, let category, let data):
            guard (0...15).contains(category) else { return nil }
            return "writerec \(id) \(attributes.rawValue) \(category) \(Hex.encode(data))"
        case .deleteRecord(let id):
            guard id != 0 else { return nil }
            return "deleterec \(id)"
        case .readAppInfo:
            return "readappinfo"
        case .writeAppInfo(let data):
            guard !data.isEmpty else { return nil }
            return "writeappinfo \(Hex.encode(data))"
        case .resetSyncFlags:
            return "resetflags"
        case .syncInfo:
            return "syncinfo"
        case .setSyncPC(let id):
            guard id != 0 else { return nil }
            return "setsyncpc \(id)"
        case .end:
            return "end"
        }
    }

    /// "<command> <text>" - a text with a line break would end the command
    /// early and turn the rest into a command of its own.
    private static func single(_ command: String, _ text: String) -> String? {
        guard !text.contains(where: \.isNewline) else { return nil }
        return "\(command) \(text)"
    }
}
