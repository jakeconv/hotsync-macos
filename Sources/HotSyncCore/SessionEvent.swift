import Foundation

/// The identity a Palm reports when it connects: user name and user ID as
/// set by the first HotSync. A Palm that was never synced (or hard reset)
/// reports user ID 0 and usually an empty name.
public struct PalmUser: Equatable, Sendable, Codable {
    public let name: String
    public let userId: UInt32

    public init(name: String, userId: UInt32) {
        self.name = name
        self.userId = userId
    }

    /// true for a Palm without a user - it takes the identity of the
    /// profile it is synced with.
    public var isBlank: Bool { userId == 0 }
}

/// One line of `hotsync-session` output (a JSON object per line).
public enum SessionEvent: Equatable, Sendable {
    case listening(port: String)
    case timeout
    case connected(PalmUser, romVersion: UInt32)
    case installing(file: String)
    case progress(bytes: Int)
    case installed(file: String, bytes: Int)
    case failed(file: String, InstallFailure)
    case userWritten(PalmUser)
    /// backup of the RAM databases into this directory: `total` databases
    case backupStarted(directory: String, total: Int)
    /// database `index` of `total` (file name as saved) is being fetched
    case backingUp(file: String, index: Int, total: Int)
    /// database `index` did not change since the last backup: skipped
    case backupUnchanged(file: String, index: Int)
    case backedUp(file: String, bytes: Int)
    case backupFailed(file: String, palmOSError: Int)
    case backupFinished(saved: Int, unchanged: Int, failed: Int)
    /// ROM dump into `file` (name in the folder given): `total` bytes of
    /// Palm OS `version`
    case romStarted(file: String, version: String, total: Int)
    case romProgress(bytes: Int)
    case romFinished(file: String, bytes: Int)
    /// Palm OS 5 and later: the ROM cannot be read over HotSync
    case romUnsupported(version: String)

    // Records (for syncing)

    /// one database of `listdbs`
    case database(PalmDatabaseInfo)
    case databaseListFinished(count: Int)
    case databaseOpened(name: String, records: Int)
    case databaseClosed
    /// one record of `readall` / `readchanged`
    case record(PalmRecord)
    case recordsFinished(count: Int)
    /// written with this ID (the Palm's, for a new record)
    case recordWritten(id: UInt32)
    case recordDeleted(id: UInt32)
    case appInfo(Data)
    case appInfoWritten(bytes: Int)
    case syncFlagsReset
    case syncInfo(PalmSyncInfo)
    case syncPCWritten(UInt32)
    /// A record command failed: `operation` is the command ("opendb",
    /// "writerec", ...), `recordId` the record it was about, if any.
    /// `palmOSError` 0 with `noDatabaseOpen`: no `opendb` before.
    case databaseFailed(operation: String, palmOSError: Int, recordId: UInt32?, noDatabaseOpen: Bool)

    case finished
    case error(stage: String, message: String)

    private struct Line: Decodable {
        let event: String
        let port: String?
        let user: String?
        let userId: UInt32?
        let romVersion: UInt32?
        let file: String?
        let bytes: Int?
        let reason: String?
        let palmOSError: Int?
        let stage: String?
        let message: String?
        let directory: String?
        let index: Int?
        let total: Int?
        let saved: Int?
        let unchanged: Int?
        let failed: Int?
        let version: String?
        // records
        let name: String?
        let id: UInt32?
        let attributes: UInt8?
        let category: Int?
        let data: String?
        let records: Int?
        let count: Int?
        let type: UInt32?
        let creator: UInt32?
        let flags: Int?
        let modnum: Int?
        let createDate: Int64?
        let modifyDate: Int64?
        let backupDate: Int64?
        let lastSyncPC: UInt32?
        let lastSyncDate: Int64?
        let successfulSyncDate: Int64?
        let op: String?
        let dbVersion: Int?

        enum CodingKeys: String, CodingKey {
            case event, port, user, userId, romVersion, file, bytes, reason, palmOSError, stage,
                 message, directory, index, total, saved, unchanged, failed, name, id, attributes,
                 category, data, records, count, type, creator, flags, modnum, createDate,
                 modifyDate, backupDate, lastSyncPC, lastSyncDate, successfulSyncDate, op
            // "version" is a text for the ROM ("4.1.0") and a number for a
            // database: decoded by hand below
            case version
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try c.decode(String.self, forKey: .event)
            port = try c.decodeIfPresent(String.self, forKey: .port)
            user = try c.decodeIfPresent(String.self, forKey: .user)
            userId = try c.decodeIfPresent(UInt32.self, forKey: .userId)
            romVersion = try c.decodeIfPresent(UInt32.self, forKey: .romVersion)
            file = try c.decodeIfPresent(String.self, forKey: .file)
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            palmOSError = try c.decodeIfPresent(Int.self, forKey: .palmOSError)
            stage = try c.decodeIfPresent(String.self, forKey: .stage)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            directory = try c.decodeIfPresent(String.self, forKey: .directory)
            index = try c.decodeIfPresent(Int.self, forKey: .index)
            total = try c.decodeIfPresent(Int.self, forKey: .total)
            saved = try c.decodeIfPresent(Int.self, forKey: .saved)
            unchanged = try c.decodeIfPresent(Int.self, forKey: .unchanged)
            failed = try c.decodeIfPresent(Int.self, forKey: .failed)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            dbVersion = try? c.decodeIfPresent(Int.self, forKey: .version)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            id = try c.decodeIfPresent(UInt32.self, forKey: .id)
            attributes = try c.decodeIfPresent(UInt8.self, forKey: .attributes)
            category = try c.decodeIfPresent(Int.self, forKey: .category)
            data = try c.decodeIfPresent(String.self, forKey: .data)
            records = try c.decodeIfPresent(Int.self, forKey: .records)
            count = try c.decodeIfPresent(Int.self, forKey: .count)
            type = try c.decodeIfPresent(UInt32.self, forKey: .type)
            creator = try c.decodeIfPresent(UInt32.self, forKey: .creator)
            flags = try c.decodeIfPresent(Int.self, forKey: .flags)
            modnum = try c.decodeIfPresent(Int.self, forKey: .modnum)
            createDate = try c.decodeIfPresent(Int64.self, forKey: .createDate)
            modifyDate = try c.decodeIfPresent(Int64.self, forKey: .modifyDate)
            backupDate = try c.decodeIfPresent(Int64.self, forKey: .backupDate)
            lastSyncPC = try c.decodeIfPresent(UInt32.self, forKey: .lastSyncPC)
            lastSyncDate = try c.decodeIfPresent(Int64.self, forKey: .lastSyncDate)
            successfulSyncDate = try c.decodeIfPresent(Int64.self, forKey: .successfulSyncDate)
            op = try c.decodeIfPresent(String.self, forKey: .op)
        }
    }

    /// pilot-link's value for a date the Palm never set (its 1904 epoch,
    /// 0x83DAC000), e.g. the backup date of a database never backed up
    static let palmNeverDate: Int64 = 0x83DA_C000

    /// Unix time from the tool; 0 or less and pilot-link's "never" are nil
    private static func date(_ seconds: Int64?) -> Date? {
        guard let seconds, seconds > 0, seconds != palmNeverDate else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Reads one output line; nil for anything that is not a known event
    /// (the tool only prints events, so nil means a broken line).
    public static func parse(_ line: String) -> SessionEvent? {
        guard let data = line.data(using: .utf8),
              let l = try? JSONDecoder().decode(Line.self, from: data) else {
            return nil
        }
        switch l.event {
        case "listening":
            return .listening(port: l.port ?? "")
        case "timeout":
            return .timeout
        case "connected":
            guard let name = l.user, let userId = l.userId else { return nil }
            return .connected(PalmUser(name: name, userId: userId), romVersion: l.romVersion ?? 0)
        case "installing":
            guard let file = l.file else { return nil }
            return .installing(file: file)
        case "progress":
            return .progress(bytes: l.bytes ?? 0)
        case "installed":
            guard let file = l.file else { return nil }
            return .installed(file: file, bytes: l.bytes ?? 0)
        case "failed":
            guard let file = l.file else { return nil }
            return .failed(file: file, failure(reason: l.reason, palmOSError: l.palmOSError))
        case "userWritten":
            guard let name = l.user, let userId = l.userId else { return nil }
            return .userWritten(PalmUser(name: name, userId: userId))
        case "backupStarted":
            guard let directory = l.directory else { return nil }
            return .backupStarted(directory: directory, total: l.total ?? 0)
        case "backingUp":
            guard let file = l.file, let index = l.index else { return nil }
            return .backingUp(file: file, index: index, total: l.total ?? 0)
        case "backupUnchanged":
            guard let file = l.file, let index = l.index else { return nil }
            return .backupUnchanged(file: file, index: index)
        case "backedUp":
            guard let file = l.file else { return nil }
            return .backedUp(file: file, bytes: l.bytes ?? 0)
        case "backupFailed":
            guard let file = l.file else { return nil }
            return .backupFailed(file: file, palmOSError: l.palmOSError ?? 0)
        case "backupFinished":
            return .backupFinished(saved: l.saved ?? 0, unchanged: l.unchanged ?? 0, failed: l.failed ?? 0)
        case "romStarted":
            guard let file = l.file, let version = l.version, let total = l.total else { return nil }
            return .romStarted(file: file, version: version, total: total)
        case "romProgress":
            guard let bytes = l.bytes else { return nil }
            return .romProgress(bytes: bytes)
        case "romFinished":
            guard let file = l.file, let bytes = l.bytes else { return nil }
            return .romFinished(file: file, bytes: bytes)
        case "romUnsupported":
            return .romUnsupported(version: l.version ?? "")
        case "db":
            guard let name = l.name, let type = l.type, let creator = l.creator else { return nil }
            return .database(PalmDatabaseInfo(
                name: name, type: FourCC.string(type), creator: FourCC.string(creator),
                flags: l.flags ?? 0, version: l.dbVersion ?? 0, modificationNumber: l.modnum ?? 0,
                created: date(l.createDate), modified: date(l.modifyDate), backedUp: date(l.backupDate)))
        case "dbListFinished":
            guard let count = l.count else { return nil }
            return .databaseListFinished(count: count)
        case "dbOpened":
            guard let name = l.name else { return nil }
            return .databaseOpened(name: name, records: l.records ?? 0)
        case "dbClosed":
            return .databaseClosed
        case "record":
            guard let id = l.id, let index = l.index, let attributes = l.attributes,
                  let category = l.category, let hex = l.data, let data = Hex.decode(hex) else { return nil }
            return .record(PalmRecord(id: id, index: index,
                                      attributes: PalmRecordAttributes(rawValue: attributes),
                                      category: category, data: data))
        case "recordsFinished":
            guard let count = l.count else { return nil }
            return .recordsFinished(count: count)
        case "recordWritten":
            guard let id = l.id else { return nil }
            return .recordWritten(id: id)
        case "recordDeleted":
            guard let id = l.id else { return nil }
            return .recordDeleted(id: id)
        case "appInfo":
            guard let hex = l.data, let data = Hex.decode(hex) else { return nil }
            return .appInfo(data)
        case "appInfoWritten":
            return .appInfoWritten(bytes: l.bytes ?? 0)
        case "flagsReset":
            return .syncFlagsReset
        case "syncInfo":
            guard let pc = l.lastSyncPC else { return nil }
            return .syncInfo(PalmSyncInfo(lastSyncPC: pc, lastSync: date(l.lastSyncDate),
                                          lastSuccessfulSync: date(l.successfulSyncDate)))
        case "syncInfoWritten":
            guard let pc = l.lastSyncPC else { return nil }
            return .syncPCWritten(pc)
        case "dbFailed":
            guard let op = l.op else { return nil }
            return .databaseFailed(operation: op, palmOSError: l.palmOSError ?? 0, recordId: l.id,
                                   noDatabaseOpen: l.reason == "noDatabaseOpen")
        case "finished":
            return .finished
        case "error":
            return .error(stage: l.stage ?? "", message: l.message ?? "")
        default:
            return nil
        }
    }

    private static func failure(reason: String?, palmOSError: Int?) -> InstallFailure {
        switch reason {
        case "unreadableFile": return .unreadableFile
        case "notEnoughSpace": return .notEnoughSpace
        default: return InstallFailure.fromPalmOSError(palmOSError ?? 0)
        }
    }
}
