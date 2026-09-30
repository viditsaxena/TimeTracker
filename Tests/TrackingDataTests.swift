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

        var directMusic = TrackingData()
        directMusic.start(at: start, category: .music)
        assert(directMusic.sessions.isEmpty && directMusic.activeStart == start)
        assert(directMusic.currentCategory == .music, "Music can start directly without a Work fragment")
        directMusic.stop(at: start.addingTimeInterval(300))
        assert(directMusic.sessions.count == 1 && directMusic.sessions[0].category == .music)

        var quickCorrection = TrackingData()
        quickCorrection.start(at: start)
        quickCorrection.switchCategory(to: .music, at: start.addingTimeInterval(8))
        assert(quickCorrection.sessions.isEmpty, "Work under 10 seconds must be discarded when switching to Music")
        assert(quickCorrection.activeStart == start.addingTimeInterval(8) && quickCorrection.currentCategory == .music)
        quickCorrection.stop(at: start.addingTimeInterval(13))
        assert(quickCorrection.sessions.count == 1 && quickCorrection.sessions[0].category == .music)
        assert(quickCorrection.sessions[0].duration == 5, "Exactly 5 seconds should be saved")
        assert(quickCorrection.total(in: sundayWeek, now: end, category: .work) == 0)

        var tenSecondWork = TrackingData()
        tenSecondWork.start(at: start)
        tenSecondWork.switchCategory(to: .music, at: start.addingTimeInterval(10))
        assert(tenSecondWork.sessions.count == 1 && tenSecondWork.sessions[0].duration == 10)
        assert(tenSecondWork.sessions[0].category == .work, "Exactly 10 seconds of Work should be saved")

        var shortSessions = TrackingData()
        shortSessions.start(at: start)
        shortSessions.stop(at: start.addingTimeInterval(4))
        assert(shortSessions.sessions.isEmpty && shortSessions.activeStart == nil, "Work under 5 seconds must be discarded")
        shortSessions.start(at: start, category: .music)
        shortSessions.stop(at: start.addingTimeInterval(4))
        assert(shortSessions.sessions.isEmpty, "Music under 5 seconds must be discarded")
        shortSessions.start(at: start, category: .music)
        shortSessions.stop(at: start.addingTimeInterval(5))
        assert(shortSessions.sessions.count == 1 && shortSessions.sessions[0].duration == 5)
        shortSessions.startStanding(at: start)
        shortSessions.stopStanding(at: start.addingTimeInterval(4))
        assert(shortSessions.standingSessions.isEmpty && shortSessions.standingStart == nil, "Standing under 5 seconds must be discarded")
        shortSessions.startStanding(at: start)
        shortSessions.stopStanding(at: start.addingTimeInterval(5))
        assert(shortSessions.standingSessions.count == 1 && shortSessions.standingSessions[0].duration == 5)

        let previouslySavedShort = TrackingData(sessions: [Session(start: start, end: start.addingTimeInterval(3))])
        let preservedShort = try JSONDecoder().decode(TrackingData.self, from: JSONEncoder().encode(previouslySavedShort))
        assert(preservedShort.sessions.count == 1 && preservedShort.sessions[0].duration == 3, "Existing short sessions must not be removed")

        var shortRecovery = TrackingData()
        shortRecovery.start(at: start)
        shortRecovery.checkpoint = start.addingTimeInterval(4)
        assert(shortRecovery.recover() && shortRecovery.sessions.isEmpty, "Interrupted time under 5 seconds must be discarded")

        let legacyJSON = """
        {"sessions":[{"id":"00000000-0000-0000-0000-000000000001","start":100,"end":160,"interrupted":false}],"activeStart":200,"checkpoint":230}
        """
        var legacy = try JSONDecoder().decode(TrackingData.self, from: Data(legacyJSON.utf8))
        assert(legacy.sessions[0].category == .work && legacy.sessions[0].duration == 60)
        assert(legacy.standingSessions.isEmpty && legacy.standingStart == nil, "Old files must load without standing data")
        assert(legacy.currentCategory == .work && legacy.recover())
        assert(legacy.sessions.last!.category == .work && legacy.sessions.last!.duration == 30)

        var standing = TrackingData()
        standing.startStanding(at: start)
        standing.startStanding(at: start.addingTimeInterval(60))
        assert(standing.standingStart == start, "Starting twice must not reset standing time")
        standing.start(at: start.addingTimeInterval(300), category: .music)
        standing.stop(at: end)
        assert(standing.standingStart == start && standing.sessions.count == 1, "Stopping a project must not stop standing")
        assert(standing.standingTotal(in: sundayWeek, now: end) == 1800)
        assert(standing.standingTotal(in: mondayWeek, now: end) == 1800)
        standing.stopStanding(at: end)
        standing.stopStanding(at: end)
        assert(standing.standingSessions.count == 1 && standing.standingStart == nil)
        assert(standing.standingSessions[0].duration == 3600)
        assert(standing.total(in: mondayWeek, now: end, category: .music) == 1800)
        assert(DataFile.csv(standing).contains("3600,false,Standing"))
        let standingRoundTrip = try JSONDecoder().decode(TrackingData.self, from: JSONEncoder().encode(standing))
        assert(standingRoundTrip.standingSessions.count == 1 && standingRoundTrip.standingStart == nil)

        let standingID = standing.standingSessions[0].id
        try standing.editStandingSession(id: standingID, start: start.addingTimeInterval(300), end: end, now: end)
        assert(standing.standingSessions[0].duration == 3300, "Standing may overlap a project")
        standing.startStanding(at: end)
        do {
            try standing.editStandingSession(id: standingID, start: start, end: end.addingTimeInterval(60), now: end.addingTimeInterval(60))
            fatalError("Standing edits must not overlap the running standing timer")
        } catch SessionEditError.overlapsAnotherSession { }
        standing.standingCheckpoint = end.addingTimeInterval(30)
        assert(standing.recover() && standing.standingSessions.last!.interrupted)
        assert(standing.standingSessions.last!.duration == 30 && standing.standingStart == nil)
        let removedStanding = try standing.deleteStandingSession(id: standingID)
        assert(removedStanding.id == standingID && standing.standingSessions.count == 1)

        var bothInterrupted = TrackingData()
        bothInterrupted.start(at: start, category: .work)
        bothInterrupted.startStanding(at: start.addingTimeInterval(60))
        bothInterrupted.checkpoint = start.addingTimeInterval(120)
        bothInterrupted.standingCheckpoint = start.addingTimeInterval(180)
        assert(bothInterrupted.recover())
        assert(bothInterrupted.sessions.last!.duration == 120)
        assert(bothInterrupted.standingSessions.last!.duration == 120)
        assert(bothInterrupted.activeStart == nil && bothInterrupted.standingStart == nil)

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

        var deletion = TrackingData(sessions: [
            Session(start: originalStart, end: nextStart, category: .work),
            Session(start: nextStart, end: later, category: .music)
        ])
        let deletedID = deletion.sessions[0].id
        let deleted = try deletion.deleteSession(id: deletedID)
        assert(deleted.id == deletedID && deletion.sessions.count == 1)
        assert(deletion.total(in: editedDay, now: editNow, category: .work) == 0)
        assert(deletion.total(in: editedDay, now: editNow, category: .music) == 3600)
        assert(!DataFile.csv(deletion).contains("3600,false,Work"))
        do {
            _ = try deletion.deleteSession(id: deletedID)
            fatalError("Deleting the same session twice must fail")
        } catch SessionEditError.notFound { }
        assert(deletion.sessions.count == 1)

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

        let quickNow = date("2026-09-27T12:00:00-04:00")
        let quickDay = calendar.dateInterval(of: .day, for: quickNow)!
        var quick = TrackingData(sessions: [
            Session(start: date("2026-09-27T09:00:00-04:00"), end: date("2026-09-27T09:30:00-04:00"), category: .work),
            Session(start: date("2026-09-27T11:50:00-04:00"), end: date("2026-09-27T11:58:00-04:00"), category: .music)
        ])
        let firstQuick = try quick.addTimeToday(duration: 300, category: .work, now: quickNow, calendar: calendar)
        guard case .addedSession(let firstQuickSession) = firstQuick else { fatalError("Stopped timer should create a new session") }
        assert(firstQuickSession.start == date("2026-09-27T11:45:00-04:00"))
        assert(firstQuickSession.end == date("2026-09-27T11:50:00-04:00"))
        assert(firstQuickSession.category == .work && quick.sessions.count == 3)
        let secondQuick = try quick.addTimeToday(duration: 600, category: .music, now: quickNow, calendar: calendar)
        guard case .addedSession(let secondQuickSession) = secondQuick else { fatalError("Stopped timer should create a new session") }
        assert(secondQuickSession.start == date("2026-09-27T11:35:00-04:00"))
        assert(secondQuickSession.end == firstQuickSession.start && secondQuickSession.category == .music)
        assert(quick.total(in: quickDay, now: quickNow, category: .work) == 35 * 60)
        assert(quick.total(in: quickDay, now: quickNow, category: .music) == 18 * 60)

        var runningQuick = TrackingData(sessions: [
            Session(start: date("2026-09-27T10:00:00-04:00"), end: date("2026-09-27T10:50:00-04:00"), category: .work)
        ], activeStart: date("2026-09-27T11:00:00-04:00"), checkpoint: quickNow, activeCategory: .music)
        let extendedRunning = try runningQuick.addTimeToday(duration: 300, category: .work, now: quickNow, calendar: calendar)
        guard case .extendedRunningSession = extendedRunning else { fatalError("A running timer should absorb adjacent free time") }
        assert(runningQuick.activeStart == date("2026-09-27T10:55:00-04:00"))
        assert(runningQuick.sessions.count == 1 && runningQuick.currentCategory == .music)
        let fallbackQuick = try runningQuick.addTimeToday(duration: 600, category: .work, now: quickNow, calendar: calendar)
        guard case .addedSession(let fallbackSession) = fallbackQuick else { fatalError("A non-adjacent gap should get a new session") }
        assert(fallbackSession.start == date("2026-09-27T09:50:00-04:00"))
        assert(fallbackSession.end == date("2026-09-27T10:00:00-04:00"))
        assert(fallbackSession.category == .music && runningQuick.activeStart == date("2026-09-27T10:55:00-04:00"))

        var fullToday = TrackingData(sessions: [Session(start: quickDay.start, end: quickNow, category: .work)])
        do {
            _ = try fullToday.addTimeToday(duration: 300, category: .music, now: quickNow, calendar: calendar)
            fatalError("Quick add must not double-count a full day")
        } catch SessionEditError.noFreeTimeToday { }
        assert(fullToday.sessions.count == 1)
        let justAfterMidnight = date("2026-09-27T00:03:00-04:00")
        var earlyToday = TrackingData()
        do {
            _ = try earlyToday.addTimeToday(duration: 300, category: .work, now: justAfterMidnight, calendar: calendar)
            fatalError("Quick add must not borrow time from yesterday")
        } catch SessionEditError.noFreeTimeToday { }
        assert(earlyToday.sessions.isEmpty)
        do {
            _ = try earlyToday.addTimeToday(duration: 0, category: .work, now: quickNow, calendar: calendar)
            fatalError("Quick add needs a positive duration")
        } catch SessionEditError.invalidTime { }
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

        var mouseReminder = MouseActivityReminder()
        let activityStart = date("2026-09-28T10:00:00-04:00")
        for second in 0..<180 {
            assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(TimeInterval(second)), mouseIdleSeconds: 1, timerRunning: false))
        }
        assert(mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(180), mouseIdleSeconds: 1, timerRunning: false))
        assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(181), mouseIdleSeconds: 1, timerRunning: false), "A reminder must fire once per activity streak")
        assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(195), mouseIdleSeconds: 13, timerRunning: false), "Mouse inactivity resets the streak")
        assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(196), mouseIdleSeconds: 1, timerRunning: false))
        assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(400), mouseIdleSeconds: 1, timerRunning: false), "A sleep-sized polling gap must reset the streak")
        assert(!mouseReminder.shouldRemind(at: activityStart.addingTimeInterval(401), mouseIdleSeconds: 1, timerRunning: true), "Running a project timer resets the streak")

        var credited = TrackingData()
        let creditEnd = activityStart.addingTimeInterval(180)
        try credited.startWithCredit(at: creditEnd, duration: 180, category: .music)
        assert(credited.activeStart == activityStart && credited.checkpoint == creditEnd && credited.currentCategory == .music)
        credited.stop(at: creditEnd.addingTimeInterval(20))
        assert(credited.sessions.count == 1 && credited.sessions[0].duration == 200)
        var overlappingCredit = TrackingData(sessions: [Session(start: activityStart.addingTimeInterval(60), end: activityStart.addingTimeInterval(90))])
        do {
            try overlappingCredit.startWithCredit(at: creditEnd, duration: 180, category: .work)
            fatalError("Backdated starts must not overlap saved sessions")
        } catch SessionEditError.overlapsAnotherSession { }
        assert(overlappingCredit.activeStart == nil)

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
        print("Passed: mouse activity reminder and credited starts, immediate Work and Music starts, short-session discard thresholds, existing-session preservation, independent standing timer, standing edits and deletion, standing overlap and recovery, daily totals, session deletion, quick add, no-overlap checks, missed sessions, cross-midnight totals, session edits, category switching, legacy migration, DST, persistence, corrupt data handling, and CSV export.")
    }
}
