import Foundation

enum TrackingCategory: String, Codable, CaseIterable {
    case work = "Work"
    case music = "Music"
}

struct Session: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var interrupted = false
    var category: TrackingCategory = .work

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    func duration(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
}

struct StandingSession: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var interrupted = false

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    func duration(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }
}

enum SessionEditError: LocalizedError {
    case notFound
    case invalidTime
    case futureTime
    case overlapsAnotherSession
    case noFreeTimeToday

    var errorDescription: String? {
        switch self {
        case .notFound: "This session is no longer in your history."
        case .invalidTime: "The duration must be greater than zero."
        case .futureTime: "A saved session can't end in the future."
        case .overlapsAnotherSession: "This time overlaps another session. Choose a shorter duration or a different time."
        case .noFreeTimeToday: "There isn't an open block that long today. Try fewer minutes or choose an exact time."
        }
    }
}

enum QuickAddResult {
    case extendedRunningSession
    case addedSession(Session)
}

enum DurationInput {
    static func parse(_ input: String) -> TimeInterval? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("m"), let minutes = Int(value.dropLast()), minutes > 0 {
            return TimeInterval(minutes) * 60
        }
        if value.hasSuffix("s"), let seconds = Int(value.dropLast()), seconds > 0 {
            return TimeInterval(seconds)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3, let first = Int(parts[0]), first >= 0 else { return nil }
        switch parts.count {
        case 1:
            return first > 0 ? TimeInterval(first) * 60 : nil
        case 2:
            guard let minutes = Int(parts[1]), (0..<60).contains(minutes) else { return nil }
            let seconds = TimeInterval(first) * 3600 + TimeInterval(minutes) * 60
            return seconds > 0 ? seconds : nil
        default:
            guard let minutes = Int(parts[1]), let seconds = Int(parts[2]),
                  (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
            let total = TimeInterval(first) * 3600 + TimeInterval(minutes) * 60 + TimeInterval(seconds)
            return total > 0 ? total : nil
        }
    }
}

extension Session {
    private enum CodingKeys: String, CodingKey { case id, start, end, interrupted, category }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        interrupted = try values.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        category = try values.decodeIfPresent(TrackingCategory.self, forKey: .category) ?? .work
    }
}

struct TrackingData: Codable {
    var sessions: [Session] = []
    var activeStart: Date?
    var checkpoint: Date?
    var activeCategory: TrackingCategory?
    var standingSessions: [StandingSession] = []
    var standingStart: Date?
    var standingCheckpoint: Date?

    var currentCategory: TrackingCategory { activeCategory ?? .work }

    mutating func editStandingSession(id: UUID, start: Date, end: Date, now: Date) throws {
        guard let index = standingSessions.firstIndex(where: { $0.id == id }) else { throw SessionEditError.notFound }
        guard start < end else { throw SessionEditError.invalidTime }
        guard end <= now else { throw SessionEditError.futureTime }
        guard !standingSessions.contains(where: { $0.id != id && $0.start < end && start < $0.end }),
              !(standingStart.map { start < now && $0 < end } ?? false) else {
            throw SessionEditError.overlapsAnotherSession
        }
        standingSessions[index].start = start
        standingSessions[index].end = end
    }

    @discardableResult
    mutating func deleteStandingSession(id: UUID) throws -> StandingSession {
        guard let index = standingSessions.firstIndex(where: { $0.id == id }) else { throw SessionEditError.notFound }
        return standingSessions.remove(at: index)
    }

    mutating func editSession(id: UUID, start: Date, end: Date, category: TrackingCategory, now: Date) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw SessionEditError.notFound }
        try validateSessionTime(start: start, end: end, excluding: id, now: now)
        sessions[index].start = start
        sessions[index].end = end
        sessions[index].category = category
    }

    @discardableResult
    mutating func deleteSession(id: UUID) throws -> Session {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw SessionEditError.notFound }
        return sessions.remove(at: index)
    }

    mutating func extendSession(id: UUID, by duration: TimeInterval, now: Date) throws {
        guard duration.isFinite, duration > 0 else { throw SessionEditError.invalidTime }
        guard let session = sessions.first(where: { $0.id == id }) else { throw SessionEditError.notFound }
        try editSession(id: id, start: session.start, end: session.end.addingTimeInterval(duration), category: session.category, now: now)
    }

    @discardableResult
    mutating func addTimeToday(duration: TimeInterval, category: TrackingCategory, now: Date, calendar: Calendar) throws -> QuickAddResult {
        guard duration.isFinite, duration > 0 else { throw SessionEditError.invalidTime }
        let dayStart = calendar.startOfDay(for: now)

        // A running timer can absorb missed time directly before it began.
        if let activeStart {
            let earlierStart = activeStart.addingTimeInterval(-duration)
            if earlierStart >= dayStart,
               !sessions.contains(where: { $0.start < activeStart && earlierStart < $0.end }) {
                self.activeStart = earlierStart
                return .extendedRunningSession
            }
        }

        // Otherwise use the latest free block today. Never move or overlap recorded time.
        var occupied = sessions.compactMap { session -> DateInterval? in
            guard session.start < now, session.end > dayStart else { return nil }
            return DateInterval(start: max(session.start, dayStart), end: min(session.end, now))
        }
        if let activeStart {
            occupied.append(DateInterval(start: max(activeStart, dayStart), end: now))
        }
        occupied.sort { $0.start > $1.start }

        var gapEnd = now
        for block in occupied {
            if gapEnd.timeIntervalSince(block.end) >= duration {
                let session = try addSession(endingAt: gapEnd, duration: duration, category: activeStart == nil ? category : currentCategory, now: now)
                return .addedSession(session)
            }
            gapEnd = min(gapEnd, block.start)
        }
        if gapEnd.timeIntervalSince(dayStart) >= duration {
            let session = try addSession(endingAt: gapEnd, duration: duration, category: activeStart == nil ? category : currentCategory, now: now)
            return .addedSession(session)
        }
        throw SessionEditError.noFreeTimeToday
    }

    @discardableResult
    mutating func addSession(endingAt end: Date, duration: TimeInterval, category: TrackingCategory, now: Date) throws -> Session {
        guard duration.isFinite, duration > 0 else { throw SessionEditError.invalidTime }
        let start = end.addingTimeInterval(-duration)
        try validateSessionTime(start: start, end: end, excluding: nil, now: now)
        let session = Session(start: start, end: end, category: category)
        sessions.append(session)
        return session
    }

    private func validateSessionTime(start: Date, end: Date, excluding id: UUID?, now: Date) throws {
        guard start < end else { throw SessionEditError.invalidTime }
        guard end <= now else { throw SessionEditError.futureTime }
        guard !sessions.contains(where: { $0.id != id && $0.start < end && start < $0.end }),
              !(activeStart.map { start < now && $0 < end } ?? false) else {
            throw SessionEditError.overlapsAnotherSession
        }
    }

    mutating func start(at date: Date, category: TrackingCategory = .work) {
        guard activeStart == nil else { return }
        activeStart = date
        checkpoint = date
        activeCategory = category
    }

    mutating func stop(at date: Date, interrupted: Bool = false) {
        guard let start = activeStart else { return }
        sessions.append(Session(start: start, end: max(start, date), interrupted: interrupted, category: currentCategory))
        activeStart = nil
        checkpoint = nil
        activeCategory = nil
    }

    mutating func switchCategory(to category: TrackingCategory, at date: Date) {
        guard let start = activeStart, currentCategory != category else { return }
        let boundary = max(start, date)
        stop(at: boundary)
        self.start(at: boundary, category: category)
    }

    mutating func startStanding(at date: Date) {
        guard standingStart == nil else { return }
        standingStart = date
        standingCheckpoint = date
    }

    mutating func stopStanding(at date: Date, interrupted: Bool = false) {
        guard let start = standingStart else { return }
        standingSessions.append(StandingSession(start: start, end: max(start, date), interrupted: interrupted))
        standingStart = nil
        standingCheckpoint = nil
    }

    mutating func recover() -> Bool {
        let hadActiveTimer = activeStart != nil || standingStart != nil
        if let start = activeStart { stop(at: checkpoint ?? start, interrupted: true) }
        if let start = standingStart { stopStanding(at: standingCheckpoint ?? start, interrupted: true) }
        return hadActiveTimer
    }

    func total(in interval: DateInterval, now: Date, category: TrackingCategory? = nil) -> TimeInterval {
        var result = sessions.reduce(0) { result, session in
            result + (category == nil || session.category == category ? session.duration(in: interval) : 0)
        }
        if let start = activeStart, category == nil || currentCategory == category {
            result += Session(start: start, end: max(start, now)).duration(in: interval)
        }
        return result
    }

    func standingTotal(in interval: DateInterval, now: Date) -> TimeInterval {
        let finished = standingSessions.reduce(0) { $0 + $1.duration(in: interval) }
        guard let start = standingStart else { return finished }
        return finished + StandingSession(start: start, end: max(start, now)).duration(in: interval)
    }
}

extension TrackingData {
    private enum CodingKeys: String, CodingKey {
        case sessions, activeStart, checkpoint, activeCategory
        case standingSessions, standingStart, standingCheckpoint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try values.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        activeStart = try values.decodeIfPresent(Date.self, forKey: .activeStart)
        checkpoint = try values.decodeIfPresent(Date.self, forKey: .checkpoint)
        activeCategory = try values.decodeIfPresent(TrackingCategory.self, forKey: .activeCategory)
        standingSessions = try values.decodeIfPresent([StandingSession].self, forKey: .standingSessions) ?? []
        standingStart = try values.decodeIfPresent(Date.self, forKey: .standingStart)
        standingCheckpoint = try values.decodeIfPresent(Date.self, forKey: .standingCheckpoint)
    }
}

enum TrackingCalendar {
    static var local: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func week(containing date: Date, calendar: Calendar = local) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    static func clock(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    static func brief(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration / 60))
        if minutes == 0 && duration > 0 { return "<1m" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct DataFile {
    let url: URL

    func load() throws -> TrackingData {
        guard FileManager.default.fileExists(atPath: url.path) else { return TrackingData() }
        return try JSONDecoder().decode(TrackingData.self, from: Data(contentsOf: url))
    }

    func save(_ data: TrackingData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: url, options: .atomic)
    }

    static func csv(_ data: TrackingData) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = (
            data.sessions.map { ($0.start, $0.end, $0.duration, $0.interrupted, $0.category.rawValue) } +
            data.standingSessions.map { ($0.start, $0.end, $0.duration, $0.interrupted, "Standing") }
        ).sorted { $0.0 < $1.0 }.map {
            "\(formatter.string(from: $0.0)),\(formatter.string(from: $0.1)),\(Int($0.2)),\($0.3),\($0.4)"
        }
        return (["start_utc,end_utc,duration_seconds,interrupted,category"] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
