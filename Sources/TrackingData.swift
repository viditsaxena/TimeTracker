import Foundation

enum TrackingCategory: String, Codable, CaseIterable {
    case work = "Work"
    case music = "Music"
}

struct Session: Codable, Identifiable {
    var id = UUID()
    let start: Date
    let end: Date
    var interrupted = false
    var category: TrackingCategory = .work

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    func duration(in interval: DateInterval) -> TimeInterval {
        max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
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

    var currentCategory: TrackingCategory { activeCategory ?? .work }

    mutating func start(at date: Date) {
        guard activeStart == nil else { return }
        activeStart = date
        checkpoint = date
        activeCategory = .work
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
        self.start(at: boundary)
        activeCategory = category
    }

    mutating func recover() -> Bool {
        guard let start = activeStart else { return false }
        stop(at: checkpoint ?? start, interrupted: true)
        return true
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
        let rows = data.sessions.sorted { $0.start < $1.start }.map {
            "\(formatter.string(from: $0.start)),\(formatter.string(from: $0.end)),\(Int($0.duration)),\($0.interrupted),\($0.category.rawValue)"
        }
        return (["start_utc,end_utc,duration_seconds,interrupted,category"] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
