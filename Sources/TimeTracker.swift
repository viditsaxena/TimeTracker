import AppKit
import SwiftUI
import Carbon
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
    var onChange: (() -> Void)?

    var isRunning: Bool { data.activeStart != nil }
    var elapsed: TimeInterval { data.activeStart.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

    init(file: DataFile) throws {
        self.file = file
        var loaded = try file.load()
        if loaded.recover() {
            try file.save(loaded)
            notice = "Your previous timer was interrupted. Time through its last saved checkpoint was recovered."
        }
        data = loaded
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        if isRunning, now.timeIntervalSince(data.checkpoint ?? now) >= 30 {
            var next = data
            next.checkpoint = now
            _ = commit(next)
        }
        onChange?()
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
        now = Date()
        var next = data
        if isRunning { next.stop(at: now) } else { next.start(at: now) }
        _ = commit(next)
    }

    func switchCategory(to category: TrackingCategory) {
        guard isRunning, data.currentCategory != category else { return }
        now = Date()
        var next = data
        next.switchCategory(to: category, at: now)
        _ = commit(next)
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

    private var calendar: Calendar { TrackingCalendar.local }
    private var week: DateInterval {
        TrackingCalendar.week(containing: calendar.date(byAdding: .weekOfYear, value: weekOffset, to: tracker.now)!)
    }
    private var days: [Date] { (0..<7).map { calendar.date(byAdding: .day, value: $0, to: week.start)! } }
    private var sessions: [Session] {
        tracker.data.sessions.filter { $0.end > week.start && $0.start < week.end }.sorted { $0.start > $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TimeTracker").font(.system(size: 25, weight: .bold, design: .rounded))
                        Text("A little focus. One session at a time.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(tracker.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                    Text(tracker.isRunning ? tracker.data.currentCategory.rawValue : "Paused").foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    Text(tracker.isRunning ? "\(tracker.data.currentCategory.rawValue.uppercased()) SESSION" : "NEXT SESSION · WORK")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                    Text(TrackingCalendar.clock(tracker.elapsed))
                        .font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Button(action: tracker.toggle) {
                        Label(tracker.isRunning ? "Stop tracking" : "Start tracking", systemImage: tracker.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold)).frame(width: 190).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(tracker.isRunning ? .orange : .indigo).controlSize(.large)
                    Text(tracker.shortcutAvailable ? "⌥ Space  ·  works in any app" : "Global shortcut unavailable · use the button")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 23)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))

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
                    Button("Add missed time…") { showingAddMissedTime = true }.buttonStyle(.link)
                    Button("Export CSV…", action: tracker.export).buttonStyle(.link)
                }
                if sessions.isEmpty {
                    Text(tracker.isRunning && weekOffset == 0 ? "Your current session will appear here when you stop." : "No sessions this week. Press ⌥ Space to begin.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    Text("Click a session to fix its time.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            Button {
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
                                    Spacer()
                                    Text(TrackingCalendar.clock(session.duration)).font(.system(size: 12, design: .monospaced))
                                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit \(session.category.rawValue) session from \(session.start.formatted(date: .abbreviated, time: .shortened))")
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
                Text("Saved on this Mac · Weeks start Monday · Sleep pauses the timer")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            }.padding(26)
        }
        .frame(minWidth: 470, minHeight: 640)
        .sheet(item: $editingSession) { session in
            EditSessionSheet(tracker: tracker, session: session)
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
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var tracker: Tracker!
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var toggleItem: NSMenuItem!
    private var totalsItem: NSMenuItem!
    private var categoryItems: [TrackingCategory: NSMenuItem] = [:]

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
        toggleItem = menu.addItem(withTitle: "Start tracking    ⌥Space", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())
        let categoryHint = menu.addItem(withTitle: "New timers start as Work", action: nil, keyEquivalent: "")
        categoryHint.isEnabled = false
        for category in TrackingCategory.allCases {
            let item = menu.addItem(withTitle: category.rawValue, action: #selector(selectCategory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = category.rawValue
            categoryItems[category] = item
        }
        menu.addItem(.separator())
        totalsItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        totalsItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show TimeTracker", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add missed time…", action: #selector(addMissedTime), keyEquivalent: "").target = self
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
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x54494D45, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        tracker.shortcutAvailable = result == noErr
        if result != noErr { tracker.notice = "Option–Space is already in use. You can still start and stop from this window or the menu bar." }
    }

    private func updateMenu() {
        statusItem.button?.image = tracker.isRunning
            ? NSImage(systemSymbolName: tracker.data.currentCategory == .work ? "briefcase" : "music.note", accessibilityDescription: tracker.data.currentCategory.rawValue)
            : NSImage(systemSymbolName: "timer", accessibilityDescription: "TimeTracker paused")
        statusItem.button?.title = tracker.isRunning ? " " + TrackingCalendar.clock(tracker.elapsed) : ""
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        toggleItem.title = "\(tracker.isRunning ? "Stop" : "Start") tracking    ⌥Space"
        for (category, item) in categoryItems {
            item.state = tracker.data.currentCategory == category ? .on : .off
            item.isEnabled = tracker.isRunning
        }
        let day = TrackingCalendar.local.dateInterval(of: .day, for: tracker.now)!
        totalsItem.title = "Today: Work \(TrackingCalendar.brief(tracker.data.total(in: day, now: tracker.now, category: .work))) · Music \(TrackingCalendar.brief(tracker.data.total(in: day, now: tracker.now, category: .music)))"
        statusItem.button?.toolTip = "TimeTracker · \(tracker.isRunning ? tracker.data.currentCategory.rawValue : "Paused") · Option–Space"
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    @objc func selectCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let category = TrackingCategory(rawValue: raw) else { return }
        tracker.switchCategory(to: category)
    }
    @objc func toggle() { tracker.toggle() }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func addMissedTime() { showWindow(); tracker.addMissedTimeRequest = UUID() }
    @objc func export() { showWindow(); tracker.export() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func willSleep() { tracker.stop(reason: "Timer stopped when your Mac went to sleep or switched users. Start again when you’re ready.") }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tracker else { return .terminateNow }
        return tracker.stop() ? .terminateNow : .terminateCancel
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
