import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let infoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private var client: BambooClient?
    private var entries: [TimesheetEntry]?   // nil = nothing fetched yet
    private var error: String?
    private var timeOff: (week: TimeInterval, fourWeeks: TimeInterval)?  // nil = couldn't fetch
    private var hoursPerDay: [String: Double]?  // company schedule, fetched once per configure
    private var paused = false           // after 401/403: stop auto-refresh until one on menu open succeeds
    private var busy = false             // clock in/out POST in flight
    private var loop: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private weak var liveItem: NSMenuItem?  // top row while clocked in; its title changes on hover

    private var clockedIn: Bool { entries?.contains { $0.isOpen } ?? false }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = editMenu()
        statusItem.button?.font = infoFont
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        configure()
        if client == nil {  // first run: the ⚙ is easy to miss; open once launching has finished
            RunLoop.main.perform { MainActor.assumeIsolated { self.openSettings() } }
        }
    }

    // MARK: Refresh

    private func configure() {
        client = if !Prefs.domain.isEmpty, Keychain.read() != nil, let config = OAuthConfig.current {
            BambooClient(domain: Prefs.domain, tokens: TokenStore(domain: Prefs.domain, config: config))
        } else { nil }
        entries = nil
        timeOff = nil
        hoursPerDay = nil
        error = nil
        paused = false
        render()
        loop?.cancel()
        guard client != nil else { return }
        // Task.sleep uses a continuous clock, so after system sleep the loop fires on wake by itself.
        loop = Task {
            while !Task.isCancelled {
                if !paused { await refresh() }
                try? await Task.sleep(for: .seconds(clockedIn ? 60 : 300))
            }
        }
    }

    /// A newer refresh supersedes one still in flight.
    private func refresh() async {
        inFlight?.cancel()
        let task = Task { await fetch() }
        inFlight = task
        await task.value
    }

    private func fetch() async {
        guard let client else { return }
        do {
            let id = try await employeeId(client)
            if hoursPerDay == nil { hoursPerDay = try? await client.hoursPerDay() }
            let now = Date(), tz = TimeZone.current.identifier, cal = Calendar.current
            let (week, fourWeeks, today) = (dayString(weekStart(now), timeZone: tz),
                                            dayString(weekStart(now, weeksBack: 4), timeZone: tz), dayString(now, timeZone: tz))
            let lastWeekEnd = dayString(cal.date(byAdding: .day, value: -1, to: weekStart(now))!, timeZone: tz)
            // Four weeks back also covers an entry left open overnight into this week; to tomorrow for timezone slack.
            let to = dayString(cal.date(byAdding: .day, value: 1, to: now)!, timeZone: tz)
            async let sheet = client.timesheetEntries(employeeId: id, from: fourWeeks, to: to)
            async let requests = client.approvedTimeOff(employeeId: id, from: fourWeeks, to: today)
            let fresh = try await sheet
            // Best effort: missing time-off permission mustn't break clock in/out.
            let off: (week: TimeInterval, fourWeeks: TimeInterval)? = if let hoursPerDay, let requests = try? await requests {
                (timeOffTime(requests, from: week, to: today, hoursPerDay: hoursPerDay),
                 timeOffTime(requests, from: fourWeeks, to: lastWeekEnd, hoursPerDay: hoursPerDay))
            } else { nil }
            try Task.checkCancellation()
            entries = fresh
            timeOff = off
            error = nil
            paused = false
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
            if (error as? BambooError)?.isAuth == true { paused = true }
        }
        render()
    }

    private func employeeId(_ client: BambooClient) async throws -> Int {
        if Prefs.employeeId == 0 { Prefs.employeeId = try await client.selfEmployeeId() }
        return Prefs.employeeId
    }

    // MARK: Rendering

    private func render() {
        let summary = entries.map { summarize($0, now: Date()) }
        renderButton(summary)
        renderMenu(summary)
    }

    private func renderButton(_ summary: Summary?) {
        guard let button = statusItem.button else { return }
        let symbol: String, title: String
        if client == nil {
            (symbol, title) = ("gearshape", "")
        } else if let summary {
            (symbol, title) = (summary.open != nil ? "circle.fill" : "circle", " " + formatDuration(summary.total))
        } else {
            (symbol, title) = (error != nil ? "exclamationmark.triangle" : "circle.dotted", "")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BambooHR")  // template by default
        if summary?.open != nil, let green = image?.withSymbolConfiguration(.init(paletteColors: [.systemGreen])) {
            green.isTemplate = false
            button.image = green
        } else {
            button.image = image
        }
        button.title = title
    }

    private func renderMenu(_ summary: Summary?) {
        menu.removeAllItems()
        guard client != nil else {
            menu.addItem(row("Not configured", color: .secondaryLabelColor))
            menu.addItem(.separator())
            menu.addItem(timesheetItem())
            menu.addItem(.separator())
            addFooter()
            return
        }

        if let summary {
            menu.addItem(summary.open.flatMap { busy ? nil : liveRow($0) } ?? clockItem())
            if let error { menu.addItem(row("⚠ \(error)", color: .systemRed)) }
        } else {
            menu.addItem(error.map { row("⚠ \($0)", color: .systemRed) } ?? row("Loading…", color: .secondaryLabelColor))
        }
        if paused { menu.addItem(row("Auto-refresh paused — check Settings", color: .secondaryLabelColor)) }

        if let summary {
            if !summary.closed.isEmpty || summary.open == nil { menu.addItem(.separator()) }
            for e in summary.closed {
                menu.addItem(row("\(formatTime(e.start!)) – \(formatTime(e.end!))", right: formatRowDuration(e.duration(at: Date()))))
            }
            if summary.closed.isEmpty && summary.open == nil {
                menu.addItem(row("No entries today", color: .secondaryLabelColor))
            }
            menu.addItem(.separator())
            menu.addItem(row("Total today", right: formatRowDuration(summary.total)))
            menu.addItem(.separator())
            let excl = timeOff == nil ? " (excl. time off)" : ""
            menu.addItem(row("Total this week" + excl, right: formatRowDuration(summary.week + (timeOff?.week ?? 0))))
            menu.addItem(row("Prev. 4 weeks" + excl, right: formatRowDuration(summary.fourWeeks + (timeOff?.fourWeeks ?? 0))))
        }
        menu.addItem(.separator())
        menu.addItem(timesheetItem())
        menu.addItem(.separator())
        addFooter()
    }

    /// Clocked out: "Clock In"; while the POST runs: "Working…".
    private func clockItem() -> NSMenuItem {
        let i = item(busy ? "Working…" : "Clock In", #selector(toggleClock), "k")
        i.isEnabled = !busy
        return i
    }

    /// Clocked in: the open entry, laid out like the entry rows (dot in the checkmark column so the times
    /// line up); clicking it clocks out.
    private func liveRow(_ open: TimesheetEntry) -> NSMenuItem {
        let i = item("", #selector(toggleClock), "k")
        i.attributedTitle = liveTitle(open, hover: false)
        i.state = .on
        i.onStateImage = liveDot
        liveItem = i
        return i
    }

    private func liveTitle(_ open: TimesheetEntry, hover: Bool) -> NSAttributedString {
        // No color: enabled items get AppKit's own text colors, including the highlighted one.
        infoTitle("\(formatTime(open.start!)) – " + (hover ? "(clock out now)" : "(live)"),
                  right: formatRowDuration(open.duration(at: Date())), color: nil)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let liveItem, let open = entries?.first(where: { $0.isOpen }) else { return }
        let hover = item === liveItem
        liveItem.attributedTitle = liveTitle(open, hover: hover)
        liveItem.onStateImage = hover ? stopSquare : liveDot
    }

    /// Disabled until signed in and the employee id is known (it is part of the URL).
    private func timesheetItem() -> NSMenuItem {
        let i = item("Open BambooHR Timesheet", #selector(openTimesheet))
        i.isEnabled = client != nil && Prefs.employeeId != 0
        return i
    }

    private func addFooter() {
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// The live row's only color: on glass, color goes on small status markers, not text. Drawn, not an
    /// SF Symbol: the menu restyles symbols in the checkmark column and drops their color.
    private let liveDot = marker("Live", .systemGreen) { NSBezierPath(ovalIn: $0) }
    /// Only shown highlighted, where the menu draws the checkmark column in the highlight's text color anyway.
    private let stopSquare = marker("Clock out", .labelColor) { NSBezierPath(rect: $0.insetBy(dx: 0.5, dy: 0.5)) }

    private static func marker(_ name: String, _ color: NSColor, _ shape: @escaping (NSRect) -> NSBezierPath) -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill()
            shape(rect).fill()
            return true
        }
        image.accessibilityDescription = name
        return image
    }

    /// Informational, non-clickable row.
    private func row(_ text: String, right: String? = nil, color: NSColor = .labelColor) -> NSMenuItem {
        let i = NSMenuItem()
        i.attributedTitle = infoTitle(text, right: right, color: color)
        i.isEnabled = false
        return i
    }

    /// `right` is right-aligned at a tab stop.
    private func infoTitle(_ text: String, right: String?, color: NSColor?) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .font: infoFont]
        attributes[.foregroundColor] = color
        return NSAttributedString(string: right.map { "\(text)\t\($0)" } ?? text, attributes: attributes)
    }

    // MARK: Actions

    func menuWillOpen(_ menu: NSMenu) {
        render()  // live durations
        Task { await refresh() }
    }

    @objc private func toggleClock() {
        guard let client, !busy else { return }
        let clockingOut = clockedIn
        busy = true
        render()
        Task {
            do {
                let id = try await employeeId(client)
                if clockingOut { try await client.clockOut(employeeId: id) } else { try await client.clockIn(employeeId: id) }
            } catch {
                alert(clockingOut ? "Clock out failed" : "Clock in failed", error.localizedDescription)
            }
            busy = false
            await refresh()
        }
    }

    @objc private func openTimesheet() {
        if let url = URL(string: "https://\(Prefs.domain).bamboohr.com/employees/timesheet/?id=\(Prefs.employeeId)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do { try service.status == .enabled ? service.unregister() : service.register() } catch {
            alert("Launch at Login failed", error.localizedDescription)
        }
    }

    @objc private func openSettings() {
        showSettings { [weak self] in self?.configure() }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Accessory apps have no visible menu bar, but ⌘C/⌘V/⌘A in text fields
    /// only work if these items exist in the main menu.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
