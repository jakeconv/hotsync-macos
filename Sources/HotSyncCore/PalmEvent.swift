import Foundation

// The calendar records of a Palm, in the two formats it uses:
//
//   DatebookDB       the Date Book, Palm OS 1 to 5 (on Palm OS 5.2 and
//                    later a copy the OS keeps for older applications)
//   CalendarDB-PDat  the Calendar of Palm OS 5.2 and later: the same layout
//                    plus a location and tagged blocks (time zone, ...)
//
// Layout (big-endian):
//   start hour, start minute, end hour, end minute   0xFF 0xFF: no time
//   date                    year-1904 (7 bits), month (4), day (5)
//   flags (16 bits)         high byte: 0x40 alarm, 0x20 repeat, 0x10 note,
//                           0x08 exceptions, 0x04 description,
//                           0x02 location (CalendarDB-PDat only); the
//                           rest is not defined, but used by others (DateBk
//                           sets 0x02/0x01 in DatebookDB) or never cleared
//                           (the low byte holds random values): kept as is
//   alarm                   advance (signed), unit (0 min, 1 h, 2 days)
//   repeat (8 bytes)        type, reserved, end date (0xFFFF: none),
//                           frequency, repeatOn, start of week, reserved
//   exceptions              count (16 bits), dates
//   description, note, location   C strings, Windows-1252
//   blocks (CalendarDB-PDat)      4-character tag, length (16 bits), data
//
// Found on real Palms (Visor, TX, Z22): see docs/calendar-sync-plan.md.

/// Which calendar database a Palm uses.
public enum PalmCalendarFormat: Equatable, Sendable {
    /// `DatebookDB`: no locations, no time zones; categories only on
    /// Palm OS 5.
    case datebook
    /// `CalendarDB-PDat`: Palm OS 5.2 and later.
    case calendar

    public var databaseName: String {
        switch self {
        case .datebook: return "DatebookDB"
        case .calendar: return "CalendarDB-PDat"
        }
    }

    /// The format to sync, from the Palm's database list: `CalendarDB-PDat`
    /// where it exists (the `DatebookDB` next to it is only a copy), else
    /// `DatebookDB`; nil if there is neither.
    public static func detect(in databases: [PalmDatabaseInfo]) -> PalmCalendarFormat? {
        let names = Set(databases.map(\.name))
        if names.contains(PalmCalendarFormat.calendar.databaseName) { return .calendar }
        if names.contains(PalmCalendarFormat.datebook.databaseName) { return .datebook }
        return nil
    }

    /// The flag bits this format defines (16 bits, see the layout above).
    var knownFlags: UInt16 {
        switch self {
        case .datebook: return 0x7C00
        case .calendar: return 0x7E00
        }
    }
}

/// A date as the Palm stores it: 1904...2031.
public struct PalmDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(rawValue: UInt16) {
        year = 1904 + Int(rawValue >> 9)
        month = Int((rawValue >> 5) & 0x0F)
        day = Int(rawValue & 0x1F)
    }

    public var rawValue: UInt16 {
        UInt16(truncatingIfNeeded: ((year - 1904) & 0x7F) << 9 | (month & 0x0F) << 5 | (day & 0x1F))
    }

    /// A real day the Palm can store.
    public var isValid: Bool {
        guard (1904...2031).contains(year), (1...12).contains(month), day >= 1 else { return false }
        let days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return day <= (month == 2 && leap ? 29 : days)
    }

    public static func < (a: PalmDate, b: PalmDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A time of day on the Palm.
public struct PalmTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public static func < (a: PalmTime, b: PalmTime) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }

    public var description: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// The Palm's one alarm per event: `advance` units before the start.
public struct PalmAlarm: Equatable, Sendable {
    public enum Unit: UInt8, Sendable {
        case minutes = 0
        case hours = 1
        case days = 2
    }

    public var advance: Int
    /// As stored; `unit` is nil for a value the Palm does not define.
    public var unitCode: UInt8

    public init(advance: Int, unit: Unit) {
        self.advance = advance
        self.unitCode = unit.rawValue
    }

    init(advance: Int, unitCode: UInt8) {
        self.advance = advance
        self.unitCode = unitCode
    }

    public var unit: Unit? { Unit(rawValue: unitCode) }

    /// How long before the start, nil for an unknown unit.
    public var minutesBefore: Int? {
        switch unit {
        case .minutes: return advance
        case .hours: return advance * 60
        case .days: return advance * 24 * 60
        case nil: return nil
        }
    }
}

/// How an event repeats.
public struct PalmRepeat: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case daily = 1
        case weekly = 2
        /// e.g. the 2nd Tuesday, or the last Friday (`week` 4)
        case monthlyByDay = 3
        /// the same day of the month
        case monthlyByDate = 4
        case yearly = 5
    }

    /// As stored; `kind` is nil for a value the Palm does not define.
    public var typeCode: UInt8
    /// Every `frequency` days / weeks / months / years.
    public var frequency: Int
    /// The last day it can occur, nil: no end.
    public var end: PalmDate?
    /// weekly: the days as bits (bit 0 Sunday); monthly by day: week × 7 +
    /// weekday (week 0...3, 4 = the last one; weekday 0 = Sunday)
    public var repeatOn: UInt8
    /// weekly: 0 Sunday, 1 Monday
    public var startOfWeek: UInt8
    /// Not defined, not cleared by the Palm (seen 0x03, 0x08, 0xFF, 0xD2):
    /// kept so a record comes back unchanged.
    public var reserved1: UInt8 = 0
    public var reserved2: UInt8 = 0

    public init(kind: Kind, frequency: Int = 1, end: PalmDate? = nil,
                repeatOn: UInt8 = 0, startOfWeek: UInt8 = 0) {
        self.typeCode = kind.rawValue
        self.frequency = frequency
        self.end = end
        self.repeatOn = repeatOn
        self.startOfWeek = startOfWeek
    }

    init(typeCode: UInt8, frequency: Int, end: PalmDate?, repeatOn: UInt8, startOfWeek: UInt8,
         reserved1: UInt8, reserved2: UInt8) {
        self.typeCode = typeCode
        self.frequency = frequency
        self.end = end
        self.repeatOn = repeatOn
        self.startOfWeek = startOfWeek
        self.reserved1 = reserved1
        self.reserved2 = reserved2
    }

    public var kind: Kind? { Kind(rawValue: typeCode) }

    /// Weekly on these days (0 Sunday ... 6 Saturday).
    public static func weekly(on weekdays: Set<Int>, every frequency: Int = 1, end: PalmDate? = nil,
                              startOfWeek: UInt8 = 0) -> PalmRepeat {
        let bits = weekdays.filter { (0...6).contains($0) }.reduce(UInt8(0)) { $0 | UInt8(1 << $1) }
        return PalmRepeat(kind: .weekly, frequency: frequency, end: end, repeatOn: bits,
                          startOfWeek: startOfWeek)
    }

    /// Monthly on the `week`-th `weekday` (week 0...3, 4 = the last one).
    public static func monthly(week: Int, weekday: Int, every frequency: Int = 1,
                               end: PalmDate? = nil) -> PalmRepeat {
        PalmRepeat(kind: .monthlyByDay, frequency: frequency, end: end,
                   repeatOn: UInt8(clamping: week * 7 + weekday))
    }

    /// weekly: the days (0 Sunday ... 6 Saturday)
    public var weekdays: Set<Int> {
        Set((0...6).filter { repeatOn & UInt8(1 << $0) != 0 })
    }

    /// monthly by day: 0...3 for the 1st to 4th, 4 for the last
    public var week: Int { Int(repeatOn) / 7 }

    /// monthly by day: 0 Sunday ... 6 Saturday
    public var weekday: Int { Int(repeatOn) % 7 }
}

/// A tagged block at the end of a `CalendarDB-PDat` record.
public struct PalmEventBlock: Equatable, Sendable {
    /// four characters, e.g. "Bd00"
    public var tag: UInt32
    public var data: Data

    public init(tag: UInt32, data: Data) {
        self.tag = tag
        self.data = data
    }

    /// The event's time zone (see `PalmTimeZone`).
    public static let timeZoneTag: UInt32 = 0x4264_3030  // "Bd00"
    /// Added by the Calendar of Palm OS 5 to every event it creates without a
    /// time; older untimed events work without it.
    public static let untimedTag: UInt32 = 0x4264_3031  // "Bd01"
    public static let untimedMarker = PalmEventBlock(tag: untimedTag, data: Data([0x00, 0x01, 0x00, 0x00]))
}

/// The `Bd00` block: the time zone an event's times are in. A Palm set to
/// New York shows 16:00 "Chicago" as 17:00.
public struct PalmTimeZone: Equatable, Sendable {
    /// From UTC, without daylight saving: -360 for Chicago.
    public var offsetMinutes: Int
    /// Daylight-saving rules as the Palm stores them (12 bytes). Those of
    /// Palm OS 5.4 predate the US rules of 2007: use `name` and
    /// `offsetMinutes` to find the zone on the Mac instead.
    public var rules: Data
    /// The city the Palm names the zone after, e.g. "Chicago".
    public var name: String

    public init(offsetMinutes: Int, rules: Data, name: String) {
        self.offsetMinutes = offsetMinutes
        self.rules = rules
        self.name = name
    }

    /// nil if the block is not a time zone of this layout
    public init?(block: PalmEventBlock) {
        let bytes = [UInt8](block.data)
        guard block.tag == PalmEventBlock.timeZoneTag, bytes.count >= 15,
              let nul = bytes[14...].firstIndex(of: 0), nul == bytes.count - 1 else { return nil }
        offsetMinutes = Int(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        rules = Data(bytes[2..<14])
        name = PalmText.decode(bytes[14..<nul])
    }

    public var block: PalmEventBlock {
        var bytes = [UInt8]()
        bytes.appendBigEndian(UInt16(bitPattern: Int16(clamping: offsetMinutes)))
        var ruleBytes = [UInt8](rules.prefix(12))
        ruleBytes += [UInt8](repeating: 0, count: 12 - ruleBytes.count)
        bytes += ruleBytes
        bytes += PalmText.encode(name)
        bytes.append(0)
        return PalmEventBlock(tag: PalmEventBlock.timeZoneTag, data: Data(bytes))
    }
}

public enum PalmRecordError: Error, Equatable {
    /// the record ends before this byte
    case truncated(offset: Int)
    /// a text starting at this byte has no terminating NUL
    case unterminatedText(offset: Int)
    /// an AppInfo block too short for the 16 categories
    case appInfoTooShort(bytes: Int)
}

/// One event of the Palm's calendar, in either format.
public struct PalmEvent: Equatable, Sendable {
    public var date: PalmDate
    /// nil (with `end`): an event without a time ("no time")
    public var start: PalmTime?
    public var end: PalmTime?
    public var alarm: PalmAlarm?
    public var repetition: PalmRepeat?
    /// Days a repeating event does not occur: deleted there, or changed (then
    /// a separate event on that day holds the changed occurrence).
    public var exceptions: [PalmDate]
    /// What the Palm calls the description: the event's text.
    public var title: String?
    public var note: String?
    /// `CalendarDB-PDat` only.
    public var location: String?
    /// `CalendarDB-PDat` only: time zone, the "no time" marker, and what
    /// else the Palm adds, kept in order.
    public var blocks: [PalmEventBlock]
    /// Flag bits this format does not define, kept as found.
    public var extraFlags: UInt16
    /// Bytes after everything this format defines, kept as found.
    public var trailing: Data

    public init(date: PalmDate, start: PalmTime? = nil, end: PalmTime? = nil, title: String?,
                note: String? = nil, location: String? = nil, alarm: PalmAlarm? = nil,
                repetition: PalmRepeat? = nil, exceptions: [PalmDate] = [],
                blocks: [PalmEventBlock] = []) {
        self.date = date
        self.start = start
        self.end = end
        self.title = title
        self.note = note
        self.location = location
        self.alarm = alarm
        self.repetition = repetition
        self.exceptions = exceptions
        self.blocks = blocks
        self.extraFlags = 0
        self.trailing = Data()
    }

    /// "No time" on the Palm; an all-day event on the Mac.
    public var isUntimed: Bool { start == nil && end == nil }

    /// The `Bd00` block, if any. Setting nil removes it.
    public var timeZone: PalmTimeZone? {
        get { blocks.lazy.compactMap(PalmTimeZone.init(block:)).first }
        set {
            let index = blocks.firstIndex { $0.tag == PalmEventBlock.timeZoneTag }
            switch (newValue, index) {
            case let (zone?, index?): blocks[index] = zone.block
            case let (zone?, nil): blocks.insert(zone.block, at: 0)
            case let (nil, index?): blocks.remove(at: index)
            case (nil, nil): break
            }
        }
    }

    // MARK: Decoding

    public init(record data: Data, format: PalmCalendarFormat) throws {
        var reader = ByteReader(data)
        start = try reader.time()
        end = try reader.time()
        date = PalmDate(rawValue: try reader.uint16())
        let flags = try reader.uint16()
        extraFlags = flags & ~format.knownFlags

        if flags & 0x4000 != 0 {
            let advance = Int(Int8(bitPattern: try reader.uint8()))
            alarm = PalmAlarm(advance: advance, unitCode: try reader.uint8())
        } else {
            alarm = nil
        }
        if flags & 0x2000 != 0 {
            let type = try reader.uint8()
            let reserved1 = try reader.uint8()
            let endRaw = try reader.uint16()
            let frequency = Int(try reader.uint8())
            let repeatOn = try reader.uint8()
            let startOfWeek = try reader.uint8()
            let reserved2 = try reader.uint8()
            repetition = PalmRepeat(typeCode: type, frequency: frequency,
                                    end: endRaw == 0xFFFF ? nil : PalmDate(rawValue: endRaw),
                                    repeatOn: repeatOn, startOfWeek: startOfWeek,
                                    reserved1: reserved1, reserved2: reserved2)
        } else {
            repetition = nil
        }
        if flags & 0x0800 != 0 {
            let count = Int(try reader.uint16())
            var dates = [PalmDate]()
            for _ in 0..<count { dates.append(PalmDate(rawValue: try reader.uint16())) }
            exceptions = dates
        } else {
            exceptions = []
        }
        title = try flags & 0x0400 != 0 ? PalmText.decode(reader.cString()) : nil
        note = try flags & 0x1000 != 0 ? PalmText.decode(reader.cString()) : nil

        var blocks = [PalmEventBlock]()
        if format == .calendar {
            location = try flags & 0x0200 != 0 ? PalmText.decode(reader.cString()) : nil
            // what does not parse as a block stays in `trailing`
            while let block = reader.block() { blocks.append(block) }
        } else {
            location = nil
        }
        self.blocks = blocks
        trailing = Data(reader.rest())
    }

    // MARK: Encoding

    /// The record for the Palm. `DatebookDB` has no place for the location
    /// and the blocks: they are left out.
    public func encoded(format: PalmCalendarFormat) -> Data {
        var flags = extraFlags & ~format.knownFlags
        if alarm != nil { flags |= 0x4000 }
        if repetition != nil { flags |= 0x2000 }
        if note != nil { flags |= 0x1000 }
        if !exceptions.isEmpty { flags |= 0x0800 }
        if title != nil { flags |= 0x0400 }
        if format == .calendar && location != nil { flags |= 0x0200 }

        var bytes = [UInt8]()
        bytes.appendTime(start)
        bytes.appendTime(end)
        bytes.appendBigEndian(date.rawValue)
        bytes.appendBigEndian(flags)
        if let alarm {
            bytes.append(UInt8(bitPattern: Int8(truncatingIfNeeded: alarm.advance)))
            bytes.append(alarm.unitCode)
        }
        if let repetition {
            bytes.append(repetition.typeCode)
            bytes.append(repetition.reserved1)
            bytes.appendBigEndian(repetition.end?.rawValue ?? 0xFFFF)
            bytes.append(UInt8(truncatingIfNeeded: repetition.frequency))
            bytes.append(repetition.repeatOn)
            bytes.append(repetition.startOfWeek)
            bytes.append(repetition.reserved2)
        }
        if !exceptions.isEmpty {
            bytes.appendBigEndian(UInt16(truncatingIfNeeded: exceptions.count))
            for day in exceptions { bytes.appendBigEndian(day.rawValue) }
        }
        if let title { bytes.appendCString(title) }
        if let note { bytes.appendCString(note) }
        if format == .calendar {
            if let location { bytes.appendCString(location) }
            for block in blocks {
                bytes.appendBigEndian(block.tag)
                bytes.appendBigEndian(UInt16(truncatingIfNeeded: block.data.count))
                bytes += block.data
            }
        }
        bytes += trailing
        return Data(bytes)
    }
}

// MARK: - Bytes

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func uint8() throws -> UInt8 {
        guard remaining >= 1 else { throw PalmRecordError.truncated(offset: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() throws -> UInt16 {
        guard remaining >= 2 else { throw PalmRecordError.truncated(offset: offset) }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func uint32() throws -> UInt32 {
        let high = try uint16()
        let low = try uint16()
        return UInt32(high) << 16 | UInt32(low)
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw PalmRecordError.truncated(offset: offset) }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// 0xFF 0xFF is "no time"
    mutating func time() throws -> PalmTime? {
        let hour = try uint8()
        let minute = try uint8()
        return hour == 0xFF && minute == 0xFF ? nil : PalmTime(hour: Int(hour), minute: Int(minute))
    }

    /// The bytes up to the NUL; the NUL is consumed.
    mutating func cString() throws -> [UInt8] {
        guard let nul = bytes[offset...].firstIndex(of: 0) else {
            throw PalmRecordError.unterminatedText(offset: offset)
        }
        defer { offset = nul + 1 }
        return Array(bytes[offset..<nul])
    }

    /// The next tagged block, or nil (and nothing consumed) if what is left
    /// is not one.
    mutating func block() -> PalmEventBlock? {
        let saved = offset
        guard remaining >= 6, let tag = try? uint32(), let length = try? uint16(),
              let data = try? take(Int(length)) else {
            offset = saved
            return nil
        }
        return PalmEventBlock(tag: tag, data: Data(data))
    }

    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        appendBigEndian(UInt16(value >> 16))
        appendBigEndian(UInt16(value & 0xFFFF))
    }

    mutating func appendTime(_ time: PalmTime?) {
        guard let time else {
            append(0xFF)
            append(0xFF)
            return
        }
        append(UInt8(truncatingIfNeeded: time.hour))
        append(UInt8(truncatingIfNeeded: time.minute))
    }

    mutating func appendCString(_ text: String) {
        self += PalmText.encode(text)
        append(0)
    }
}
