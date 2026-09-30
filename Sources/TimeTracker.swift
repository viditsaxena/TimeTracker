import AppKit
import SwiftUI
import Carbon
import CoreGraphics
import UniformTypeIdentifiers

@MainActor
final class Tracker: ObservableObject {
    @Published private(set) var data: TrackingData
    @Published var now = Date()
    @Published var notice: String?
    @Published var shortcutAvailable = false
    @Published var addMissedTimeRequest = UUID()
    private let file: DataFile
    private var timer: Timer?
    private var activityReminder = ComputerActivityReminder()
    var onChange: (() -> Void)?
    var onUntrackedComputerActivity: (() -> Void)?

    var isRunning: Bool { data.activeStart != nil }
    var elapsed: TimeInterval { data.activeStart.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
    var isStanding: Bool { data.standingStart != nil }
    var standingElapsed: TimeInterval { data.standingStart.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    init(file: DataFile) throws {
        self.file = file
        var loaded = try file.load()
        if loaded.recover() {
            try file.save(loaded)
            notice = "A timer was interrupted. Time through its last saved checkpoint was recovered."
        }
        data = loaded
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Menu tracking uses a different run-loop mode from the normal UI.
        RunLoop.main.add(ticker, forMode: .common)
        RunLoop.main.add(ticker, forMode: .eventTracking)
        timer = ticker
    }

    private func tick() {
        now = Date()
        if (isRunning && now.timeIntervalSince(data.checkpoint ?? now) >= 30) ||
           (isStanding && now.timeIntervalSince(data.standingCheckpoint ?? now) >= 30) {
            var next = data
            if isRunning { next.checkpoint = now }
            if isStanding { next.standingCheckpoint = now }
            _ = commit(next)
        }
        onChange?()
        // Only the age of the last input is read; no key or pointer data is stored.
        let inputIdleSeconds = isRunning ? .infinity : [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                      .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
        if activityReminder.shouldRemind(at: now, inputIdleSeconds: inputIdleSeconds, timerRunning: isRunning) {
            onUntrackedComputerActivity?()
        }
    }

    @discardableResult
    private func commit(_ next: TrackingData) -> Bool {
        do {
            try file.save(next)
            data = next
            onChange?()
            return true
        } catch {
            notice = "Couldn’t save your time: \(error.localizedDescription)"
            return false
        }
    }

    func toggle() {
        if isRunning { _ = stop() }
        else { _ = start(category: .work) }
    }

    @discardableResult
    func start(category: TrackingCategory) -> Bool {
        guard !isRunning else { return false }
        now = Date()
        var next = data
        next.start(at: now, category: category)
        return commit(next)
    }

    @discardableResult
    func startWithCredit(category: TrackingCategory) throws -> Bool {
        guard !isRunning else { return false }
        now = Date()
        var next = data
        try next.startWithCredit(at: now, duration: ComputerActivityReminder.threshold, category: category)
        return commit(next)
    }

    func switchCategory(to category: TrackingCategory) {
        guard isRunning, data.currentCategory != category else { return }
        now = Date()
        var next = data
        next.switchCategory(to: category, at: now)
        _ = commit(next)
    }

    func toggleStanding() {
        now = Date()
        var next = data
        if isStanding { next.stopStanding(at: now) }
        else { next.startStanding(at: now) }
        _ = commit(next)
    }

    func editStandingSession(id: UUID, start: Date, duration: TimeInterval) throws {
        now = Date()
        var next = data
        try next.editStandingSession(id: id, start: start, end: start.addingTimeInterval(duration), now: now)
        try file.save(next)
        data = next
        onChange?()
    }

    func deleteStandingSession(id: UUID) throws {
        var next = data
        _ = try next.deleteStandingSession(id: id)
        try file.save(next)
        data = next
        onChange?()
    }

    func editSession(id: UUID, start: Date, duration: TimeInterval, category: TrackingCategory) throws {
        now = Date()
        var next = data
        try next.editSession(id: id, start: start, end: start.addingTimeInterval(duration), category: category, now: now)
        try file.save(next)
        data = next
        onChange?()
    }

    @discardableResult
    func deleteSession(id: UUID) throws -> Session {
        var next = data
        let deleted = try next.deleteSession(id: id)
        try file.save(next)
        data = next
        onChange?()
        return deleted
    }

    @discardableResult
    func addTimeToday(minutes: Int, category: TrackingCategory) throws -> QuickAddResult {
        now = Date()
        var next = data
        let result = try next.addTimeToday(duration: TimeInterval(minutes * 60), category: category, now: now, calendar: TrackingCalendar.local)
        try file.save(next)
        data = next
        onChange?()
        return result
    }

    @discardableResult
    func addSession(endingAt end: Date, duration: TimeInterval, category: TrackingCategory) throws -> Session {
        now = Date()
        var next = data
        let session = try next.addSession(endingAt: end, duration: duration, category: category, now: now)
        try file.save(next)
        data = next
        onChange?()
        return session
    }

    @discardableResult
    func stop(reason: String? = nil) -> Bool {
        guard isRunning else { return true }
        now = Date()
        var next = data
        next.stop(at: now)
        let success = commit(next)
        if success, let reason { notice = reason }
        return success
    }

    @discardableResult
    func stopAll(reason: String? = nil) -> Bool {
        guard isRunning || isStanding else { return true }
        now = Date()
        var next = data
        next.stop(at: now)
        next.stopStanding(at: now)
        let success = commit(next)
        if success, let reason { notice = reason }
        return success
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TimeTracker-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        panel.title = "Export completed sessions"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DataFile.csv(data).write(to: url, atomically: true, encoding: .utf8) }
        catch { notice = "Export failed: \(error.localizedDescription)" }
    }
}

struct Dashboard: View {
    @ObservedObject var tracker: Tracker
    @State private var weekOffset = 0
    @State private var editingSession: Session?
    @State private var showingAddMissedTime = false
    @State private var quickMinutes = 5
    @State private var quickCategory: TrackingCategory = .work
    @State private var quickMessage: String?
    @State private var quickAddFailed = false
    @State private var deletingSessionID: UUID?
    @State private var deleteError: (id: UUID, message: String)?
    @State private var editingStandingSession: StandingSession?
    @State private var deletingStandingID: UUID?
    @State private var standingDeleteError: (id: UUID, message: String)?

    private var calendar: Calendar { TrackingCalendar.local }
    private var week: DateInterval {
        TrackingCalendar.week(containing: calendar.date(byAdding: .weekOfYear, value: weekOffset, to: tracker.now)!)
    }
    private var days: [Date] { (0..<7).map { calendar.date(byAdding: .day, value: $0, to: week.start)! } }
    private var sessions: [Session] {
        tracker.data.sessions.filter { $0.end > week.start && $0.start < week.end }.sorted { $0.start > $1.start }
    }
    private var standingSessions: [StandingSession] {
        tracker.data.standingSessions.filter { $0.end > week.start && $0.start < week.end }.sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TimeTracker").font(.system(size: 25, weight: .bold, design: .rounded))
                        Text("Work, music, and time on your feet.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(tracker.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                    Text(tracker.isRunning ? tracker.data.currentCategory.rawValue : "Paused").foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    Text(tracker.isRunning ? "\(tracker.data.currentCategory.rawValue.uppercased()) SESSION" : "NEXT SESSION · WORK")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        Text(TrackingCalendar.clock(tracker.elapsed))
                            .font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        if let start = tracker.data.activeStart {
                            Text("Started at \(start.formatted(date: calendar.isDate(start, inSameDayAs: tracker.now) ? .omitted : .abbreviated, time: .shortened))")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Button(action: tracker.toggle) {
                        Label(tracker.isRunning ? "Stop tracking" : "Start Work", systemImage: tracker.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold)).frame(width: 190).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(tracker.isRunning ? .orange : .indigo).controlSize(.large)
                    Text(tracker.shortcutAvailable ? "⌥ T  ·  works in any app" : "Global shortcut unavailable · use the button")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 23)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))

                HStack(spacing: 14) {
                    Image(systemName: "figure.stand").font(.system(size: 22)).foregroundStyle(.orange)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tracker.isStanding ? "Standing now" : "Sitting now").font(.headline)
                        Text(tracker.isStanding ? TrackingCalendar.clock(tracker.standingElapsed) : "Standing timer off")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button(tracker.isStanding ? "Sit down" : "Stand up", action: tracker.toggleStanding)
                        .buttonStyle(.borderedProminent).tint(tracker.isStanding ? .orange : .green)
                        .accessibilityLabel(tracker.isStanding ? "Stop standing timer" : "Start standing timer")
                }
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Add missed time").font(.headline)
                        Spacer()
                        if tracker.isRunning {
                            Text("Current \(tracker.data.currentCategory.rawValue) timer")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Category", selection: $quickCategory) {
                                ForEach(TrackingCategory.allCases, id: \.self) { category in
                                    Text(category.rawValue).tag(category)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        Button { quickMinutes -= 5 } label: { Image(systemName: "minus").frame(width: 18) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(quickMinutes <= 5)
                            .accessibilityLabel("Decrease minutes to add")
                        Text("\(quickMinutes) min")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 60)
                            .accessibilityLabel("\(quickMinutes) minutes to add")
                        Button { quickMinutes += 5 } label: { Image(systemName: "plus").frame(width: 18) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(quickMinutes >= 24 * 60)
                            .accessibilityLabel("Increase minutes to add")
                        Button("Add") { quickAdd() }
                            .buttonStyle(.borderedProminent).tint(.indigo).controlSize(.small)
                            .accessibilityLabel("Add \(quickMinutes) minutes today")
                        Spacer(minLength: 0)
                    }
                    if let quickMessage {
                        Text(quickMessage).font(.caption)
                            .foregroundStyle(quickAddFailed ? Color.red : Color.secondary)
                        if quickAddFailed {
                            Button("Choose an exact time…") { showingAddMissedTime = true }
                                .font(.caption).buttonStyle(.link)
                        }
                    } else {
                        Text("Uses the latest open time today.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    summary("Today", interval: calendar.dateInterval(of: .day, for: tracker.now)!)
                    summary("This week", interval: TrackingCalendar.week(containing: tracker.now))
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(weekOffset == 0 ? "This week" : "Weekly overview").font(.headline)
                            Text("\(week.start.formatted(.dateTime.month(.abbreviated).day())) – \(week.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous week")
                        Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }.disabled(weekOffset >= 0).accessibilityLabel("Next week")
                    }
                    WeeklyActivityChart(data: tracker.data, now: tracker.now, days: days, calendar: calendar)
                }

                Divider()
                HStack {
                    Text("Sessions").font(.headline)
                    Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose exact time…") { showingAddMissedTime = true }.buttonStyle(.link)
                    Button("Export CSV…", action: tracker.export).buttonStyle(.link)
                }
                if sessions.isEmpty {
                    Text(tracker.isRunning && weekOffset == 0 ? "Your current session will appear here when you stop." : "No sessions this week. Press ⌥ T to begin.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    Text("Click a session to fix its time.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 10) {
                                    Button {
                                        deletingSessionID = nil
                                        editingSession = session
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 6) {
                                                    Circle().fill(session.category.color).frame(width: 6, height: 6)
                                                    Text(session.category.rawValue).foregroundStyle(session.category.color)
                                                    Text(session.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                                }.font(.system(size: 12, weight: .medium))
                                                Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: calendar.isDate(session.start, inSameDayAs: session.end) ? .omitted : .abbreviated, time: .shortened))\(session.interrupted ? " · recovered" : "")")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 4)
                                            Text(TrackingCalendar.clock(session.duration)).font(.system(size: 12, design: .monospaced))
                                            Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit \(session.category.rawValue) session from \(session.start.formatted(date: .abbreviated, time: .shortened))")
                                    Button {
                                        deleteError = nil
                                        deletingSessionID = session.id
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete session")
                                    .accessibilityLabel("Delete \(session.category.rawValue) session from \(session.start.formatted(date: .abbreviated, time: .shortened))")
                                }
                                if deletingSessionID == session.id {
                                    HStack(spacing: 8) {
                                        Text("Delete this session?").font(.caption).foregroundStyle(.secondary)
                                        Button("Delete") { delete(session) }.tint(.red)
                                        Button("Cancel") { deletingSessionID = nil }
                                    }
                                    .controlSize(.small)
                                }
                                if deleteError?.id == session.id, let message = deleteError?.message {
                                    Text(message).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 9)
                            Divider().opacity(0.5)
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Standing sessions").font(.headline)
                    Text("\(standingSessions.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if standingSessions.isEmpty {
                    Text(tracker.isStanding && weekOffset == 0 ? "This standing block will appear when you sit down." : "No standing time this week.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    Text("Click a standing block to fix its time.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: 0) {
                        ForEach(standingSessions) { session in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 10) {
                                    Button {
                                        deletingStandingID = nil
                                        editingStandingSession = session
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(session.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                                                Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: calendar.isDate(session.start, inSameDayAs: session.end) ? .omitted : .abbreviated, time: .shortened))\(session.interrupted ? " · recovered" : "")")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 4)
                                            Text(TrackingCalendar.clock(session.duration)).font(.system(size: 12, design: .monospaced))
                                            Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit standing session from \(session.start.formatted(date: .abbreviated, time: .shortened))")
                                    Button {
                                        standingDeleteError = nil
                                        deletingStandingID = session.id
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete standing session")
                                    .accessibilityLabel("Delete standing session from \(session.start.formatted(date: .abbreviated, time: .shortened))")
                                }
                                if deletingStandingID == session.id {
                                    HStack(spacing: 8) {
                                        Text("Delete this standing block?").font(.caption).foregroundStyle(.secondary)
                                        Button("Delete") { deleteStanding(session) }.tint(.red)
                                        Button("Cancel") { deletingStandingID = nil }
                                    }.controlSize(.small)
                                }
                                if standingDeleteError?.id == session.id, let message = standingDeleteError?.message {
                                    Text(message).font(.caption).foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 9)
                            Divider().opacity(0.5)
                        }
                    }
                }
                if let notice = tracker.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { tracker.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.foregroundStyle(.secondary).padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Saved on this Mac · Weeks start Monday · Sleep pauses both timers")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            }.padding(26)
        }
        .frame(minWidth: 470, minHeight: 640)
        .sheet(item: $editingSession) { session in
            EditSessionSheet(tracker: tracker, session: session)
        }
        .sheet(item: $editingStandingSession) { session in
            EditStandingSessionSheet(tracker: tracker, session: session)
        }
        .sheet(isPresented: $showingAddMissedTime) {
            AddMissedSessionSheet(
                tracker: tracker,
                initialEnd: min(calendar.date(byAdding: .weekOfYear, value: weekOffset, to: tracker.now) ?? tracker.now, tracker.data.activeStart ?? tracker.now)
            ) { end in
                let currentWeek = TrackingCalendar.week(containing: tracker.now).start
                let addedWeek = TrackingCalendar.week(containing: end.addingTimeInterval(-1)).start
                weekOffset = (calendar.dateComponents([.day], from: currentWeek, to: addedWeek).day ?? 0) / 7
            }
        }
        .onChange(of: tracker.addMissedTimeRequest) { _, _ in
            showingAddMissedTime = true
        }
    }

    private func quickAdd() {
        do {
            let result = try tracker.addTimeToday(minutes: quickMinutes, category: quickCategory)
            weekOffset = 0
            quickAddFailed = false
            switch result {
            case .extendedRunningSession:
                quickMessage = "Added \(quickMinutes) minutes to the current \(tracker.data.currentCategory.rawValue) timer."
            case .addedSession(let session):
                quickMessage = "Added \(quickMinutes) minutes of \(session.category.rawValue), \(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened))."
            }
        } catch {
            quickAddFailed = true
            quickMessage = error.localizedDescription
        }
    }

    private func delete(_ session: Session) {
        do {
            try tracker.deleteSession(id: session.id)
            deletingSessionID = nil
            deleteError = nil
        } catch {
            deleteError = (session.id, error.localizedDescription)
        }
    }

    private func deleteStanding(_ session: StandingSession) {
        do {
            try tracker.deleteStandingSession(id: session.id)
            deletingStandingID = nil
            standingDeleteError = nil
        } catch {
            standingDeleteError = (session.id, error.localizedDescription)
        }
    }

    private func summary(_ title: String, interval: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(TrackingCategory.allCases, id: \.self) { category in
                HStack {
                    Circle().fill(category.color).frame(width: 6, height: 6)
                    Text(category.rawValue).font(.system(size: 12))
                    Spacer(minLength: 4)
                    Text(TrackingCalendar.brief(tracker.data.total(in: interval, now: tracker.now, category: category)))
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            HStack {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("Standing").font(.system(size: 12))
                Spacer(minLength: 4)
                Text(TrackingCalendar.brief(tracker.data.standingTotal(in: interval, now: tracker.now)))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .help("Standing \(TrackingCalendar.clock(tracker.data.standingTotal(in: interval, now: tracker.now)))")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AddMissedSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tracker: Tracker
    let onAdded: (Date) -> Void
    @State private var endedAt: Date
    @State private var category: TrackingCategory = .work
    @State private var customDuration = ""
    @State private var errorMessage: String?

    init(tracker: Tracker, initialEnd: Date, onAdded: @escaping (Date) -> Void) {
        self.tracker = tracker
        self.onAdded = onAdded
        _endedAt = State(initialValue: initialEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Add missed time").font(.system(size: 20, weight: .semibold))
            Text("Choose when you finished, then click how long it took.")
                .font(.callout).foregroundStyle(.secondary)
            DatePicker("Ended", selection: $endedAt, displayedComponents: [.date, .hourAndMinute])
            Picker("Category", selection: $category) {
                ForEach(TrackingCategory.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            HStack(spacing: 8) {
                ForEach([5, 10, 15, 20], id: \.self) { minutes in
                    Button("\(minutes) min") { add(TimeInterval(minutes * 60)) }
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                TextField("Other duration", text: $customDuration)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Other duration in minutes or hours and minutes")
                Button("Add") {
                    if let duration = DurationInput.parse(customDuration) { add(duration) }
                }.disabled(DurationInput.parse(customDuration) == nil)
            }
            Text("For a longer session, type minutes like 45, or hours:minutes like 1:30.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func add(_ duration: TimeInterval) {
        do {
            _ = try tracker.addSession(endingAt: endedAt, duration: duration, category: category)
            onAdded(endedAt)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EditSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tracker: Tracker
    let session: Session
    @State private var start: Date
    @State private var durationText: String
    @State private var category: TrackingCategory
    @State private var errorMessage: String?

    init(tracker: Tracker, session: Session) {
        self.tracker = tracker
        self.session = session
        _start = State(initialValue: session.start)
        _durationText = State(initialValue: TrackingCalendar.clock(session.duration))
        _category = State(initialValue: session.category)
    }

    private var duration: TimeInterval? { DurationInput.parse(durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Edit session").font(.system(size: 20, weight: .semibold))
            Text("Change the start time or duration, then save. Your totals will update.")
                .font(.callout).foregroundStyle(.secondary)
            DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Text("Duration")
                Spacer()
                TextField("Duration", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 115)
                    .accessibilityLabel("Session duration")
            }
            Text("Use minutes, like 45, or hours:minutes, like 1:30.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Category", selection: $category) {
                ForEach(TrackingCategory.allCases, id: \.self) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            if let duration {
                Text("Ends \(start.addingTimeInterval(duration).formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Enter a duration greater than zero.").font(.callout).foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(duration == nil)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func save() {
        guard let duration else { return }
        do {
            try tracker.editSession(id: session.id, start: start, duration: duration, category: category)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EditStandingSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tracker: Tracker
    let session: StandingSession
    @State private var start: Date
    @State private var durationText: String
    @State private var errorMessage: String?

    init(tracker: Tracker, session: StandingSession) {
        self.tracker = tracker
        self.session = session
        _start = State(initialValue: session.start)
        _durationText = State(initialValue: TrackingCalendar.clock(session.duration))
    }

    private var duration: TimeInterval? { DurationInput.parse(durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Edit standing time").font(.system(size: 20, weight: .semibold))
            Text("Change when you stood up or how long you stood, then save.")
                .font(.callout).foregroundStyle(.secondary)
            DatePicker("Started", selection: $start, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Text("Duration")
                Spacer()
                TextField("Duration", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 115)
                    .accessibilityLabel("Standing duration")
            }
            Text("Use minutes, like 45, or hours:minutes, like 1:30.")
                .font(.caption).foregroundStyle(.secondary)
            if let duration {
                Text("Ends \(start.addingTimeInterval(duration).formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Enter a duration greater than zero.").font(.callout).foregroundStyle(.red)
            }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(duration == nil)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func save() {
        guard let duration else { return }
        do {
            try tracker.editStandingSession(id: session.id, start: start, duration: duration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension TrackingCategory {
    var color: Color { self == .work ? .indigo : .teal }
}

struct WeeklyActivityChart: View {
    let data: TrackingData
    let now: Date
    let days: [Date]
    let calendar: Calendar

    private func total(_ day: Date, _ category: TrackingCategory) -> TimeInterval {
        data.total(in: calendar.dateInterval(of: .day, for: day)!, now: now, category: category)
    }

    private func standingTotal(_ day: Date) -> TimeInterval {
        data.standingTotal(in: calendar.dateInterval(of: .day, for: day)!, now: now)
    }

    var body: some View {
        let maximum = max(1, days.flatMap { day in TrackingCategory.allCases.map { total(day, $0) } }.max() ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(TrackingCategory.allCases, id: \.self) { category in
                    HStack(spacing: 5) {
                        Circle().fill(category.color).frame(width: 7, height: 7)
                        Text("\(category.rawValue) · \(TrackingCalendar.brief(days.reduce(0) { $0 + total($1, category) }))")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 8) {
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(TrackingCategory.allCases, id: \.self) { category in
                                let duration = total(day, category)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(category.color.opacity(duration > 0 ? 0.85 : 0.15))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: duration > 0 ? max(3, 80 * duration / maximum) : 2)
                                    .help("\(day.formatted(.dateTime.weekday(.wide))): \(category.rawValue) \(TrackingCalendar.clock(duration))")
                                    .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))) \(category.rawValue)")
                                    .accessibilityValue(TrackingCalendar.clock(duration))
                            }
                        }.frame(height: 80, alignment: .bottom)
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10, weight: calendar.isDateInToday(day) ? .bold : .medium)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
            Divider().opacity(0.5)
            Text("Standing · \(TrackingCalendar.brief(days.reduce(0) { $0 + standingTotal($1) }))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            HStack(spacing: 12) {
                ForEach(days, id: \.self) { day in
                    Text(TrackingCalendar.brief(standingTotal(day)))
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .foregroundStyle(standingTotal(day) > 0 ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .help("\(day.formatted(.dateTime.weekday(.wide))): Standing \(TrackingCalendar.clock(standingTotal(day)))")
                        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))) Standing")
                        .accessibilityValue(TrackingCalendar.clock(standingTotal(day)))
                }
            }
        }
    }
}

private struct ActivityReminderPrompt: View {
    let startWork: () -> Void
    let startMusic: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work/Music timer is off").font(.headline)
            Text("You've been active for 3 minutes. Add that time and start tracking?")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Not now", action: dismiss)
                Spacer(minLength: 0)
                Button("Start Music +3 min", action: startMusic)
                Button("Add 3 min & start Work", action: startWork)
                    .buttonStyle(.borderedProminent).tint(.indigo)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var tracker: Tracker!
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var activityReminderPanel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var toggleItem: NSMenuItem!
    private var standingItem: NSMenuItem!
    private var totalsItem: NSMenuItem!
    private var categoryItems: [TrackingCategory: NSMenuItem] = [:]
    private var wasRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should reveal the existing app, never create two writers.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.TimeTracker")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TimeTracker")
        do { tracker = try Tracker(file: DataFile(url: directory.appendingPathComponent("sessions.json"))) }
        catch {
            let alert = NSAlert()
            alert.messageText = "TimeTracker couldn’t open your saved sessions"
            alert.informativeText = "Your file has been left untouched.\n\(error.localizedDescription)\n\(directory.path)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        toggleItem = menu.addItem(withTitle: "Start Work    ⌥T", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())
        for category in TrackingCategory.allCases {
            let item = menu.addItem(withTitle: category.rawValue, action: #selector(selectCategory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = category.rawValue
            categoryItems[category] = item
        }
        menu.addItem(.separator())
        standingItem = menu.addItem(withTitle: "Stand up", action: #selector(toggleStanding), keyEquivalent: "")
        standingItem.target = self
        menu.addItem(.separator())
        totalsItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        totalsItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show TimeTracker", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Choose exact time…", action: #selector(addMissedTime), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Export CSV…", action: #selector(export), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TimeTracker", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "TimeTracker"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Dashboard(tracker: tracker))
        window.center()
        window.setFrameAutosaveName("TimeTrackerDashboard")

        registerShortcut()
        tracker.onChange = { [weak self] in self?.updateMenu() }
        tracker.onUntrackedComputerActivity = { [weak self] in self?.showActivityReminder() }
        updateMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        showWindow()
    }

    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.toggle() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey), EventHotKeyID(signature: 0x54494D45, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        tracker.shortcutAvailable = result == noErr
        if result != noErr { tracker.notice = "Option–T is already in use. You can still start and stop from this window or the menu bar." }
    }

    private func showActivityReminder() {
        guard !tracker.isRunning, activityReminderPanel?.isVisible != true else { return }
        let panel = activityReminderPanel ?? makeActivityReminderPanel()
        activityReminderPanel = panel
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20,
                                         y: visible.maxY - panel.frame.height - 20))
        }
        panel.orderFrontRegardless()
        NSSound.beep()
    }

    private func makeActivityReminderPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 145),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "TimeTracker reminder"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        panel.contentView = NSHostingView(rootView: ActivityReminderPrompt(
            startWork: { [weak self] in self?.startFromActivityReminder(category: .work) },
            startMusic: { [weak self] in self?.startFromActivityReminder(category: .music) },
            dismiss: { [weak self] in self?.dismissActivityReminder() }
        ))
        return panel
    }

    private func dismissActivityReminder() {
        activityReminderPanel?.orderOut(nil)
    }

    private func startFromActivityReminder(category: TrackingCategory) {
        guard !tracker.isRunning else { return }
        do {
            if try tracker.startWithCredit(category: category) { dismissActivityReminder() }
        } catch {
            tracker.notice = "Couldn't count those 3 minutes: \(error.localizedDescription)"
            dismissActivityReminder()
            showWindow()
        }
    }

    private func updateMenu() {
        if tracker.isRunning && !wasRunning { dismissActivityReminder() }
        wasRunning = tracker.isRunning
        statusItem.button?.image = tracker.isRunning
            ? NSImage(systemSymbolName: tracker.data.currentCategory == .work ? "briefcase" : "music.note", accessibilityDescription: tracker.data.currentCategory.rawValue)
            : NSImage(systemSymbolName: "timer", accessibilityDescription: "TimeTracker paused")
        statusItem.button?.title = tracker.isRunning ? " " + TrackingCalendar.clock(tracker.elapsed) : ""
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        toggleItem.title = tracker.isRunning ? "Stop tracking    ⌥T" : "Start Work    ⌥T"
        standingItem.title = tracker.isStanding ? "Standing now  ·  Sit down" : "Sitting now  ·  Stand up"
        for (category, item) in categoryItems {
            item.state = tracker.isRunning && tracker.data.currentCategory == category ? .on : .off
            item.isEnabled = true
        }
        let day = TrackingCalendar.local.dateInterval(of: .day, for: tracker.now)!
        totalsItem.title = "Today: Work \(TrackingCalendar.brief(tracker.data.total(in: day, now: tracker.now, category: .work))) · Music \(TrackingCalendar.brief(tracker.data.total(in: day, now: tracker.now, category: .music))) · Standing \(TrackingCalendar.brief(tracker.data.standingTotal(in: day, now: tracker.now)))"
        statusItem.button?.toolTip = "TimeTracker · \(tracker.isRunning ? tracker.data.currentCategory.rawValue : "Paused") · \(tracker.isStanding ? "Standing now" : "Sitting now") · Option–T"
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    @objc func selectCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let category = TrackingCategory(rawValue: raw) else { return }
        if tracker.isRunning { tracker.switchCategory(to: category) }
        else { _ = tracker.start(category: category) }
    }
    @objc func toggle() { tracker.toggle() }
    @objc func toggleStanding() { tracker.toggleStanding() }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func addMissedTime() { showWindow(); tracker.addMissedTimeRequest = UUID() }
    @objc func export() { showWindow(); tracker.export() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func willSleep() {
        dismissActivityReminder()
        tracker.stopAll(reason: "Timers stopped when your Mac went to sleep or switched users. Start again when you’re ready.")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tracker else { return .terminateNow }
        return tracker.stopAll() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

@main
enum TimeTrackerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
