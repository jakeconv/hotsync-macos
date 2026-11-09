# Calendar sync and calendar view: plan

Goal: two-way sync between the calendar on a Palm (Palm OS 3.0 and newer) and the
calendars on the Mac (EventKit, so iCloud and therefore the iPhone), and later a
calendar window in the style of the Palm Desktop, editing the Palm's events.

Each stage names the model suggested for it: **Opus** where a mistake costs data
(protocol, binary formats, sync logic), **Sonnet** for UI, settings, plumbing,
texts and documentation.

## Decisions

| Topic | Decision |
|---|---|
| Palm OS versions | 3.0 and newer. The format is chosen by what is on the Palm, not by the version number: `CalendarDB-PDat` (the newer Calendar app, Palm OS 5.2.1+ on devices such as Tungsten T3/T5, TX, LifeDrive, Treo 650+) if present, else `DatebookDB` (Palm OS 3.0 – 5.x). |
| Calendars, Palm without categories (`DatebookDB`) | The user picks any number of Mac calendars. All of them are merged into the one Palm calendar. New events from the Palm go to one Mac calendar the user picks. |
| Calendars, Palm with categories (`CalendarDB-PDat`) | Each Palm category matches one Mac calendar, by name (`Work` ↔ `Work`), editable in the settings. Unfiled goes to the default Mac calendar. Palm OS allows at most 15 categories, with names of up to 15 characters. |
| Sync window | Configurable; default **3 months back, 18 months ahead**, at most 12 months back. A repeating event is included if any of its dates falls in the window. Events that fall out of the window are removed from the Palm only; they stay on the Mac (this is not a deletion). |
| Conflicts | **The Mac wins.** That covers edit/edit and edit/delete: an event edited on the Mac but deleted on the Palm comes back onto the Palm, and an event edited on the Palm but deleted on the Mac is deleted on the Palm. |
| Time zones | Palm times count as the Mac's current local time. `CalendarDB-PDat` events that carry a time zone use it. |
| Several Palms, one Mac calendar | Supported: every Palm has its own sync state (record mapping and fingerprints). |
| Calendar window | An editor, like the Palm Desktop, showing the events as they are on the Palm. A new or changed event is written to the Mac calendar at once and goes to the Palm at the next HotSync. |
| Signing | No paid Developer ID. The build is signed with a stable local identity (see stage 3) so the calendar permission survives rebuilds. |

### Why the default window is smaller than a year

Storage is not the problem: a Date Book record is about 20 bytes plus its text, so
1,000 events come to roughly 60–80 KB, which fits even a 2 MB Palm. The cost is
time. A slow sync (the first sync, after a hard reset, or after the Palm synced with
another computer) reads every record. Over a serial cradle at 57,600 baud that is
noticeable. 3 months back is enough for looking things up on the go, and anyone who
wants more can set up to 12 months.

## How the code is laid out today (for orientation)

- `Sources/HotSync/` – the SwiftUI menu bar app. It runs one
  `Tools/hotsync-session/hotsync-session.c` per port, sends it commands over stdin
  (`install`, `backup`, `getrom`, `setuser`, `log`, `end`) and reads JSON events
  from stdout (`Sources/HotSyncCore/SessionEvent.swift`).
- `Sources/HotSyncCore/` – pure Swift, no UI, unit-tested
  (`Tests/HotSyncCoreTests`, `./Scripts/test.sh`).
- Today everything is whole-database: there is no record-level read or write, no
  handling of the dirty/deleted flags, and `lastSyncPC` is never maintained.

## Stage 1 – Record-level access in `hotsync-session` (Opus)

New commands and events in `hotsync-session.c`, records as hex in the JSON:

- `opendb <name> <mode>` / `closedb`
- `readall` – every record with its ID, attributes (dirty, deleted, archived,
  private, busy) and category (`dlp_ReadRecordByIndex`)
- `readchanged` – only modified/deleted records (`dlp_ReadNextModifiedRec`)
- `writerec <id|0> <attrs> <category> <hex>` – add or replace; reports the new
  record ID (`dlp_WriteRecord`)
- `deleterec <id>` (`dlp_DeleteRecord`)
- `readappinfo` / `writeappinfo <hex>` – the AppInfo block (category names)
- `resetflags` – `dlp_CleanUpDatabase` + `dlp_ResetSyncFlags` after a successful
  sync
- `syncinfo` – report and set `lastSyncPC` and the `successfulSyncDate` in the user
  info. A Palm whose `lastSyncPC` is this Mac's ID can be fast-synced (changed
  records only); otherwise slow-sync. The Mac's ID: random, stored once in the
  app's settings.
- `listdbs` with creator/type, to tell which calendar database exists.

`SessionEvent` gets the matching cases, and the tests get transcript cases.
**Done when** a test command can dump and rewrite the Date Book records of an
OS 3.0 and an OS 5.4 Palm unchanged.

**Status: implemented; to be checked on the real Palms.**

- `hotsync-session.c`: the commands above, plus `closedb`. Command lines may now
  be of any length (a 64 KB record is a 128 KB line). An open database is closed
  before the HotSync ends.
- `HotSyncCore`: `PalmRecord`, `PalmRecordAttributes`, `PalmDatabaseInfo`,
  `PalmSyncInfo` (`canFastSync(withPC:)`), `SessionCommand` (every command, with
  the values checked), and the new `SessionEvent` cases. `SessionRunner` gets
  `send(_: SessionCommand)`. The app does not use any of it yet.
- Tests: `Tools/hotsync-session/tests/run.sh` builds the tool against
  `fake-pisock.c`, an in-memory Palm, runs `commands.txt` and compares with
  `expected.txt`, plus a 60,000-byte record. `RecordAccessTests.swift` checks the
  Swift side and that it understands every line of `expected.txt`.
  `./Scripts/test.sh` runs both.

**Checking it on a real Palm** (quit HotSync first, so the port is free):

```bash
HotSync.app/Contents/Resources/hotsync-session --port usb:
```

Press HotSync on the Palm. After the `connected` line, type commands, e.g.
`syncinfo`, `listdbs`, `opendb read DatebookDB` (on the 5.4 Palm also
`opendb read CalendarDB-PDat`), `readappinfo`, `readall`, `readchanged`,
`closedb`, `end`. To check writing, rewrite one record with its own data:
`opendb write DatebookDB`, then `writerec <id> <attributes> <category> <data>` with
the values from its `record` line (attributes 16 if it was private, else 0), then
`readall` again: the record must come back with the same data. Do not `resetflags` or `setsyncpc` on a Palm that syncs with another
desktop, since they change what that desktop sees as changed.

## Stage 2 – Calendar formats in `HotSyncCore` (Opus)

Pure Swift types, unit-tested, no I/O:

- `PalmEvent`: date, start/end time or untimed; alarm (advance + unit); repeat
  (none, daily, weekly with days, monthly by date, monthly by weekday incl. "last",
  yearly; frequency; end date; week start); exceptions; description; note;
  private; category (if any); location and time zone (`CalendarDB-PDat`).
- Codecs for `DatebookDB` records and `CalendarDB-PDat` records, and for the
  category AppInfo block (shared by all categorised Palm databases).
- Text: Windows-1252 ↔ UTF-8 (for both directions; the C tool already has the
  table for one).
- **Test data:** the `.pdb` files in `~/HotSync/<device>/Backup/` from the user's
  own Palms (OS 3.0 and 5.4). Every record must decode and encode back to
  exactly the same bytes. The tests contain a few anonymised records, not personal
  data.
- **Found on a Handspring Visor (Palm OS 3.1, `DatebookDB` with Datebook+):**
  - The byte after the flags byte is not cleared by the Palm (random values
    such as `d2`, `c1`, `0a`). The codec keeps it, or records would not come
    back byte for byte.
  - Datebook+/DateBk keeps its own data in the note: lines starting with `##`
    (here `##f` and `##c`, most likely a floating event and a completed one),
    together with flag bits `0x01`/`0x02` that the classic Date Book does not
    define. The codec keeps unknown bits and `##` lines unchanged on the Palm.
    They do not go into the Mac note, and an edit from the Mac does not lose
    them.
  - Alarm units as documented: an alarm of 0 minutes is "at the start time";
    unit 2 is days.
  - The sample had no repeating events and no exceptions: test records with
    those are still needed (daily, weekly on several days, monthly by date,
    monthly on the 2nd Tuesday and on the last Friday, yearly, one with a
    deleted occurrence, one with a note).
- **Found on a Palm TX (Palm OS 5.4.9):**
  - Both databases exist, with the same records under the same IDs.
    `CalendarDB-PDat` (creator `PDat`) is the Calendar app's own;
    `DatebookDB` is a copy the OS keeps for older applications, without the
    new fields. Sync `CalendarDB-PDat` only. To check in stage 7: after the
    sync writes to `CalendarDB-PDat`, does the OS update `DatebookDB` too?
  - `CalendarDB-PDat` records are the Date Book layout plus:
    - flag `0x02` = a location, stored as one more string after the
      description (for example "Magnet Theatre"). Which comes first when an event
      has both a note and a location is still open.
    - after the strings, optional tagged blocks: 4-character ID, 2-byte
      length, data. Seen: `Bd01` with 4 bytes, on untimed events only (meaning
      not known yet; time zones are probably another block). The codec keeps
      unknown blocks as they are.
  - The category byte is used (0, 1, 2); the names are in the AppInfo block.
  - Yearly repeats (type 5) as documented; the byte after the repeat type is
    not cleared either (seen `09`).
  - A deleted record kept as an archive copy comes with attributes 72
    (archived + dirty) and its full data.

## Stage 3 – The Mac side: EventKit, permission, signing (Opus for conversion, Sonnet for the rest)

**Sonnet:**
- `NSCalendarsFullAccessUsageDescription` in `Info.plist` (German and English),
  `EKEventStore.requestFullAccessToEvents`, a status line when access is missing,
  with a button to System Settings.
- **Signing with a free account.** With ad-hoc signing (`codesign --sign -`) every
  build is a new identity to macOS, which then asks for calendar access again.
  `Scripts/build.sh` gets an optional `SIGN_IDENTITY`; the README explains two
  free ways to get one: an "Apple Development" certificate from Xcode's Personal
  Team (free Apple ID), or a self-signed code-signing certificate made in Keychain
  Access. Ad-hoc stays the default for release zips: those users grant access once
  per version.
- `EventKitCalendars`: list the Mac's calendars (with account: iCloud, On My Mac, …).

**Opus – converting `PalmEvent` ↔ `EKEvent`:**
- Untimed ↔ all-day. A multi-day Mac event goes onto the Palm as a daily repeating
  event over those days (the Date Book has no multi-day events) and stays linked
  to the one Mac event.
- Repeat rules ↔ `EKRecurrenceRule`; exceptions ↔ detached occurrences. Mac rules
  the Palm cannot express (e.g. "2nd and 4th Tuesday", several days a month, an
  occurrence count) are written to the Palm as single events within the window,
  marked as belonging to the Mac event. The Mac wins, so a Palm edit of one of
  them changes just that occurrence on the Mac.
- Alarms: the Palm holds one; the earliest Mac alarm goes to the Palm. A Palm edit
  changes only that alarm and leaves the others alone.
- Description (the Date Book shows about 255 characters) and note (about 4 KB)
  are cut to size; emoji and other characters outside Windows-1252 become `?`.
- Private ↔ there is no Mac equivalent; it is kept in the sync state.
- A Palm change updates only the fields the Palm has. URL, attendees, travel time,
  extra alarms and so on stay on the Mac event as they are.
- **Key rule:** fingerprints compare what the Palm *can* hold. A Mac title with an
  emoji that arrives on the Palm as `?` does not count as a Palm edit, otherwise
  every sync would overwrite the Mac with the lossy copy.

## Stage 4 – One-way: Palm → Mac (Sonnet, with Opus on review)

A first useful milestone that reads the Palm only:

- After the installs, read the calendar, convert it, and write it to the Mac:
  for a Palm without categories into the calendar the user picked, for a Palm with
  categories by the category ↔ calendar mapping.
- Simple settings in the tab: "Calendar: off / Palm → Mac", the target calendar.
- **Purpose:** shows the conversion working on real data before anything is
  written to the Palm. Easy to undo: delete the events in the Mac calendar.

## Stage 5 – Two-way sync engine (Opus)

In `HotSyncCore`, the engine works on plain values and is driven by the app;
EventKit and the session stay outside it, so it can be tested in full.

- **Sync state per Palm** in `~/HotSync/<device>/Sync/calendar.json`: Palm record
  ID ↔ Mac event (`calendarItemExternalIdentifier` plus `calendarItemIdentifier`,
  because EventKit identifiers can change when an event moves between calendars),
  a fingerprint of each side as last synced, the window used, and the category ↔
  calendar mapping.
- **Mac changes:** EventKit cannot say what changed, so compare the events in the
  window against the fingerprints: new, changed, gone.
- **Palm changes:** fast sync (dirty/deleted flags) when `lastSyncPC` is this Mac,
  otherwise slow sync (read everything, compare with fingerprints).
- **Apply:** Mac wins on every conflict. Out-of-window ≠ deleted. Events moved
  between categories/calendars move on the other side too. After success:
  `resetflags`, then set `lastSyncPC`.
- **First sync of a Palm** (no state yet): match existing events by
  date + time + description to avoid duplicates, such as when the Palm and the Mac
  already hold the same events from a Palm Desktop era, or when a second Palm joins
  a calendar.
- **Several Palms on one calendar:** each with its own state. An event made on
  Palm A goes to the Mac at A's HotSync and to Palm B at B's.
- **Safety rails:**
  - the backup of `DatebookDB`/`CalendarDB-PDat` is taken *before* the calendar
    sync (a calendar-only backup before the sync, the full one afterwards as
    today)
  - a dry-run mode that only reports "12 to the Palm, 3 to the Mac, 1 conflict
    (Mac wins)"
  - stop and ask if a sync would delete more than, say, 20 events or 25 % on
    either side
  - a clear "Reset calendar sync" that throws away the state and does a fresh
    first sync
- **Tests:** table tests for every combination (new/changed/deleted/unchanged ×
  Palm × Mac), out-of-window, recurrence with exceptions, lossy text, two Palms.

## Stage 6 – Settings and integration (Sonnet)

- Per Palm (device, not tab): calendar sync off / Palm → Mac / two-way; the
  window; for a Palm without categories, the Mac calendars to merge and the
  calendar for new Palm events; for a Palm with categories, the
  category ↔ calendar table (create missing categories on the Palm, at most 15).
- Order in the HotSync: restore → installs → calendar sync → backup.
- Progress ("Calendar: 214 of 530") and a summary in the tab log and in the Palm's
  HotSync log; a notification on conflicts.
- German and English texts in `L10n.swift`, a README section.

## Stage 7 – Hardening on real Palms (Sonnet, Opus for bugs in stages 2–5)

A checklist on the OS 3.0 and OS 5.4 devices, over USB and serial:
daylight-saving changes, an edited repeating event (all of it, one occurrence),
events from the iPhone, a hard reset (slow sync), two Palms on one calendar,
a full Palm, a pulled cable mid-sync (next sync must recover), a calendar renamed
or deleted on the Mac.

## Stage 8 – Calendar window like the Palm Desktop (Opus for the design, Sonnet to build)

- A window per Palm with the familiar Palm Desktop layout: **Day** (time slots,
  with a list beside it), **Week**, **Month**, plus a mini month to jump.
- **Data:** the events *as they are on the Palm*: the Palm side of the sync state
  (stage 5), plus changes made in the window that are waiting for the next
  HotSync (shown as pending). Events from Mac calendars that are not synced to this
  Palm are not shown.
- **Editing:** create, change, delete, drag to move and resize; repeat, alarm,
  note, private, and category (only for a Palm that has categories). Every edit is
  written to the matching Mac calendar at once (and so reaches the iPhone) and to
  the Palm at its next HotSync. Because the Mac wins on conflicts, an edit made
  here also wins over a change made on the Palm in the meantime.
- **The editor is limited to what the Palm can hold** (description length,
  Windows-1252 characters, repeat rules the Palm knows), so nothing is lost on
  the way.
- Opus: the view model, overlapping events in the day/week grid, editing a
  repeating event ("this one / all"). Sonnet: the SwiftUI views.

## Later

The same building blocks (record access, category block, sync engine with
fingerprints) carry over to To Do ↔ Reminders, Address ↔ Contacts and Memos ↔
Notes (the last one is not possible through a public API on macOS; would need a
different target). A To Do pane in the Day view, as in the Palm Desktop, once
To Do sync exists.
