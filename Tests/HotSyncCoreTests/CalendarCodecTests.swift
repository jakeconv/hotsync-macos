import Foundation
import Testing
@testable import HotSyncCore

// Records as the Palms wrote them: test events made for this on a Palm Z22
// (Palm OS 5.4.9, CalendarDB-PDat and its DatebookDB copy) and a Handspring
// Visor (Palm OS 3.1, DatebookDB with Datebook+). See
// docs/calendar-sync-plan.md for what they showed.

private enum Fixture {
    // Z22, CalendarDB-PDat
    static let daily = "08000900f56a740005000108f59f010000d24461696c7900546869732069732061207465737400"
    static let everyTwoDays = "0c000d00f56b3ce001fff59f020000d20002f59df56d457665727920322064617973004f6e65206f6666206e6f7465207465737400"
    static let lastFriday = "07000800f57b240003fff79f012100d24d6f6e746c79206c6173742066726900"
    static let weekly = "0a000b00f5692c800212ffff010200000001f6245765656b6c7900"
    static let yearly = "0a000b00f599240005ffffff010000d2596561726c7900"
    static let secondTuesday = "0d000e00f58824000312ffff010900d24d6f6e74686c7920326e64205475657300"
    static let monthly = "0f001000f56f240004ffffff010000d24d6f6e746c7900"
    static let detached = "0c000d00f59d56030500457665727920322064617973004f6e65206f6666206e6f7465207465737400696e7465726e657400"
    static let noTime = "fffffffff59c04444e6f2074696d650042643031000400010000"
    static let timeZone = "10001100f59f06482074696d65207a6f6e65207465737400686f6d6500426430300016fe98020000040200040a003c17804368696361676f00"
    static let allDay = "08001200f62104004461796c6f6e6700"
    static let otherCategory = "0b000c00f62246000700536f6d657468696e6720696e206120646966666572656e742063617465676f7279004f666669636500"
    // Z22, the same detached occurrence in DatebookDB: no location
    static let detachedDatebook = "0c000d00f59d54030500457665727920322064617973004f6e65206f6666206e6f7465207465737400"
    // Visor, DatebookDB
    static let visorDaily = "0c000d00f5772cda0103f761010000000001f59a4461696c7900"
    static let visorWeekly = "13001400f57824e60203ffff010400005765656b6c7900"
    static let visorSecondTuesday = "08000900f58824d20303f67f010900004d6f6e74686c7920326e6420205475657300"
    static let visorLastFriday = "12001300f59924de0303ffff012100004d6f6e74686c79206c6173742066726964617900"
    static let visorYearly = "08000900f59924e20503f98101000000596561726c7900"
    static let visorDetached = "0e000f00f59354ce05005765656b6c79005465737400"
    // Datebook+ (DateBk) on the Visor: flag 0x02 and "##c" in the note.
    // Layout as found, text made up.
    static let dateBk = "fffffffff56416c14578616d706c65002323630a00"

    static let calendar = [daily, everyTwoDays, lastFriday, weekly, yearly, secondTuesday, monthly,
                           detached, noTime, timeZone, allDay, otherCategory]
    static let datebook = [detachedDatebook, visorDaily, visorWeekly, visorSecondTuesday,
                           visorLastFriday, visorYearly, visorDetached, dateBk]
}

private func data(_ hex: String) -> Data { Hex.decode(hex)! }

private func event(_ hex: String, _ format: PalmCalendarFormat) throws -> PalmEvent {
    try PalmEvent(record: data(hex), format: format)
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> PalmDate {
    PalmDate(year: year, month: month, day: day)
}

// MARK: - Round trip

/// Every record comes back byte for byte, the bytes the Palm leaves
/// uncleared included.
@Test(arguments: Fixture.calendar)
func calendarRecordsRoundTrip(_ hex: String) throws {
    #expect(Hex.encode(try event(hex, .calendar).encoded(format: .calendar)) == hex)
}

@Test(arguments: Fixture.datebook)
func datebookRecordsRoundTrip(_ hex: String) throws {
    #expect(Hex.encode(try event(hex, .datebook).encoded(format: .datebook)) == hex)
}

// MARK: - Decoding

@Test func dailyWithAlarmAndNote() throws {
    let e = try event(Fixture.daily, .calendar)
    #expect(e.date == day(2026, 11, 10))
    #expect(e.start == PalmTime(hour: 8, minute: 0))
    #expect(e.end == PalmTime(hour: 9, minute: 0))
    #expect(e.title == "Daily")
    #expect(e.note == "This is a test")
    #expect(e.location == nil)
    #expect(e.alarm == PalmAlarm(advance: 5, unit: .minutes))
    #expect(e.alarm?.minutesBefore == 5)
    let r = try #require(e.repetition)
    #expect(r.kind == .daily)
    #expect(r.frequency == 1)
    #expect(r.end == day(2026, 12, 31))
    #expect(e.exceptions.isEmpty)
    #expect(!e.isUntimed)
}

@Test func everyTwoDaysWithTwoExceptions() throws {
    let e = try event(Fixture.everyTwoDays, .calendar)
    #expect(e.repetition?.kind == .daily)
    #expect(e.repetition?.frequency == 2)
    #expect(e.exceptions == [day(2026, 12, 29), day(2026, 11, 13)])
    #expect(e.note == "One off note test")
    #expect(e.extraFlags == 0x00E0)  // the low byte the Palm does not clear
}

@Test func weeklyOnMondayWithException() throws {
    let e = try event(Fixture.weekly, .calendar)
    let r = try #require(e.repetition)
    #expect(r.kind == .weekly)
    #expect(r.weekdays == [1])
    #expect(r.startOfWeek == 0)
    #expect(r.end == nil)
    #expect(e.exceptions == [day(2027, 1, 4)])
    // the Visor's weekly event: Tuesday
    #expect(try event(Fixture.visorWeekly, .datebook).repetition?.weekdays == [2])
}

@Test func monthlyByWeekday() throws {
    let second = try #require(try event(Fixture.secondTuesday, .calendar).repetition)
    #expect(second.kind == .monthlyByDay)
    #expect(second.week == 1)
    #expect(second.weekday == 2)
    let last = try #require(try event(Fixture.lastFriday, .calendar).repetition)
    #expect(last.kind == .monthlyByDay)
    #expect(last.week == 4)  // the last one
    #expect(last.weekday == 5)
    #expect(last.end == day(2027, 12, 31))
    #expect(try event(Fixture.visorLastFriday, .datebook).repetition?.repeatOn == 33)
}

@Test func monthlyByDateAndYearly() throws {
    let monthly = try event(Fixture.monthly, .calendar)
    #expect(monthly.repetition?.kind == .monthlyByDate)
    #expect(monthly.date == day(2026, 11, 15))
    let yearly = try event(Fixture.yearly, .calendar)
    #expect(yearly.repetition?.kind == .yearly)
    #expect(yearly.date == day(2026, 12, 25))
    #expect(try event(Fixture.visorYearly, .datebook).repetition?.end == day(2028, 12, 1))
}

/// Order of the texts: description, note, location.
@Test func detachedOccurrenceWithNoteAndLocation() throws {
    let e = try event(Fixture.detached, .calendar)
    #expect(e.date == day(2026, 12, 29))
    #expect(e.title == "Every 2 days")
    #expect(e.note == "One off note test")
    #expect(e.location == "internet")
    #expect(e.alarm?.minutesBefore == 5)
    #expect(e.repetition == nil)
}

@Test func untimedWithMarker() throws {
    let e = try event(Fixture.noTime, .calendar)
    #expect(e.isUntimed)
    #expect(e.date == day(2026, 12, 28))
    #expect(e.blocks == [PalmEventBlock.untimedMarker])
    #expect(e.timeZone == nil)
}

/// "All day" on Palm OS 5 is a timed event over the day's hours.
@Test func allDayIsTimed() throws {
    let e = try event(Fixture.allDay, .calendar)
    #expect(!e.isUntimed)
    #expect(e.start == PalmTime(hour: 8, minute: 0))
    #expect(e.end == PalmTime(hour: 18, minute: 0))
}

@Test func timeZoneBlock() throws {
    var e = try event(Fixture.timeZone, .calendar)
    #expect(e.title == " time zone test")
    #expect(e.location == "home")
    #expect(e.start == PalmTime(hour: 16, minute: 0))
    let zone = try #require(e.timeZone)
    #expect(zone.offsetMinutes == -360)
    #expect(zone.name == "Chicago")
    #expect(zone.rules == data("020000040200040a003c1780"))
    #expect(zone.block == e.blocks[0])

    e.timeZone = nil
    #expect(e.blocks.isEmpty)
    e.timeZone = PalmTimeZone(offsetMinutes: -300, rules: zone.rules, name: "New York")
    #expect(e.timeZone?.name == "New York")
    #expect(e.timeZone?.offsetMinutes == -300)
    #expect(try PalmEvent(record: e.encoded(format: .calendar), format: .calendar) == e)
}

@Test func categoryEventWithLocation() throws {
    let e = try event(Fixture.otherCategory, .calendar)
    #expect(e.title == "Something in a different category")
    #expect(e.location == "Office")
    #expect(e.alarm?.minutesBefore == 7)
}

/// The DatebookDB copy on Palm OS 5 is the same record without the
/// location.
@Test func datebookCopyOfACalendarRecord() throws {
    let calendar = try event(Fixture.detached, .calendar)
    let datebook = try event(Fixture.detachedDatebook, .datebook)
    #expect(datebook.location == nil)
    #expect(datebook.title == calendar.title)
    #expect(datebook.note == calendar.note)
    #expect(datebook.alarm == calendar.alarm)
    #expect(calendar.encoded(format: .datebook) == data(Fixture.detachedDatebook))
}

/// DateBk's own flag bits and "##" note lines stay as they are.
@Test func dateBkDataKept() throws {
    let e = try event(Fixture.dateBk, .datebook)
    #expect(e.title == "Example")
    #expect(e.note == "##c\n")
    #expect(e.extraFlags == 0x02C1)
    #expect(e.isUntimed)
}

@Test func alarmUnits() {
    #expect(PalmAlarm(advance: 1, unit: .days).minutesBefore == 1440)
    #expect(PalmAlarm(advance: 2, unit: .hours).minutesBefore == 120)
    #expect(PalmAlarm(advance: 0, unit: .minutes).minutesBefore == 0)
    #expect(PalmAlarm(advance: 1, unitCode: 9).minutesBefore == nil)
}

// MARK: - New events

@Test func newTimedEventEncodes() {
    let e = PalmEvent(date: day(2026, 11, 2), start: PalmTime(hour: 10, minute: 0),
                      end: PalmTime(hour: 10, minute: 30), title: "Call")
    #expect(Hex.encode(e.encoded(format: .datebook)) == "0a000a1ef562040043616c6c00")
    #expect(e.encoded(format: .calendar) == e.encoded(format: .datebook))
}

@Test func newUntimedEventLikeThePalmMakesIt() {
    let e = PalmEvent(date: day(2026, 12, 28), title: "No time", blocks: [.untimedMarker])
    // as the Z22 wrote it, but with the low flag byte cleared
    #expect(Hex.encode(e.encoded(format: .calendar)) == "fffffffff59c04004e6f2074696d650042643031000400010000")
    // DatebookDB has no blocks
    #expect(Hex.encode(e.encoded(format: .datebook)) == "fffffffff59c04004e6f2074696d6500")
}

@Test func newRepeatingEventRoundTrips() throws {
    let e = PalmEvent(date: day(2027, 1, 4), start: PalmTime(hour: 9, minute: 15),
                      end: PalmTime(hour: 10, minute: 0), title: "Stand-up", note: "Room 2",
                      location: "Office", alarm: PalmAlarm(advance: 10, unit: .minutes),
                      repetition: .weekly(on: [1, 3], end: day(2027, 6, 30)),
                      exceptions: [day(2027, 1, 6)])
    #expect(e.repetition?.repeatOn == 0b0000_1010)
    for format in [PalmCalendarFormat.calendar, .datebook] {
        var expected = e
        if format == .datebook { expected.location = nil }
        #expect(try PalmEvent(record: e.encoded(format: format), format: format) == expected)
    }
    #expect(PalmRepeat.monthly(week: 4, weekday: 5).repeatOn == 33)
}

/// A flag the format defines is set from the fields, never from
/// `extraFlags`.
@Test func flagsFollowTheFields() throws {
    var e = try event(Fixture.daily, .calendar)
    e.note = nil
    e.alarm = nil
    let decoded = try PalmEvent(record: e.encoded(format: .calendar), format: .calendar)
    #expect(decoded.note == nil)
    #expect(decoded.alarm == nil)
    #expect(decoded.title == "Daily")
}

// MARK: - Broken records

@Test func brokenRecordsThrow() {
    #expect(throws: PalmRecordError.truncated(offset: 2)) {
        try PalmEvent(record: Data([0x0A, 0x00]), format: .datebook)
    }
    // alarm flag, but no alarm
    #expect(throws: PalmRecordError.truncated(offset: 8)) {
        try PalmEvent(record: data("0a000b00f5624000"), format: .datebook)
    }
    // description without its NUL
    #expect(throws: PalmRecordError.unterminatedText(offset: 8)) {
        try PalmEvent(record: data("0a000b00f562040043616c6c"), format: .datebook)
    }
    // exceptions: two announced, one there
    #expect(throws: PalmRecordError.truncated(offset: 12)) {
        try PalmEvent(record: data("0a000b00f56208000002f56d"), format: .datebook)
    }
}

/// Bytes after the texts that are not a whole block stay as they are.
@Test func unknownTrailingBytesKept() throws {
    let hex = "0a000a1ef562040043616c6c00" + "4264"
    let e = try event(hex, .calendar)
    #expect(e.blocks.isEmpty)
    #expect(e.trailing == Data([0x42, 0x64]))
    #expect(Hex.encode(e.encoded(format: .calendar)) == hex)
}

// MARK: - Dates

@Test func palmDates() {
    #expect(PalmDate(rawValue: 0xF56A) == day(2026, 11, 10))
    #expect(day(2026, 11, 10).rawValue == 0xF56A)
    #expect(day(2027, 1, 1).rawValue == 0xF621)
    #expect(day(2026, 12, 31) < day(2027, 1, 1))
    #expect(day(2026, 12, 31).description == "2026-12-31")
    #expect(day(2028, 2, 29).isValid)
    #expect(!day(2027, 2, 29).isValid)
    #expect(!PalmDate(rawValue: 0xFFFF).isValid)
}

@Test func formatDetection() {
    func db(_ name: String) -> PalmDatabaseInfo {
        PalmDatabaseInfo(name: name, type: "DATA", creator: "date", flags: 0, version: 0,
                         modificationNumber: 0, created: nil, modified: nil, backedUp: nil)
    }
    // Palm OS 5.2+: both; the Calendar's own database wins
    #expect(PalmCalendarFormat.detect(in: [db("DatebookDB"), db("CalendarDB-PDat")]) == .calendar)
    #expect(PalmCalendarFormat.detect(in: [db("MemoDB"), db("DatebookDB")]) == .datebook)
    #expect(PalmCalendarFormat.detect(in: [db("MemoDB")]) == nil)
    #expect(PalmCalendarFormat.calendar.databaseName == "CalendarDB-PDat")
}

// MARK: - Text

@Test func windows1252() {
    #expect(PalmText.encode("Müller €") == [0x4D, 0xFC, 0x6C, 0x6C, 0x65, 0x72, 0x20, 0x80])
    #expect(PalmText.decode([0x4D, 0xFC, 0x6C, 0x6C, 0x65, 0x72, 0x20, 0x80]) == "Müller €")
    #expect(PalmText.encode("“quoted” – ok") == [0x93, 0x71, 0x75, 0x6F, 0x74, 0x65, 0x64, 0x94, 0x20, 0x96, 0x20, 0x6F, 0x6B])
    // what the Palm cannot hold
    #expect(PalmText.representable("Party 🎉") == "Party ?")
    #expect(PalmText.representable("東京") == "??")
    #expect(PalmText.encode("a\u{0}b") == [0x61, 0x3F, 0x62])
    // "é" as e + combining accent is one character
    #expect(PalmText.encode("e\u{0301}") == [0xE9])
}

/// Every byte, including the five Windows-1252 leaves undefined, comes back.
@Test func windows1252IsLosslessForPalmBytes() {
    let all = (1...255).map { UInt8($0) }
    #expect(PalmText.encode(PalmText.decode(all)) == all)
}

// MARK: - Categories

/// Modelled on the Z22: Unfiled, Business, Personal and a new " Test" (with
/// ID 17), all four marked renamed, followed by Calendar settings.
private func z22AppInfo() -> Data {
    var bytes: [UInt8] = [0x00, 0x0F]
    for name in ["Unfiled", "Business", "Personal", " Test"] + Array(repeating: "", count: 12) {
        let encoded = Array(name.utf8)
        bytes += encoded + [UInt8](repeating: 0, count: 16 - encoded.count)
    }
    bytes += [0, 1, 2, 17, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    bytes += [17, 0]
    bytes += [0x00, 0x0F, 0x00, 0x01, 0x02, 0x04, 0x00, 0x00]
    return Data(bytes)
}

@Test func categoriesDecode() throws {
    let categories = try PalmCategories(appInfo: z22AppInfo())
    #expect(categories.name(at: 0) == "Unfiled")
    #expect(categories.name(at: 3) == " Test")
    #expect(categories.name(at: 4) == "")
    #expect(categories.id(at: 3) == 17)
    #expect(categories.lastUniqueID == 17)
    #expect(categories.renamed == 0x000F)
    #expect(categories.used.map { $0.name } == ["Unfiled", "Business", "Personal", " Test"])
    #expect(categories.extra == Data([0x00, 0x0F, 0x00, 0x01, 0x02, 0x04, 0x00, 0x00]))
    #expect(categories.appInfo == z22AppInfo())
}

@Test func categoryLookupIsExact() throws {
    let categories = try PalmCategories(appInfo: z22AppInfo())
    #expect(categories.index(named: "Business") == 1)
    #expect(categories.index(named: "business") == nil)
    #expect(categories.index(named: "Test") == nil)  // the Palm's has a leading space
    #expect(categories.index(named: " Test") == 3)
    #expect(categories.index(named: "") == nil)
}

@Test func addingCategories() throws {
    var categories = try PalmCategories(appInfo: z22AppInfo())
    let added = categories.add(named: "Work")
    let work = try #require(added)
    #expect(work == 4)
    #expect(categories.id(at: 4) == 128)  // first desktop ID
    #expect(categories.renamed & (1 << 4) != 0)
    let again = categories.add(named: "Work")
    #expect(again == 4)  // already there
    // at most 15 bytes, as the Palm keeps it
    let addedLong = categories.add(named: "A very long calendar name")
    let long = try #require(addedLong)
    #expect(categories.name(at: long) == "A very long cal")
    #expect(categories.id(at: long) == 129)
    #expect(categories.index(named: "A very long calendar name") == long)

    let reread = try PalmCategories(appInfo: categories.appInfo)
    #expect(reread == categories)

    // all 16 used
    for i in 0..<10 { _ = categories.add(named: "C\(i)") }
    #expect(categories.used.count == 16)
    let oneMore = categories.add(named: "One more")
    #expect(oneMore == nil)
}

@Test func renamingCategories() throws {
    var categories = try PalmCategories(appInfo: z22AppInfo())
    categories.renamed = 0
    categories.rename(at: 3, to: "Test")
    #expect(categories.name(at: 3) == "Test")
    #expect(categories.renamed == 1 << 3)
    categories.rename(at: 0, to: "Nope")  // "Unfiled" stays
    #expect(categories.name(at: 0) == "Unfiled")
}

@Test func appInfoTooShort() {
    #expect(throws: PalmRecordError.appInfoTooShort(bytes: 10)) {
        try PalmCategories(appInfo: Data(count: 10))
    }
}
