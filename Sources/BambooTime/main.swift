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
    private var timeOffWeek: TimeInterval?  // nil = couldn't fetch
    private var hoursPerDay: [String: Double]?  // company schedule, fetched once per configure
    private var paused = false           // after 401/403: stop auto-refresh until a manual one succeeds
    private var busy = false             // clock in/out POST in flight
    private var loop: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    private var clockedIn: Bool { entries?.contains { $0.isOpen } ?? false }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = editMenu()
        statusItem.button?.font = infoFont
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        configure()
    }

    // MARK: Refresh

    private func configure() {
        let key = Keychain.read() ?? ""
        client = Prefs.domain.isEmpty || key.isEmpty ? nil : BambooClient(domain: Prefs.domain, apiKey: key)
        entries = nil
        timeOffWeek = nil
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
            let (week, today) = (dayString(weekStart(now), timeZone: tz), dayString(now, timeZone: tz))
            // From the day before the week starts, so an entry left open overnight is always found; to tomorrow for timezone slack.
            let from = dayString(cal.date(byAdding: .day, value: -1, to: weekStart(now))!, timeZone: tz)
            let to = dayString(cal.date(byAdding: .day, value: 1, to: now)!, timeZone: tz)
            async let sheet = client.timesheetEntries(employeeId: id, from: from, to: to)
            async let timeOff = client.approvedTimeOff(employeeId: id, from: week, to: today)
            let fresh = try await sheet
            // Best effort: missing time-off permission mustn't break clock in/out.
            let off: TimeInterval? = if let hoursPerDay {
                try? await timeOffTime(timeOff, from: week, to: today, hoursPerDay: hoursPerDay)
            } else { nil }
            try Task.checkCancellation()
            entries = fresh
            timeOffWeek = off
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
            addFooter()
            return
        }

        if let summary {
            menu.addItem(clockItem(summary.open))
            if let error { menu.addItem(row("⚠ \(error)", color: .systemRed)) }
        } else {
            menu.addItem(error.map { row("⚠ \($0)", color: .systemRed) } ?? row("Loading…", color: .secondaryLabelColor))
        }
        if paused { menu.addItem(row("Auto-refresh paused — check API key", color: .secondaryLabelColor)) }

        if let summary {
            menu.addItem(.separator())
            for e in summary.closed {
                menu.addItem(row("\(formatTime(e.start!)) – \(formatTime(e.end!))", right: formatDuration(e.duration(at: Date()))))
            }
            if let open = summary.open {
                menu.addItem(row("\(formatTime(open.start!)) – (live)", right: formatDuration(open.duration(at: Date())), color: .systemGreen))
            }
            if summary.closed.isEmpty && summary.open == nil {
                menu.addItem(row("No entries today", color: .secondaryLabelColor))
            }
            menu.addItem(.separator())
            menu.addItem(row("Total today", right: formatDuration(summary.total)))
            menu.addItem(.separator())
            menu.addItem(row(timeOffWeek == nil ? "Total this week (excl. time off)" : "Total this week",
                             right: formatDuration(summary.week + (timeOffWeek ?? 0))))
        }
        menu.addItem(.separator())
        menu.addItem(item("Refresh", #selector(manualRefresh), "r"))
        menu.addItem(item("Open BambooHR", #selector(openBamboo)))
        menu.addItem(.separator())
        addFooter()
    }

    /// "Clock Out (in since 09:02)", the suffix in the info rows' low-contrast style.
    private func clockItem(_ open: TimesheetEntry?) -> NSMenuItem {
        let i = item(busy ? "Working…" : (open != nil ? "Clock Out" : "Clock In"), #selector(toggleClock), "k")
        i.isEnabled = !busy
        if let start = open?.start, !busy {
            let title = NSMutableAttributedString(string: i.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: " (in since \(formatTime(start)))", attributes: [
                .font: infoFont,
                .foregroundColor: NSColor.secondaryLabelColor]))
            i.attributedTitle = title
        }
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

    /// Informational, non-clickable row; `right` is right-aligned at a tab stop.
    private func row(_ text: String, right: String? = nil, color: NSColor = .labelColor) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(
            string: right.map { "\(text)\t\($0)" } ?? text,
            attributes: [.foregroundColor: color, .paragraphStyle: style, .font: infoFont])
        i.isEnabled = false
        return i
    }

    // MARK: Actions

    func menuWillOpen(_ menu: NSMenu) {
        render()  // live durations
        Task { await refresh() }
    }

    @objc private func manualRefresh() {
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

    @objc private func openBamboo() {
        if let url = URL(string: "https://\(Prefs.domain).bamboohr.com/") { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do { try service.status == .enabled ? service.unregister() : service.register() } catch {
            alert("Launch at Login failed", error.localizedDescription)
        }
    }

    @objc private func openSettings() {
        if runSettingsDialog() { configure() }
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
