import Foundation

@main
enum TrackingDataTests {
    static func main() throws {
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        var data = TrackingData()
        let start = date("2026-09-27T23:30:00-04:00")
        let end = date("2026-09-28T00:30:00-04:00")
        data.start(at: start)
        data.start(at: start.addingTimeInterval(100))
        assert(data.activeStart == start, "Starting twice must not reset timer")
        let sundayWeek = TrackingCalendar.week(containing: start, calendar: calendar)
        let mondayWeek = TrackingCalendar.week(containing: end, calendar: calendar)
        assert(data.total(in: sundayWeek, now: end) == 1800, "Active timer must split at week boundary")
        data.stop(at: end)
        data.stop(at: end)
        assert(data.sessions.count == 1, "Stopping twice must not duplicate sessions")
        assert(data.total(in: sundayWeek, now: end) == 1800)
        assert(data.total(in: mondayWeek, now: end) == 1800)
        assert(data.sessions[0].duration == 3600)

        let dstDay = calendar.dateInterval(of: .day, for: date("2026-03-08T12:00:00-04:00"))!
        assert(dstDay.duration == 23 * 3600, "Calendar days must respect DST")
        let dstSession = Session(start: date("2026-03-08T01:30:00-05:00"), end: date("2026-03-08T03:30:00-04:00"))
        assert(dstSession.duration(in: dstDay) == 3600)

        data.start(at: end)
        data.checkpoint = end.addingTimeInterval(30)
        assert(data.recover())
        assert(data.sessions.last!.duration == 30 && data.sessions.last!.interrupted)
        assert(data.activeStart == nil && !data.recover())

        var categorized = TrackingData()
        categorized.switchCategory(to: .music, at: start)
        assert(categorized.activeStart == nil && categorized.currentCategory == .work)
        categorized.start(at: start)
        assert(categorized.currentCategory == .work)
        categorized.switchCategory(to: .music, at: start.addingTimeInterval(1800))
        assert(categorized.sessions.count == 1 && categorized.sessions[0].category == .work)
        assert(categorized.sessions[0].end == categorized.activeStart, "Switch must not lose time or overlap")
        categorized.switchCategory(to: .music, at: end)
        assert(categorized.sessions.count == 1, "Selecting the current category must not split the session")
        assert(categorized.total(in: sundayWeek, now: end, category: .work) == 1800)
        assert(categorized.total(in: mondayWeek, now: end, category: .music) == 1800)
        assert(categorized.total(in: mondayWeek, now: end, category: .work) == 0)
        let runningRoundTrip = try JSONDecoder().decode(TrackingData.self, from: JSONEncoder().encode(categorized))
        assert(runningRoundTrip.currentCategory == .music && runningRoundTrip.activeStart == categorized.activeStart)
        var recoveredMusic = runningRoundTrip
        recoveredMusic.checkpoint = end
        assert(recoveredMusic.recover())
        assert(recoveredMusic.sessions.last!.category == .music && recoveredMusic.sessions.last!.duration == 1800)
        categorized.stop(at: end)
        assert(categorized.sessions.last!.category == .music)
        assert(categorized.sessions.reduce(0) { $0 + $1.duration } == 3600)
        categorized.start(at: end)
        assert(categorized.currentCategory == .work, "Every fresh timer must default to Work after Music")
        categorized.switchCategory(to: .music, at: end.addingTimeInterval(60))
        categorized.switchCategory(to: .work, at: end.addingTimeInterval(120))
        assert(categorized.currentCategory == .work && categorized.sessions.last!.category == .music)
        assert(DataFile.csv(categorized).contains("1800,false,Music"))

        let legacyJSON = """
        {"sessions":[{"id":"00000000-0000-0000-0000-000000000001","start":100,"end":160,"interrupted":false}],"activeStart":200,"checkpoint":230}
        """
        var legacy = try JSONDecoder().decode(TrackingData.self, from: Data(legacyJSON.utf8))
        assert(legacy.sessions[0].category == .work && legacy.sessions[0].duration == 60)
        assert(legacy.currentCategory == .work && legacy.recover())
        assert(legacy.sessions.last!.category == .work && legacy.sessions.last!.duration == 30)

        assert(DurationInput.parse("45") == 2700)
        assert(DurationInput.parse("1:30") == 5400)
        assert(DurationInput.parse("00:00:26") == 26)
        assert(DurationInput.parse("5m") == 300)
        assert(DurationInput.parse("0") == nil && DurationInput.parse("1:90") == nil)

        let originalStart = date("2026-09-25T10:00:00Z")
        let nextStart = originalStart.addingTimeInterval(3600)
        let later = nextStart.addingTimeInterval(3600)
        let editNow = later.addingTimeInterval(3600)
        var edited = TrackingData(sessions: [
            Session(start: originalStart, end: nextStart, category: .work),
            Session(start: nextStart, end: later, category: .music)
        ])
        let editedID = edited.sessions[0].id
        let changedStart = originalStart.addingTimeInterval(900)
        try edited.editSession(id: editedID, start: changedStart, end: nextStart, category: .music, now: editNow)
        let editedDay = calendar.dateInterval(of: .day, for: changedStart)!
        assert(edited.sessions.count == 2 && edited.sessions[0].id == editedID)
        assert(edited.total(in: editedDay, now: editNow, category: .work) == 0)
        assert(edited.total(in: editedDay, now: editNow, category: .music) == 6300)
        assert(DataFile.csv(edited).contains("2700,false,Music"))
        do {
            try edited.editSession(id: editedID, start: changedStart, end: nextStart.addingTimeInterval(1), category: .work, now: editNow)
            fatalError("An overlapping edit must fail")
        } catch SessionEditError.overlapsAnotherSession { }
        assert(edited.sessions[0].end == nextStart && edited.sessions[0].category == .music)
        do {
            try edited.editSession(id: editedID, start: changedStart, end: changedStart, category: .music, now: editNow)
            fatalError("A zero-length edit must fail")
        } catch SessionEditError.invalidTime { }
        do {
            try edited.editSession(id: editedID, start: changedStart, end: editNow.addingTimeInterval(1), category: .music, now: editNow)
            fatalError("A future edit must fail")
        } catch SessionEditError.futureTime { }
        edited.start(at: later)
        do {
            try edited.editSession(id: edited.sessions[1].id, start: nextStart, end: later.addingTimeInterval(1), category: .music, now: editNow)
            fatalError("An edit must not overlap the running timer")
        } catch SessionEditError.overlapsAnotherSession { }
        let editedRoundTrip = try JSONDecoder().decode(TrackingData.self, from: JSONEncoder().encode(edited))
        assert(editedRoundTrip.sessions[0].start == changedStart && editedRoundTrip.sessions[0].category == .music)

        var extended = TrackingData(sessions: [
            Session(start: originalStart, end: originalStart.addingTimeInterval(600), category: .work),
            Session(start: nextStart, end: nextStart.addingTimeInterval(600), category: .music)
        ])
        let extendedID = extended.sessions[0].id
        for minutes in [5, 10, 15, 20] {
            try extended.extendSession(id: extendedID, by: TimeInterval(minutes * 60), now: editNow)
        }
        assert(extended.sessions.count == 2 && extended.sessions[0].id == extendedID)
        assert(extended.sessions[0].start == originalStart && extended.sessions[0].category == .work)
        assert(extended.sessions[0].duration == 60 * 60)
        assert(extended.total(in: editedDay, now: editNow, category: .work) == 60 * 60)
        let unchangedEnd = extended.sessions[0].end
        do {
            try extended.extendSession(id: extendedID, by: 10 * 60, now: editNow)
            fatalError("Extending into the next session must fail")
        } catch SessionEditError.overlapsAnotherSession { }
        assert(extended.sessions[0].end == unchangedEnd)
        do {
            try extended.extendSession(id: extendedID, by: 0, now: editNow)
            fatalError("Zero-length extensions must fail")
        } catch SessionEditError.invalidTime { }
        do {
            try extended.extendSession(id: UUID(), by: 300, now: editNow)
            fatalError("An unknown session must fail")
        } catch SessionEditError.notFound { }
        do {
            try extended.extendSession(id: extended.sessions[1].id, by: 300, now: nextStart.addingTimeInterval(600))
            fatalError("Extending into the future must fail")
        } catch SessionEditError.futureTime { }
        extended.start(at: nextStart.addingTimeInterval(600))
        do {
            try extended.extendSession(id: extended.sessions[1].id, by: 60, now: editNow)
            fatalError("Extending into the active timer must fail")
        } catch SessionEditError.overlapsAnotherSession { }
        assert(extended.sessions[0].end == unchangedEnd && extended.sessions[1].duration == 600)

        var missed = TrackingData()
        let missedDay = date("2026-09-25T08:00:00Z")
        let missedNow = date("2026-09-25T13:00:00Z")
        for (index, minutes) in [5, 10, 15, 20].enumerated() {
            let session = try missed.addSession(
                endingAt: missedDay.addingTimeInterval(TimeInterval(index * 3600 + minutes * 60)),
                duration: TimeInterval(minutes * 60),
                category: index == 1 ? .music : .work,
                now: missedNow
            )
            assert(session.duration == TimeInterval(minutes * 60))
        }
        let missedInterval = calendar.dateInterval(of: .day, for: missedDay)!
        assert(missed.sessions.count == 4)
        assert(missed.total(in: missedInterval, now: missedNow, category: .work) == 40 * 60)
        assert(missed.total(in: missedInterval, now: missedNow, category: .music) == 10 * 60)
        do {
            _ = try missed.addSession(endingAt: missedDay.addingTimeInterval(10 * 60), duration: 10 * 60, category: .work, now: missedNow)
            fatalError("Overlapping missed time must fail")
        } catch SessionEditError.overlapsAnotherSession { }
        do {
            _ = try missed.addSession(endingAt: missedNow.addingTimeInterval(60), duration: 300, category: .work, now: missedNow)
            fatalError("Future missed time must fail")
        } catch SessionEditError.futureTime { }
        do {
            _ = try missed.addSession(endingAt: missedNow, duration: 0, category: .work, now: missedNow)
            fatalError("Zero-length missed time must fail")
        } catch SessionEditError.invalidTime { }
        missed.start(at: date("2026-09-25T12:00:00Z"))
        do {
            _ = try missed.addSession(endingAt: date("2026-09-25T12:01:00Z"), duration: 300, category: .work, now: missedNow)
            fatalError("Missed time must not overlap a running timer")
        } catch SessionEditError.overlapsAnotherSession { }
        assert(missed.sessions.count == 4)

        var midnight = TrackingData()
        let midnightEnd = date("2026-09-28T00:10:00-04:00")
        _ = try midnight.addSession(endingAt: midnightEnd, duration: 1200, category: .music, now: midnightEnd)
        assert(midnight.total(in: sundayWeek, now: midnightEnd, category: .music) == 600)
        assert(midnight.total(in: mondayWeek, now: midnightEnd, category: .music) == 600)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TimeTrackerTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = DataFile(url: temporary.appendingPathComponent("sessions.json"))
        let empty = try file.load()
        assert(empty.sessions.isEmpty)
        try file.save(data)
        let loaded = try file.load()
        assert(loaded.sessions.count == 2 && loaded.sessions[0].duration == 3600)
        assert(DataFile.csv(loaded).contains("3600,false"))
        try Data("invalid JSON".utf8).write(to: file.url)
        do { _ = try file.load(); fatalError("Corrupt data must not be silently replaced") }
        catch is DecodingError { }
        assert(TrackingCalendar.clock(3661) == "01:01:01")
        print("Passed: one-click session extensions, missed sessions, presets, overlap checks, cross-midnight totals, session edits, Work defaults, category switching, legacy migration, DST, crash recovery, persistence, corrupt data handling, and categorized CSV export.")
    }
}
