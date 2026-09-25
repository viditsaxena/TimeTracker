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
        print("Passed: Work defaults, category switching, separate totals, legacy migration, toggling, cross-week totals, DST, crash recovery, persistence, corrupt data handling, and categorized CSV export.")
    }
}
