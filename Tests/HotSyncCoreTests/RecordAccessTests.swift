import Foundation
import Testing
@testable import HotSyncCore

// MARK: - Record events

@Test func recordEvent() {
    let line = #"{"event":"record","id":10485761,"index":0,"attributes":80,"category":2,"data":"636c65616e"}"#
    #expect(SessionEvent.parse(line) == .record(PalmRecord(
        id: 0xA0_0001, index: 0, attributes: [.dirty, .secret], category: 2,
        data: Data("clean".utf8))))
}

@Test func recordEventDeletedWithoutData() {
    let line = #"{"event":"record","id":10485763,"index":2,"attributes":128,"category":0,"data":""}"#
    guard case .record(let record) = SessionEvent.parse(line) else {
        Issue.record("not a record")
        return
    }
    #expect(record.data.isEmpty)
    #expect(record.attributes == .deleted)
    #expect(record.isRemoved)
}

@Test func recordEventIncompleteOrBrokenHex() {
    #expect(SessionEvent.parse(#"{"event":"record","id":1,"index":0,"attributes":0,"category":0}"#) == nil)
    #expect(SessionEvent.parse(#"{"event":"record","id":1,"index":0,"attributes":0,"category":0,"data":"abc"}"#) == nil)
    #expect(SessionEvent.parse(#"{"event":"record","id":1,"index":0,"attributes":0,"category":0,"data":"zz"}"#) == nil)
}

@Test func databaseListEvents() {
    let line = #"{"event":"db","name":"DatebookDB","type":1145132097,"creator":1684108389,"flags":0,"version":1,"modnum":42,"createDate":1000000000,"modifyDate":1000000500,"backupDate":0}"#
    #expect(SessionEvent.parse(line) == .database(PalmDatabaseInfo(
        name: "DatebookDB", type: "DATA", creator: "date", flags: 0, version: 1,
        modificationNumber: 42, created: Date(timeIntervalSince1970: 1_000_000_000),
        modified: Date(timeIntervalSince1970: 1_000_000_500), backedUp: nil)))
    #expect(SessionEvent.parse(#"{"event":"dbListFinished","count":2}"#) == .databaseListFinished(count: 2))
}

@Test func databaseEvents() {
    #expect(SessionEvent.parse(#"{"event":"dbOpened","name":"DatebookDB","records":4}"#)
            == .databaseOpened(name: "DatebookDB", records: 4))
    #expect(SessionEvent.parse(#"{"event":"dbClosed"}"#) == .databaseClosed)
    #expect(SessionEvent.parse(#"{"event":"recordsFinished","count":3}"#) == .recordsFinished(count: 3))
    #expect(SessionEvent.parse(#"{"event":"recordWritten","id":10485776,"requestedId":0}"#)
            == .recordWritten(id: 0xA0_0010))
    #expect(SessionEvent.parse(#"{"event":"recordDeleted","id":10485764}"#) == .recordDeleted(id: 0xA0_0004))
    #expect(SessionEvent.parse(#"{"event":"appInfo","data":"0001556e66696c6564"}"#)
            == .appInfo(Data([0x00, 0x01]) + Data("Unfiled".utf8)))
    #expect(SessionEvent.parse(#"{"event":"appInfo","data":""}"#) == .appInfo(Data()))
    #expect(SessionEvent.parse(#"{"event":"appInfoWritten","bytes":6}"#) == .appInfoWritten(bytes: 6))
    #expect(SessionEvent.parse(#"{"event":"flagsReset"}"#) == .syncFlagsReset)
}

@Test func databaseFailedEvents() {
    #expect(SessionEvent.parse(#"{"event":"dbFailed","op":"opendb","error":-301,"palmOSError":5}"#)
            == .databaseFailed(operation: "opendb", palmOSError: 5, recordId: nil, noDatabaseOpen: false))
    #expect(SessionEvent.parse(#"{"event":"dbFailed","op":"deleterec","error":-301,"palmOSError":5,"id":999}"#)
            == .databaseFailed(operation: "deleterec", palmOSError: 5, recordId: 999, noDatabaseOpen: false))
    #expect(SessionEvent.parse(#"{"event":"dbFailed","op":"readall","reason":"noDatabaseOpen"}"#)
            == .databaseFailed(operation: "readall", palmOSError: 0, recordId: nil, noDatabaseOpen: true))
    #expect(SessionEvent.parse(#"{"event":"dbFailed"}"#) == nil)
}

@Test func syncInfoEvents() {
    let line = #"{"event":"syncInfo","lastSyncPC":1234567,"lastSyncDate":1000000100,"successfulSyncDate":0}"#
    let info = PalmSyncInfo(lastSyncPC: 1_234_567, lastSync: Date(timeIntervalSince1970: 1_000_000_100),
                            lastSuccessfulSync: nil)
    #expect(SessionEvent.parse(line) == .syncInfo(info))
    #expect(SessionEvent.parse(#"{"event":"syncInfoWritten","lastSyncPC":31337}"#) == .syncPCWritten(31337))
}

@Test func fastSyncOnlyWithTheSamePC() {
    let info = PalmSyncInfo(lastSyncPC: 31337, lastSync: nil, lastSuccessfulSync: nil)
    #expect(info.canFastSync(withPC: 31337))
    #expect(!info.canFastSync(withPC: 4711))
    // a Palm that never synced, or a Mac without an ID: always slow sync
    #expect(!PalmSyncInfo(lastSyncPC: 0, lastSync: nil, lastSuccessfulSync: nil).canFastSync(withPC: 0))
}

/// The ROM's "version" is a text, a database's a number: both still decode.
@Test func versionAsTextAndAsNumber() {
    #expect(SessionEvent.parse(#"{"event":"romUnsupported","version":"5.4.9"}"#) == .romUnsupported(version: "5.4.9"))
    guard case .database(let info) = SessionEvent.parse(
        #"{"event":"db","name":"MemoDB","type":1145132097,"creator":1835363695,"version":3}"#) else {
        Issue.record("not a database")
        return
    }
    #expect(info.version == 3)
    #expect(info.creator == "memo")
}

/// Every line the tool printed in its own test (Tools/hotsync-session/tests,
/// against an in-memory Palm) is understood here.
@Test func everyLineOfTheSessionToolTestParses() throws {
    let expected = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/hotsync-session/tests/expected.txt")
    let lines = try String(contentsOf: expected, encoding: .utf8).split(separator: "\n")
    #expect(lines.count > 30)
    for line in lines {
        #expect(SessionEvent.parse(String(line)) != nil, "not understood: \(line)")
    }
}

// MARK: - Commands

@Test func recordCommands() {
    #expect(SessionCommand.listDatabases.line == "listdbs")
    #expect(SessionCommand.openDatabase(name: "DatebookDB", writable: true).line == "opendb write DatebookDB")
    #expect(SessionCommand.openDatabase(name: "CalendarDB-PDat", writable: false).line == "opendb read CalendarDB-PDat")
    #expect(SessionCommand.closeDatabase.line == "closedb")
    #expect(SessionCommand.readAllRecords.line == "readall")
    #expect(SessionCommand.readChangedRecords.line == "readchanged")
    #expect(SessionCommand.writeRecord(id: 0, attributes: [], category: 0, data: Data("new".utf8)).line
            == "writerec 0 0 0 6e6577")
    #expect(SessionCommand.writeRecord(id: 0xA0_0001, attributes: .secret, category: 15, data: Data([0xFF, 0x00])).line
            == "writerec 10485761 16 15 ff00")
    #expect(SessionCommand.deleteRecord(id: 0xA0_0004).line == "deleterec 10485764")
    #expect(SessionCommand.readAppInfo.line == "readappinfo")
    #expect(SessionCommand.writeAppInfo(Data([0x00, 0x02])).line == "writeappinfo 0002")
    #expect(SessionCommand.resetSyncFlags.line == "resetflags")
    #expect(SessionCommand.syncInfo.line == "syncinfo")
    #expect(SessionCommand.setSyncPC(31337).line == "setsyncpc 31337")
}

@Test func existingCommands() {
    #expect(SessionCommand.install(path: "/a b/x.prc").line == "install /a b/x.prc")
    #expect(SessionCommand.setUser(id: 4711, name: "Palm User").line == "setuser 4711 Palm User")
    #expect(SessionCommand.log("3 installed").line == "log 3 installed")
    #expect(SessionCommand.backup(directory: "/b").line == "backup /b")
    #expect(SessionCommand.getROM(directory: "/r").line == "getrom /r")
    #expect(SessionCommand.end.line == "end")
}

@Test func commandsThatCannotBeSent() {
    #expect(SessionCommand.writeRecord(id: 0, attributes: [], category: 16, data: Data()).line == nil)
    #expect(SessionCommand.writeRecord(id: 0, attributes: [], category: -1, data: Data()).line == nil)
    #expect(SessionCommand.deleteRecord(id: 0).line == nil)
    #expect(SessionCommand.writeAppInfo(Data()).line == nil)
    #expect(SessionCommand.setSyncPC(0).line == nil)
    #expect(SessionCommand.setUser(id: 0, name: "x").line == nil)
    // a line break would turn the rest into a command of its own
    #expect(SessionCommand.log("ok\nend").line == nil)
    #expect(SessionCommand.openDatabase(name: "a\nb", writable: true).line == nil)
}

// MARK: - Hex, four-character codes

@Test func hexRoundTrip() {
    let all = Data((0...255).map { UInt8($0) })
    #expect(Hex.decode(Hex.encode(all)) == all)
    #expect(Hex.encode(Data([0xDE, 0xAD, 0x01])) == "dead01")
    #expect(Hex.decode("DEAD01") == Data([0xDE, 0xAD, 0x01]))
    #expect(Hex.decode("") == Data())
    #expect(Hex.decode("a") == nil)
    #expect(Hex.decode("0g") == nil)
}

@Test func fourCharacterCodes() {
    #expect(FourCC.string(0x4441_5441) == "DATA")
    #expect(FourCC.string(0x6461_7465) == "date")
    #expect(FourCC.value("PDat") == 0x5044_6174)
    #expect(FourCC.value("toolong") == nil)
    #expect(FourCC.value(FourCC.string(0x0001_FF7F)) == 0x0001_FF7F)
}
