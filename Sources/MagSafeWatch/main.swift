import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.ps
import ServiceManagement
import UserNotifications

@main
@MainActor
struct MagSafeWatchMain {
    private static let delegate = MagSafeWatchApp()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class MagSafeWatchApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = PowerMonitor()
    private let motionClassifier = MotionClassifier()
    private let inputMonitor = InputActivityMonitor()
    private let settings = AppSettings()
    private let diagnosticsLog = DiagnosticsLog()
    private lazy var notifier = AlertNotifier(settings: settings, diagnosticsLog: diagnosticsLog)
    private lazy var updateChecker = UpdateChecker(settings: settings)
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var monitoringMenuItem: NSMenuItem!
    private var batteryStatusMenuItem: NSMenuItem!
    private var statusWindowController: StatusWindowController?
    private var reminderTimer: Timer?
    private var fullScreenWarningTimer: Timer?
    private var fullScreenWarningController: FullScreenWarningWindowController?
    private var fullScreenWarningID = UUID()
    private var fullScreenSnoozedUntil: Date?
    private var fullScreenSnoozeBatteryThreshold: Int?
    private var accidentalDisconnectAlerted = false
    private var updateTimer: Timer?
    private var latestReleaseURL: URL?
    private var latestState = PowerState(isOnACPower: true, sourceDescription: "Unknown", batteryPercent: nil)
    private var motionCheckID = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()
        configureMainMenu()
        applyPresentationSettings()
        showStatusWindow()
        notifier.requestAuthorization()

        monitor.onChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handlePowerState(state)
            }
        }
        monitor.start()
        inputMonitor.start()
        applyLaunchAtLoginSetting()
        scheduleUpdateChecks()
    }

    private func configureApplicationIcon() {
        guard let image = NSImage(named: "MagSafeWatchBrand") ?? NSImage(named: "MagSafeWatch") else {
            return
        }
        NSApp.applicationIconImage = image
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        inputMonitor.stop()
        updateTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showStatusWindow()
        }
        return true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "MagSafe Watch")
        appMenu.addItem(NSMenuItem(title: "About MagSafe Watch", action: #selector(showStatusWindow), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "Notifications", action: #selector(openNotifications), keyEquivalent: "n"))
        appMenu.addItem(NSMenuItem(title: "Permissions", action: #selector(openPermissions), keyEquivalent: "p"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MagSafe Watch", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Show MagSafe Watch", action: #selector(showStatusWindow), keyEquivalent: "0"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        guard statusItem == nil else {
            refreshStatusMenu()
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel("MagSafe Watch")

        statusMenu = NSMenu()
        statusMenu.delegate = self

        let titleItem = NSMenuItem(title: "MagSafe.watch", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        statusMenu.addItem(titleItem)

        monitoringMenuItem = NSMenuItem(title: "Monitoring", action: #selector(toggleMonitoringFromMenu), keyEquivalent: "")
        statusMenu.addItem(monitoringMenuItem)

        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Notifications", action: #selector(openNotifications), keyEquivalent: "n"))
        statusMenu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))

        statusMenu.addItem(NSMenuItem.separator())
        batteryStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryStatusMenuItem.isEnabled = true
        statusMenu.addItem(batteryStatusMenuItem)

        statusItem.menu = statusMenu
        updateStatusIcon(for: latestState)
        refreshStatusMenu()
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        statusMenu = nil
        monitoringMenuItem = nil
        batteryStatusMenuItem = nil
    }

    private func applyPresentationSettings() {
        if !settings.showMenuBarItem && !settings.showDockIcon {
            settings.showDockIcon = true
            settings.save()
        }

        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)

        if settings.showMenuBarItem {
            configureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusMenu()
    }

    private func handlePowerState(_ state: PowerState) {
        latestState = state
        updateStatusIcon(for: state)
        statusWindowController?.update(
            state: state,
            idleSeconds: UserActivity.idleSeconds,
            motionStatus: motionClassifier.statusDescription,
            inputStatus: inputMonitor.statusDescription
        )

        guard settings.monitorEnabled else { return }

        if state.isOnACPower {
            diagnosticsLog.add("Power restored: \(state.sourceDescription). Clearing unplug warning state.")
            motionCheckID = UUID()
            reminderTimer?.invalidate()
            reminderTimer = nil
            accidentalDisconnectAlerted = false
            cancelFullScreenWarning()
            return
        }

        showBatteryThresholdWarningIfNeeded(state: state)
        classifyDisconnect(state: state)
    }

    private func updateStatusIcon(for state: PowerState) {
        statusItem?.button?.toolTip = "MagSafe Watch: \(state.sourceDescription)"
        statusItem?.button?.image = menuBarImage(for: state)
        refreshStatusMenu()
    }

    private func menuBarImage(for state: PowerState) -> NSImage? {
        let imageName = menuBarImageName(isCharging: state.isOnACPower, batteryPercent: state.batteryPercent)
        let image = NSImage(named: imageName) ?? NSImage(named: "MagSafeWatchMenuBar") ?? NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "MagSafe Watch")
        image?.isTemplate = false
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func menuBarImageName(isCharging: Bool, batteryPercent: Int?) -> String {
        let percent = batteryPercent.map { min(max($0, 0), 100) }
        if isCharging {
            guard let percent else { return "MagSafeWatchMenuBarCharging0" }
            if percent >= 95 { return "MagSafeWatchMenuBarChargingFull" }
            if percent >= 80 { return "MagSafeWatchMenuBarCharging80" }
            if percent >= 60 { return "MagSafeWatchMenuBarCharging60" }
            if percent >= 50 { return "MagSafeWatchMenuBarCharging50" }
            if percent >= 30 { return "MagSafeWatchMenuBarCharging30" }
            if percent >= 20 { return "MagSafeWatchMenuBarCharging20" }
            return "MagSafeWatchMenuBarCharging0"
        }

        guard let percent else { return "MagSafeWatchMenuBarNotCharging0" }
        if percent >= 100 { return "MagSafeWatchMenuBarNotChargingFull" }
        if percent >= 95 { return "MagSafeWatchMenuBarNotCharging6" }
        if percent >= 80 { return "MagSafeWatchMenuBarNotCharging5" }
        if percent >= 65 { return "MagSafeWatchMenuBarNotCharging4" }
        if percent >= 50 { return "MagSafeWatchMenuBarNotCharging3" }
        if percent >= 35 { return "MagSafeWatchMenuBarNotCharging2" }
        if percent >= 20 { return "MagSafeWatchMenuBarNotCharging1" }
        return "MagSafeWatchMenuBarNotCharging0"
    }

    private func refreshStatusMenu() {
        guard let monitoringMenuItem, let batteryStatusMenuItem else { return }

        monitoringMenuItem.state = settings.monitorEnabled ? .on : .off
        monitoringMenuItem.title = settings.monitorEnabled ? "Monitoring On" : "Monitoring Off"

        let batteryColor = Self.batteryColor(for: latestState.batteryPercent)
        let statusPrefix = latestState.isOnACPower ? "MagSafe Connected" : "MagSafe Disconnected"
        let batteryText: String
        if let batteryPercent = latestState.batteryPercent {
            batteryText = "\(batteryPercent)%"
            batteryStatusMenuItem.image = batterySymbol(percent: batteryPercent, isCharging: latestState.isOnACPower)
        } else {
            batteryText = "Battery Unknown"
            batteryStatusMenuItem.image = batterySymbol(percent: nil, isCharging: latestState.isOnACPower)
        }

        let title = NSMutableAttributedString(
            string: "\(statusPrefix) / ",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        title.append(NSAttributedString(string: batteryText, attributes: [.foregroundColor: batteryColor]))
        batteryStatusMenuItem.attributedTitle = title
    }

    private static func batteryColor(for percent: Int?) -> NSColor {
        guard let percent else { return .secondaryLabelColor }
        if percent <= 10 { return .systemRed }
        if percent <= 25 { return .systemOrange }
        return .systemGreen
    }

    private func batterySymbol(percent: Int?, isCharging: Bool) -> NSImage? {
        let symbolName: String
        if isCharging {
            symbolName = "battery.100.bolt"
        } else if let percent {
            switch percent {
            case ...10:
                symbolName = "battery.0"
            case ...25:
                symbolName = "battery.25"
            case ...50:
                symbolName = "battery.50"
            case ...75:
                symbolName = "battery.75"
            default:
                symbolName = "battery.100"
            }
        } else {
            symbolName = "battery.100"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [Self.batteryColor(for: percent)]))
        image?.isTemplate = false
        return image
    }

    private func classifyDisconnect(state: PowerState) {
        guard settings.motionDetectionEnabled else {
            diagnosticsLog.add("Power lost: motion detection disabled. Falling back to idle/input checks.")
            classifyDisconnectWithIdleFallback(state: state, reason: "Motion detection is switched off.")
            return
        }

        diagnosticsLog.add("Power lost: sampling motion for \(Int(settings.motionSampleWindow))s.")
        let checkID = UUID()
        motionCheckID = checkID
        statusWindowController?.update(
            state: state,
            idleSeconds: UserActivity.idleSeconds,
            motionStatus: "Sampling motion...",
            inputStatus: inputMonitor.statusDescription
        )

        motionClassifier.classify(
            sampleDuration: settings.motionSampleWindow,
            movementThreshold: settings.movementThreshold
        ) { [weak self] result in
            guard let self, self.motionCheckID == checkID, !self.latestState.isOnACPower else { return }
            self.statusWindowController?.update(
                state: self.latestState,
                idleSeconds: UserActivity.idleSeconds,
                motionStatus: result.statusDescription,
                inputStatus: self.inputMonitor.statusDescription
            )

            switch result {
            case .stationary:
                self.diagnosticsLog.add("Motion result: stationary. Sending accidental-unplug alert.")
                self.sendAccidentalUnplugAlert(source: state.sourceDescription, reason: result.alertReason)
                self.scheduleBatteryReminder()
            case .moving:
                self.diagnosticsLog.add("Motion result: moving. Suppressing first alert and keeping reminders armed.")
                self.scheduleBatteryReminder()
            case .unavailable:
                self.diagnosticsLog.add("Motion result unavailable. Falling back to idle/input checks.")
                self.classifyDisconnectWithIdleFallback(state: state, reason: result.alertReason)
                self.scheduleBatteryReminder()
            }
        }
    }

    private func classifyDisconnectWithIdleFallback(state: PowerState, reason: String) {
        guard settings.idleFallbackEnabled else {
            diagnosticsLog.add("Idle fallback disabled. No accidental-unplug alert sent.")
            return
        }
        if settings.externalInputDeskSignalEnabled {
            let inputContext = inputMonitor.context(recentThreshold: settings.inputActivityWindow)
            switch inputContext {
            case .externalRecent(let age):
                diagnosticsLog.add("External input \(Int(age.rounded()))s ago. Treating as desk use and alerting.")
                sendAccidentalUnplugAlert(source: state.sourceDescription, reason: reason + " External keyboard or mouse activity was detected \(Int(age.rounded()))s ago, so the Mac appears active at the desk.")
                return
            case .builtInRecent:
                diagnosticsLog.add("Built-in input was recent. Treating unplug as likely intentional laptop use.")
                return
            case .idle:
                break
            }
        }

        let idleSeconds = UserActivity.idleSeconds
        guard idleSeconds >= settings.stationaryIdleThreshold else {
            diagnosticsLog.add("Idle fallback waited: \(Int(idleSeconds.rounded()))s idle is below \(Int(settings.stationaryIdleThreshold))s threshold.")
            return
        }
        diagnosticsLog.add("Idle fallback threshold met at \(Int(idleSeconds.rounded()))s. Sending alert.")
        sendAccidentalUnplugAlert(source: state.sourceDescription, reason: reason + " Idle fallback: \(Int(idleSeconds.rounded()))s.")
    }

    private func sendAccidentalUnplugAlert(source: String, reason: String) {
        guard !accidentalDisconnectAlerted else {
            diagnosticsLog.add("Accidental-unplug alert already sent for this disconnect; suppressing duplicate.")
            return
        }
        accidentalDisconnectAlerted = true
        diagnosticsLog.add("Sending accidental-unplug alert: \(reason)")

        notifier.alert(
            title: "MacBook is running on battery",
            body: "Power changed to \(source). \(reason) Check the MagSafe cable."
        )
        notifier.sendWebhookIfConfigured(
            title: "MacBook unplugged",
            message: "Power changed to \(source). \(reason)"
        )
        scheduleFullScreenWarning(reason: reason)
    }

    private func scheduleFullScreenWarning(reason: String, delay: TimeInterval = 30) {
        guard settings.monitorEnabled, !latestState.isOnACPower else { return }
        guard fullScreenSnoozeBatteryThreshold == nil else { return }
        if let fullScreenSnoozedUntil {
            guard Date() >= fullScreenSnoozedUntil else { return }
            self.fullScreenSnoozedUntil = nil
        }

        let warningID = UUID()
        fullScreenWarningID = warningID
        fullScreenWarningTimer?.invalidate()
        diagnosticsLog.add("Scheduling full-screen warning in \(Int(delay))s.")
        fullScreenWarningTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.fullScreenWarningID == warningID,
                      !self.latestState.isOnACPower else { return }
                self.showFullScreenWarning(reason: reason)
            }
        }
    }

    private func showFullScreenWarning(reason: String) {
        guard settings.monitorEnabled, !latestState.isOnACPower else { return }
        diagnosticsLog.add("Showing full-screen warning.")
        if fullScreenWarningController == nil {
            fullScreenWarningController = FullScreenWarningWindowController(settings: settings) { [weak self] snooze in
                self?.handleFullScreenSnooze(snooze)
            }
        }

        fullScreenWarningController?.update(
            batteryPercent: latestState.batteryPercent,
            reason: reason
        )
        fullScreenWarningController?.showWarning()
    }

    private func handleFullScreenSnooze(_ snooze: WarningSnooze) {
        fullScreenWarningController?.close()
        fullScreenWarningController = nil
        fullScreenWarningTimer?.invalidate()
        fullScreenSnoozedUntil = nil
        fullScreenSnoozeBatteryThreshold = nil

        switch snooze {
        case .minutes(let minutes):
            diagnosticsLog.add("Full-screen warning snoozed for \(minutes) minutes.")
            let warningID = UUID()
            fullScreenWarningID = warningID
            fullScreenSnoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            fullScreenWarningTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self,
                          self.fullScreenWarningID == warningID,
                          !self.latestState.isOnACPower else { return }
                    self.fullScreenSnoozedUntil = nil
                    self.showFullScreenWarning(reason: "Snooze expired.")
                }
            }
        case .batteryThreshold(let threshold):
            diagnosticsLog.add("Full-screen warning snoozed until battery reaches \(threshold)%.")
            fullScreenSnoozeBatteryThreshold = threshold
            showBatteryThresholdWarningIfNeeded(state: latestState)
        }
    }

    private func showBatteryThresholdWarningIfNeeded(state: PowerState) {
        guard let threshold = fullScreenSnoozeBatteryThreshold,
              !state.isOnACPower,
              let batteryPercent = state.batteryPercent,
              batteryPercent <= threshold else { return }

        fullScreenSnoozeBatteryThreshold = nil
        diagnosticsLog.add("Battery threshold snooze reached at \(batteryPercent)%. Showing warning.")
        showFullScreenWarning(reason: "Battery has depleted to \(batteryPercent)%.")
    }

    private func cancelFullScreenWarning() {
        fullScreenWarningID = UUID()
        fullScreenWarningTimer?.invalidate()
        fullScreenWarningTimer = nil
        fullScreenSnoozedUntil = nil
        fullScreenSnoozeBatteryThreshold = nil
        fullScreenWarningController?.close()
        fullScreenWarningController = nil
    }

    private func scheduleBatteryReminder() {
        guard settings.repeatRemindersEnabled else {
            diagnosticsLog.add("Repeat reminders disabled.")
            return
        }
        reminderTimer?.invalidate()
        diagnosticsLog.add("Scheduling repeat reminders every \(Int(settings.repeatAlertInterval))s.")
        reminderTimer = Timer.scheduledTimer(
            timeInterval: settings.repeatAlertInterval,
            target: self,
            selector: #selector(handleReminderTimer),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleReminderTimer() {
        guard !latestState.isOnACPower else { return }
        classifyReminder()
    }

    private func classifyReminder() {
        guard settings.repeatRemindersEnabled else { return }
        guard settings.motionDetectionEnabled else {
            sendIdleFallbackReminder()
            return
        }

        motionClassifier.classify(
            sampleDuration: settings.motionSampleWindow,
            movementThreshold: settings.movementThreshold
        ) { [weak self] result in
            guard let self, !self.latestState.isOnACPower else { return }
            self.statusWindowController?.update(
                state: self.latestState,
                idleSeconds: UserActivity.idleSeconds,
                motionStatus: result.statusDescription,
                inputStatus: self.inputMonitor.statusDescription
            )

            switch result {
            case .stationary:
                self.diagnosticsLog.add("Reminder check: stationary. Sending still-on-battery reminder.")
                self.notifier.alert(
                    title: "Still on battery",
                    body: "The MacBook is still unplugged and motionless."
                )
                self.notifier.sendWebhookIfConfigured(
                    title: "MacBook still unplugged",
                    message: "The MacBook is still unplugged and motionless."
                )
            case .moving:
                self.diagnosticsLog.add("Reminder check: moving. Reminder suppressed.")
                break
            case .unavailable:
                self.diagnosticsLog.add("Reminder check: motion unavailable. Using idle fallback.")
                self.sendIdleFallbackReminder()
            }
        }
    }

    private func sendIdleFallbackReminder() {
        guard settings.idleFallbackEnabled else {
            diagnosticsLog.add("Reminder skipped: idle fallback disabled.")
            return
        }
        if settings.externalInputDeskSignalEnabled {
            switch inputMonitor.context(recentThreshold: settings.inputActivityWindow) {
            case .externalRecent:
                diagnosticsLog.add("Reminder sent: external input indicates desk use.")
                notifier.alert(
                    title: "Still on battery",
                    body: "The MacBook is still unplugged while external keyboard or mouse input suggests desk use."
                )
                notifier.sendWebhookIfConfigured(
                    title: "MacBook still unplugged",
                    message: "The MacBook is still unplugged while external keyboard or mouse input suggests desk use."
                )
                return
            case .builtInRecent:
                diagnosticsLog.add("Reminder skipped: built-in input suggests active laptop use.")
                return
            case .idle:
                break
            }
        }

        guard UserActivity.idleSeconds >= settings.stationaryIdleThreshold else {
            diagnosticsLog.add("Reminder skipped: idle time below threshold.")
            return
        }
        diagnosticsLog.add("Reminder sent: idle fallback threshold met.")
        notifier.alert(
            title: "Still on battery",
            body: "Motion detection is unavailable or switched off, and the Mac has been idle."
        )
        notifier.sendWebhookIfConfigured(
            title: "MacBook still unplugged",
            message: "Motion detection is unavailable or switched off, and the Mac has been idle."
        )
    }

    @objc private func sendTestAlert() {
        notifier.alert(title: "MagSafe Watch test", body: "Alerts are working on this Mac.")
    }

    @objc private func sendTestSound() {
        notifier.testSound()
    }

    @objc private func sendTestLocalNotification() {
        notifier.testLocalNotification()
    }

    @objc private func sendTestWebhook() {
        notifier.testWebhook()
    }

    @objc private func showStatusWindow() {
        if statusWindowController == nil {
            statusWindowController = StatusWindowController(
                settings: settings,
                testAlertHandler: { [weak self] in self?.sendTestAlert() },
                notificationPermissionHandler: { [weak self] in self?.notifier.requestAuthorization() },
                checkForUpdatesHandler: { [weak self] in self?.checkForUpdates(manual: true) },
                openLatestReleaseHandler: { [weak self] in self?.openLatestReleasePage() },
                updateScheduleChangedHandler: { [weak self] in self?.scheduleUpdateChecks() },
                monitorChangedHandler: { [weak self] in self?.handleMonitoringSettingChanged() },
                launchAtLoginChangedHandler: { [weak self] in self?.applyLaunchAtLoginSetting() },
                presentationChangedHandler: { [weak self] in self?.applyPresentationSettings() },
                openConfigHandler: { [weak self] in self?.openConfigFile() },
                soundTestHandler: { [weak self] in self?.sendTestSound() },
                localNotificationTestHandler: { [weak self] in self?.sendTestLocalNotification() },
                webhookTestHandler: { [weak self] in self?.sendTestWebhook() },
                diagnosticsProvider: { [weak self] in self?.diagnosticsLog.summary() ?? "No diagnostics recorded yet." }
            )
        }

        statusWindowController?.update(
            state: latestState,
            idleSeconds: UserActivity.idleSeconds,
            motionStatus: motionClassifier.statusDescription,
            inputStatus: inputMonitor.statusDescription
        )
        statusWindowController?.showWindow(nil)
        statusWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        guard settings.autoUpdateChecksEnabled else { return }

        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkForUpdates(manual: false)
            }
        }

        updateTimer = Timer.scheduledTimer(
            timeInterval: settings.updateCheckInterval,
            target: self,
            selector: #selector(checkForUpdatesFromTimer),
            userInfo: nil,
            repeats: true
        )
    }

    private func applyLaunchAtLoginSetting() {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLoginEnabled {
                if service.status != .enabled {
                    try service.register()
                }
                diagnosticsLog.add("Launch at login enabled or awaiting macOS approval.")
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                diagnosticsLog.add("Launch at login disabled.")
            }
        } catch {
            diagnosticsLog.add("Launch at login update failed: \(error.localizedDescription)")
        }
    }

    @objc private func checkForUpdatesFromMenu() {
        showStatusWindow()
        statusWindowController?.showStatusPage()
        checkForUpdates(manual: true)
    }

    @objc private func checkForUpdatesFromTimer() {
        checkForUpdates(manual: false)
    }

    private func checkForUpdates(manual: Bool) {
        statusWindowController?.updateUpdateStatus("Checking for updates...")
        updateChecker.check { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .available(let version, let url):
                    self.latestReleaseURL = url
                    self.statusWindowController?.setReleasePageAvailable(true)
                    self.statusWindowController?.updateUpdateStatus("Update available: \(version)")
                    self.notifier.alert(
                        title: "MagSafe Watch update available",
                        body: "Version \(version) is available. Open the release page from Advanced Config or GitHub."
                    )
                    if manual {
                        NSWorkspace.shared.open(url)
                    }
                case .current(let version, let url):
                    self.latestReleaseURL = url
                    self.statusWindowController?.setReleasePageAvailable(url != nil)
                    self.statusWindowController?.updateUpdateStatus("Up to date: \(version)")
                    if manual {
                        self.notifier.alert(title: "MagSafe Watch is up to date", body: "You are running version \(version).")
                    }
                case .notConfigured:
                    self.latestReleaseURL = nil
                    self.statusWindowController?.setReleasePageAvailable(false)
                    self.statusWindowController?.updateUpdateStatus("Update feed not configured")
                    if manual {
                        self.notifier.alert(
                            title: "Update feed not configured",
                            body: "Add a GitHub latest-release API URL in Advanced Config."
                        )
                    }
                case .failed(let message):
                    self.latestReleaseURL = nil
                    self.statusWindowController?.setReleasePageAvailable(false)
                    self.statusWindowController?.updateUpdateStatus("Update check failed")
                    if manual {
                        self.notifier.alert(title: "Update check failed", body: message)
                    }
                }
            }
        }
    }

    @objc private func openLatestReleasePage() {
        guard let latestReleaseURL else {
            diagnosticsLog.add("Release page not opened: no latest release URL available.")
            return
        }
        NSWorkspace.shared.open(latestReleaseURL)
    }

    @objc private func openSettings() {
        showStatusWindow()
        statusWindowController?.showSettingsPage()
    }

    @objc private func openNotifications() {
        showStatusWindow()
        statusWindowController?.showNotificationsPage()
    }

    @objc private func openPermissions() {
        showStatusWindow()
        statusWindowController?.showPermissionsPage()
    }

    @objc private func toggleMonitoringFromMenu() {
        settings.monitorEnabled.toggle()
        settings.save()
        handleMonitoringSettingChanged()
        refreshStatusMenu()
    }

    private func handleMonitoringSettingChanged() {
        if !settings.monitorEnabled {
            reminderTimer?.invalidate()
            reminderTimer = nil
            accidentalDisconnectAlerted = false
            cancelFullScreenWarning()
        }
    }

    private func openConfigFile() {
        NSWorkspace.shared.open(settings.configFileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum WarningSnooze {
    case minutes(Int)
    case batteryThreshold(Int)

    func matches(_ other: WarningSnooze) -> Bool {
        switch (self, other) {
        case (.minutes(let lhs), .minutes(let rhs)):
            return lhs == rhs
        case (.batteryThreshold(let lhs), .batteryThreshold(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

enum SnoozeKind: String {
    case time
    case battery
}

final class FullScreenWarningWindowController: NSWindowController {
    private let settings: AppSettings
    private let onSnooze: (WarningSnooze) -> Void
    private let batteryValue = NSTextField(labelWithString: "Battery unknown")
    private let reasonValue = NSTextField(wrappingLabelWithString: "")
    private var selectedSnooze: WarningSnooze?
    private var visibleDefaultSnooze: WarningSnooze?
    private weak var selectedSnoozeCard: SnoozeOptionCard?
    private let defaultSelectionCheckbox = NSButton(checkboxWithTitle: "Set this Snooze period as default.", target: nil, action: nil)
    private lazy var confirmButton: NSButton = {
        let button = NSButton(title: "Submit", target: self, action: #selector(confirmSelectedSnooze))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 17, weight: .semibold)
        button.isEnabled = false
        button.keyEquivalent = "\r"
        return button
    }()

    init(settings: AppSettings, onSnooze: @escaping (WarningSnooze) -> Void) {
        self.settings = settings
        self.onSnooze = onSnooze

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        super.init(window: window)
        window.contentView = buildContentView()
        window.defaultButtonCell = confirmButton.cell as? NSButtonCell
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(batteryPercent: Int?, reason: String) {
        if let batteryPercent {
            batteryValue.stringValue = "Battery \(batteryPercent)%"
            batteryValue.textColor = batteryPercent <= 10 ? .systemRed : batteryPercent <= 25 ? .systemOrange : .systemGreen
        } else {
            batteryValue.stringValue = "Battery unknown"
            batteryValue.textColor = .secondaryLabelColor
        }
        reasonValue.stringValue = conciseReason(from: reason)
    }

    func showWarning() {
        guard let window else { return }
        if let screenFrame = NSScreen.main?.frame {
            window.setFrame(screenFrame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContentView() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 30
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Plug MagSafe back in")
        title.font = .systemFont(ofSize: 44, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        let body = NSTextField(wrappingLabelWithString: "Power is disconnected and this Mac appears to be sitting at your desk.")
        body.font = .systemFont(ofSize: 21, weight: .medium)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.maximumNumberOfLines = 2
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 700).isActive = true

        batteryValue.font = .systemFont(ofSize: 24, weight: .semibold)
        batteryValue.alignment = .center

        reasonValue.font = .systemFont(ofSize: 14, weight: .regular)
        reasonValue.textColor = .tertiaryLabelColor
        reasonValue.alignment = .center
        reasonValue.maximumNumberOfLines = 1

        let snoozeControls = buildSnoozeControls()

        let primaryStack = NSStackView(views: [title, body, batteryValue, reasonValue])
        primaryStack.orientation = .vertical
        primaryStack.spacing = 18
        primaryStack.alignment = .centerX

        let stack = NSStackView(views: [primaryStack, snoozeControls])
        stack.orientation = .vertical
        stack.spacing = 30
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(panel)
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            panel.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.66),
            panel.heightAnchor.constraint(lessThanOrEqualTo: content.heightAnchor, multiplier: 0.66),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 900),

            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(greaterThanOrEqualTo: panel.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -36)
        ])

        return content
    }

    private func buildSnoozeControls() -> NSView {
        let timeCards = [
            clockCard(minutes: 10),
            clockCard(minutes: 20),
            clockCard(minutes: 30)
        ]

        let batteryCards = [
            batteryCard(percent: 20, filledBars: 2),
            batteryCard(percent: 10, filledBars: 1),
            batteryCard(percent: 5, filledBars: 0)
        ]

        let choices = choicesView(timeCards: timeCards, batteryCards: batteryCards)
        configureDefaultSelectionCheckbox()

        let stack = NSStackView(views: [choices, defaultSelectionCheckbox, confirmButton])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .centerX
        confirmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        preselectDefaultCard(from: timeCards + batteryCards)
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    private func groupTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }

    private func choicesView(timeCards: [SnoozeOptionCard], batteryCards: [SnoozeOptionCard]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let timeTitle = groupTitle("Snooze for...")
        let batteryTitle = groupTitle("Until Battery depletes to:")
        let timeRow = row(timeCards)
        let batteryRow = row(batteryCards)
        let orLabel = NSTextField(labelWithString: "or")
        orLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        orLabel.textColor = .secondaryLabelColor
        orLabel.alignment = .center

        [timeTitle, batteryTitle, timeRow, batteryRow, orLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            timeTitle.topAnchor.constraint(equalTo: container.topAnchor),
            timeTitle.centerXAnchor.constraint(equalTo: timeRow.centerXAnchor),
            batteryTitle.topAnchor.constraint(equalTo: container.topAnchor),
            batteryTitle.centerXAnchor.constraint(equalTo: batteryRow.centerXAnchor),

            timeRow.topAnchor.constraint(equalTo: timeTitle.bottomAnchor, constant: 12),
            timeRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            timeRow.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            orLabel.leadingAnchor.constraint(equalTo: timeRow.trailingAnchor, constant: 28),
            orLabel.centerYAnchor.constraint(equalTo: timeRow.centerYAnchor),
            orLabel.widthAnchor.constraint(equalToConstant: 34),

            batteryRow.leadingAnchor.constraint(equalTo: orLabel.trailingAnchor, constant: 28),
            batteryRow.topAnchor.constraint(equalTo: batteryTitle.bottomAnchor, constant: 12),
            batteryRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            batteryRow.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func clockCard(minutes: Int) -> SnoozeOptionCard {
        let card = SnoozeOptionCard(title: "\(minutes)", actionTitle: "mins", iconView: ClockFaceView(minutes: minutes), target: self, action: #selector(selectSnoozeCard(_:)))
        card.snooze = .minutes(minutes)
        card.submitAction = { [weak self] in self?.confirmSelectedSnooze() }
        return card
    }

    private func batteryCard(percent: Int, filledBars: Int) -> SnoozeOptionCard {
        let card = SnoozeOptionCard(title: "\(percent)%", actionTitle: "remaining", iconView: BatteryBarsView(filledBars: filledBars), target: self, action: #selector(selectSnoozeCard(_:)))
        card.snooze = .batteryThreshold(percent)
        card.submitAction = { [weak self] in self?.confirmSelectedSnooze() }
        return card
    }

    private func conciseReason(from reason: String) -> String {
        if reason.localizedCaseInsensitiveContains("external keyboard") ||
            reason.localizedCaseInsensitiveContains("external mouse") {
            return "External input suggests this Mac is still at the desk."
        }
        if reason.localizedCaseInsensitiveContains("idle fallback") {
            return "No recent movement or activity was detected."
        }
        if reason.localizedCaseInsensitiveContains("motion sensor") {
            return "Motion data was unavailable, so idle checks were used."
        }
        return "No movement was detected after power disconnected."
    }

    private func select(_ card: SnoozeOptionCard, snooze: WarningSnooze) {
        selectedSnoozeCard?.isSelected = false
        selectedSnoozeCard = card
        card.isSelected = true
        selectedSnooze = snooze
        confirmButton.isEnabled = true
        updateDefaultSelectionCheckbox()
    }

    private func bars(forBatteryPercent percent: Int) -> Int {
        min(max(Int((Double(percent) / 100.0 * 8.0).rounded(.down)), 0), 8)
    }

    private func preselectDefaultCard(from cards: [SnoozeOptionCard]) {
        guard let defaultCard = cards.first(where: { card in
            guard let snooze = card.snooze else { return false }
            return snooze.matches(settings.defaultSnooze)
        }), let snooze = defaultCard.snooze else {
            visibleDefaultSnooze = nil
            updateDefaultSelectionCheckbox()
            return
        }
        visibleDefaultSnooze = snooze
        select(defaultCard, snooze: snooze)
    }

    private func configureDefaultSelectionCheckbox() {
        defaultSelectionCheckbox.target = self
        defaultSelectionCheckbox.action = #selector(toggleDefaultSelectionCheckbox(_:))
        defaultSelectionCheckbox.font = .systemFont(ofSize: 14, weight: .medium)
        defaultSelectionCheckbox.controlSize = .regular
        defaultSelectionCheckbox.state = .off
        defaultSelectionCheckbox.isEnabled = false
        defaultSelectionCheckbox.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        updateDefaultSelectionCheckbox()
    }

    private func updateDefaultSelectionCheckbox() {
        guard let selectedSnooze else {
            defaultSelectionCheckbox.title = "Set this Snooze period as default."
            defaultSelectionCheckbox.state = .off
            defaultSelectionCheckbox.isEnabled = false
            return
        }

        if let visibleDefaultSnooze, selectedSnooze.matches(visibleDefaultSnooze) {
            defaultSelectionCheckbox.title = "This is your default Snooze period."
            defaultSelectionCheckbox.state = .off
            defaultSelectionCheckbox.isEnabled = false
            return
        }

        defaultSelectionCheckbox.title = visibleDefaultSnooze == nil
            ? "Set this Snooze period as default."
            : "Change my default Snooze period to this selection"
        defaultSelectionCheckbox.isEnabled = true
    }

    private func saveSelectedSnoozeAsDefaultIfNeeded() {
        guard defaultSelectionCheckbox.state == .on, let selectedSnooze else { return }
        switch selectedSnooze {
        case .minutes(let minutes):
            settings.defaultSnoozeKind = .time
            settings.defaultSnoozeMinutes = minutes
        case .batteryThreshold(let percent):
            settings.defaultSnoozeKind = .battery
            settings.defaultSnoozeBatteryThreshold = percent
        }
        settings.save()
        visibleDefaultSnooze = selectedSnooze
    }

    @objc private func selectSnoozeCard(_ sender: SnoozeOptionCard) {
        guard let snooze = sender.snooze else { return }
        select(sender, snooze: snooze)
    }

    @objc private func confirmSelectedSnooze() {
        guard let selectedSnooze else { return }
        saveSelectedSnoozeAsDefaultIfNeeded()
        onSnooze(selectedSnooze)
    }

    @objc private func toggleDefaultSelectionCheckbox(_ sender: NSButton) {
        guard sender.state == .on else { return }
        updateDefaultSelectionCheckbox()
    }

}

final class SnoozeOptionCard: NSControl {
    var snooze: WarningSnooze?
    var submitAction: (() -> Void)?
    var isSelected: Bool = false {
        didSet { updateSelectionAppearance() }
    }

    private let stack = NSStackView()

    init(title: String, actionTitle: String, iconView: NSView, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let actionLabel = NSTextField(labelWithString: actionTitle)
        actionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        actionLabel.textColor = .secondaryLabelColor
        actionLabel.alignment = .center

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 10, bottom: 12, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(actionLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 120),
            heightAnchor.constraint(equalToConstant: 156),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateSelectionAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func addInputField(_ field: NSTextField) {
        stack.addArrangedSubview(field)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if isSelected {
                submitAction?()
            } else {
                _ = sendAction(action, to: target)
            }
        case 123, 126:
            window?.selectPreviousKeyView(nil)
        case 124, 125:
            window?.selectNextKeyView(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateSelectionAppearance() {
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.24) : NSColor.white.withAlphaComponent(0.14)).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.24)).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isSelected ? 0.24 : 0.12
        layer?.shadowRadius = isSelected ? 14 : 8
        layer?.shadowOffset = CGSize(width: 0, height: 5)
    }
}

final class ClockFaceView: NSView {
    var minutes: Int? {
        didSet { needsDisplay = true }
    }

    init(minutes: Int?) {
        self.minutes = minutes
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let diameter = min(bounds.width, bounds.height) - 8
        let rect = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = diameter / 2

        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: rect).fill()

        if let minutes, minutes > 0 {
            let endAngle = 90.0 - (Double(minutes % 60) / 60.0 * 360.0)
            let segment = NSBezierPath()
            segment.move(to: center)
            segment.line(to: point(from: center, radius: radius - 2, degrees: 90))
            segment.appendArc(withCenter: center, radius: radius - 2, startAngle: 90, endAngle: endAngle, clockwise: true)
            segment.close()
            NSColor.controlAccentColor.withAlphaComponent(0.34).setFill()
            segment.fill()
        }

        NSColor.labelColor.withAlphaComponent(0.8).setStroke()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = 2
        outline.stroke()

        for degrees in stride(from: 90.0, through: -180.0, by: -90.0) {
            let marker = point(from: center, radius: radius - 7, degrees: degrees)
            NSColor.labelColor.withAlphaComponent(0.62).setFill()
            NSBezierPath(ovalIn: NSRect(x: marker.x - 2, y: marker.y - 2, width: 4, height: 4)).fill()
        }

        NSColor.labelColor.withAlphaComponent(0.78).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }

    private func point(from center: NSPoint, radius: CGFloat, degrees: Double) -> NSPoint {
        let radians = degrees * Double.pi / 180.0
        return NSPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
}

final class BatteryBarsView: NSView {
    var filledBars: Int {
        didSet { needsDisplay = true }
    }

    init(filledBars: Int) {
        self.filledBars = min(max(filledBars, 0), 8)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let body = NSRect(x: 6, y: bounds.midY - 15, width: bounds.width - 18, height: 30)
        let nub = NSRect(x: body.maxX + 2, y: body.midY - 7, width: 6, height: 14)
        let color: NSColor = filledBars == 0 ? .systemRed : filledBars <= 1 ? .systemOrange : .systemGreen

        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7).fill()
        color.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7)
        outline.lineWidth = 2
        outline.stroke()
        NSBezierPath(roundedRect: nub, xRadius: 3, yRadius: 3).stroke()

        let gap: CGFloat = 2
        let inset = body.insetBy(dx: 6, dy: 7)
        let barWidth = (inset.width - gap * 7) / 8
        for index in 0..<8 {
            let rect = NSRect(x: inset.minX + CGFloat(index) * (barWidth + gap), y: inset.minY, width: barWidth, height: inset.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (index < filledBars ? color : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
            path.fill()
        }
    }
}

final class PositiveIntegerFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        if let number = obj as? NSNumber {
            return number.stringValue
        }
        return obj as? String
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let digits = string.filter(\.isNumber)
        obj?.pointee = digits as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.allSatisfy(\.isNumber)
    }
}

final class StatusWindowController: NSWindowController {
    private let settings: AppSettings
    private let testAlertHandler: () -> Void
    private let notificationPermissionHandler: () -> Void
    private let checkForUpdatesHandler: () -> Void
    private let openLatestReleaseHandler: () -> Void
    private let updateScheduleChangedHandler: () -> Void
    private let monitorChangedHandler: () -> Void
    private let launchAtLoginChangedHandler: () -> Void
    private let presentationChangedHandler: () -> Void
    private let openConfigHandler: () -> Void
    private let soundTestHandler: () -> Void
    private let localNotificationTestHandler: () -> Void
    private let webhookTestHandler: () -> Void
    private let diagnosticsProvider: () -> String
    private let powerValue = NSTextField(labelWithString: "Checking...")
    private let idleValue = NSTextField(labelWithString: "Checking...")
    private let motionValue = NSTextField(labelWithString: "Checking...")
    private let inputValue = NSTextField(labelWithString: "Checking...")
    private let updateValue = NSTextField(labelWithString: "Not checked")
    private let openReleaseButton = NSButton(title: "Open Latest Release", target: nil, action: nil)
    private let diagnosticsValue = NSTextField(wrappingLabelWithString: "No diagnostics recorded yet.")
    private let defaultSnoozeKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let defaultSnoozeValueField = NSTextField()
    private let pageTabs = NSSegmentedControl(labels: ["Intro", "Settings", "Notifications", "Permissions", "Status"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageContainer = NSView()

    init(settings: AppSettings, testAlertHandler: @escaping () -> Void, notificationPermissionHandler: @escaping () -> Void, checkForUpdatesHandler: @escaping () -> Void, openLatestReleaseHandler: @escaping () -> Void, updateScheduleChangedHandler: @escaping () -> Void, monitorChangedHandler: @escaping () -> Void, launchAtLoginChangedHandler: @escaping () -> Void, presentationChangedHandler: @escaping () -> Void, openConfigHandler: @escaping () -> Void, soundTestHandler: @escaping () -> Void, localNotificationTestHandler: @escaping () -> Void, webhookTestHandler: @escaping () -> Void, diagnosticsProvider: @escaping () -> String) {
        self.settings = settings
        self.testAlertHandler = testAlertHandler
        self.notificationPermissionHandler = notificationPermissionHandler
        self.checkForUpdatesHandler = checkForUpdatesHandler
        self.openLatestReleaseHandler = openLatestReleaseHandler
        self.updateScheduleChangedHandler = updateScheduleChangedHandler
        self.monitorChangedHandler = monitorChangedHandler
        self.launchAtLoginChangedHandler = launchAtLoginChangedHandler
        self.presentationChangedHandler = presentationChangedHandler
        self.openConfigHandler = openConfigHandler
        self.soundTestHandler = soundTestHandler
        self.localNotificationTestHandler = localNotificationTestHandler
        self.webhookTestHandler = webhookTestHandler
        self.diagnosticsProvider = diagnosticsProvider

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MagSafe Watch"
        window.center()
        super.init(window: window)
        window.contentView = buildContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: PowerState, idleSeconds: TimeInterval, motionStatus: String, inputStatus: String) {
        powerValue.stringValue = state.isOnACPower ? "Power Adapter" : "Battery"
        idleValue.stringValue = "\(Int(idleSeconds.rounded()))s idle"
        motionValue.stringValue = motionStatus
        inputValue.stringValue = inputStatus
        diagnosticsValue.stringValue = diagnosticsProvider()
    }

    func showSettingsPage() {
        selectPage(1)
    }

    func showNotificationsPage() {
        selectPage(2)
    }

    func showPermissionsPage() {
        selectPage(3)
    }

    func showStatusPage() {
        selectPage(4)
    }

    func updateUpdateStatus(_ status: String) {
        updateValue.stringValue = status
    }

    func setReleasePageAvailable(_ available: Bool) {
        openReleaseButton.isEnabled = available
    }

    private func buildContentView() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let brandHeader = buildBrandHeader()

        pageTabs.selectedSegment = 0
        pageTabs.target = self
        pageTabs.action = #selector(changePage)
        pageTabs.segmentStyle = .rounded
        pageTabs.translatesAutoresizingMaskIntoConstraints = false

        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(brandHeader)
        content.addSubview(pageTabs)
        content.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            brandHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            brandHeader.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            brandHeader.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            pageTabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            pageTabs.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            pageTabs.topAnchor.constraint(equalTo: brandHeader.bottomAnchor, constant: 16),
            pageContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: pageTabs.bottomAnchor, constant: 18),
            pageContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        selectPage(0)
        return content
    }

    private func buildBrandHeader() -> NSView {
        let imageView = NSImageView()
        imageView.image = NSImage(named: "MagSafeWatchBrand") ?? NSApp.applicationIconImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "MagSafe Watch")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "Power cable monitoring")
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading

        let stack = NSStackView(views: [imageView, textStack])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 42),
            imageView.heightAnchor.constraint(equalToConstant: 42)
        ])

        return stack
    }

    @objc private func changePage() {
        selectPage(pageTabs.selectedSegment)
    }

    private func selectPage(_ index: Int) {
        pageTabs.selectedSegment = index
        pageContainer.subviews.forEach { $0.removeFromSuperview() }

        let page: NSView
        switch index {
        case 1:
            page = buildSettingsPage()
        case 2:
            page = buildNotificationsPage()
        case 3:
            page = buildPermissionsPage()
        case 4:
            page = buildStatusPage()
        default:
            page = buildIntroPage()
        }

        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 24),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -24),
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.bottomAnchor.constraint(lessThanOrEqualTo: pageContainer.bottomAnchor, constant: -24)
        ])
    }

    private func buildIntroPage() -> NSView {
        let title = heading("MagSafe Watch")
        let body = paragraph("MagSafe Watch runs quietly in the menu bar and watches for accidental power cable disconnections. When your Mac switches to battery power, it checks whether the Mac appears stationary before warning you.")
        let details = paragraph("The app uses macOS power-source events for charger connect/disconnect state. If motion sensor events are available on this Mac, it samples movement after unplug. If not, it can fall back to idle-time checks.")
        let input = paragraph("External keyboard and mouse input is treated differently from built-in laptop input. External input means the Mac may still be sitting on your desk, so the app can keep warning you even while you are typing or using a mouse.")

        let settingsButton = NSButton(title: "Review Settings", target: self, action: #selector(openSettingsPage))
        settingsButton.bezelStyle = .rounded

        let notificationsButton = NSButton(title: "Notification Types", target: self, action: #selector(openNotificationsPage))
        notificationsButton.bezelStyle = .rounded

        let buttons = row([settingsButton, notificationsButton])
        return pageStack([title, body, details, input, buttons])
    }

    private func buildSettingsPage() -> NSView {
        let title = heading("Settings")
        let body = paragraph("Control how MagSafe Watch decides whether a power disconnection looks accidental.")

        let controls: [NSView] = [
            checkbox(title: "Show MagSafe Watch in the menu bar", isOn: settings.showMenuBarItem, action: #selector(toggleShowMenuBarItem(_:))),
            checkbox(title: "Show MagSafe Watch in the Dock", isOn: settings.showDockIcon, action: #selector(toggleShowDockIcon(_:))),
            checkbox(title: "Monitor MagSafe and power adapter changes", isOn: settings.monitorEnabled, action: #selector(toggleMonitor(_:))),
            checkbox(title: "Use motion detection when sensor events are available", isOn: settings.motionDetectionEnabled, action: #selector(toggleMotionDetection(_:))),
            checkbox(title: "Use idle-time fallback when motion data is unavailable", isOn: settings.idleFallbackEnabled, action: #selector(toggleIdleFallback(_:))),
            checkbox(title: "Treat external keyboard or mouse input as desk activity", isOn: settings.externalInputDeskSignalEnabled, action: #selector(toggleExternalInputDeskSignal(_:))),
            checkbox(title: "Repeat reminders while the Mac remains unplugged", isOn: settings.repeatRemindersEnabled, action: #selector(toggleRepeatReminders(_:))),
            checkbox(title: "Show all available snooze periods", isOn: settings.showAllSnoozeOptions, action: #selector(toggleShowAllSnoozeOptions(_:))),
            checkbox(title: "Automatically check for app updates", isOn: settings.autoUpdateChecksEnabled, action: #selector(toggleAutoUpdateChecks(_:))),
            checkbox(title: "Launch MagSafe Watch when I log in", isOn: settings.launchAtLoginEnabled, action: #selector(toggleLaunchAtLogin(_:)))
        ]

        let snoozeControls = buildDefaultSnoozeControls()
        let timing = paragraph("Current timing: \(Int(settings.motionSampleWindow))s motion sample, \(Int(settings.stationaryIdleThreshold))s idle fallback, \(Int(settings.inputActivityWindow))s input window, \(Int(settings.repeatAlertInterval))s repeat reminders, \(Int(settings.updateCheckInterval / 3600))h update checks.")
        let updateFeed = paragraph(settings.updateFeedURL == nil ? "Update feed is not configured. Add a GitHub latest-release API URL in Advanced Config when the repository has releases." : "Update feed is configured.")
        let configButton = NSButton(title: "Open Advanced Config", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded

        return pageStack([title, body] + controls + [snoozeControls, timing, updateFeed, configButton])
    }

    private func buildDefaultSnoozeControls() -> NSView {
        defaultSnoozeKindPopup.removeAllItems()
        defaultSnoozeKindPopup.addItems(withTitles: ["Minutes", "Battery %"])
        defaultSnoozeKindPopup.selectItem(at: settings.defaultSnoozeKind == .time ? 0 : 1)
        defaultSnoozeKindPopup.target = self
        defaultSnoozeKindPopup.action = #selector(updateDefaultSnoozeKind)

        defaultSnoozeValueField.formatter = PositiveIntegerFormatter()
        defaultSnoozeValueField.stringValue = "\(settings.defaultSnoozeValue)"
        defaultSnoozeValueField.target = self
        defaultSnoozeValueField.action = #selector(updateDefaultSnooze)
        if !defaultSnoozeValueField.constraints.contains(where: { $0.firstAttribute == .width }) {
            defaultSnoozeValueField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }

        let label = NSTextField(labelWithString: "Default snooze")
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [label, defaultSnoozeKindPopup, defaultSnoozeValueField])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func buildNotificationsPage() -> NSView {
        let title = heading("Notifications")
        let body = paragraph("Choose how MagSafe Watch gets your attention when it thinks the cable was pulled accidentally.")

        let controls: [NSView] = [
            checkbox(title: "Show macOS notification banners", isOn: settings.localNotificationsEnabled, action: #selector(toggleLocalNotifications(_:))),
            checkbox(title: "Play alert sound on this Mac", isOn: settings.soundEnabled, action: #selector(toggleSound(_:))),
            checkbox(title: "Send webhook push notifications for iPhone or Apple Watch", isOn: settings.webhookNotificationsEnabled, action: #selector(toggleWebhook(_:)))
        ]

        let webhook = paragraph(settings.webhookURL == nil ? "Webhook URL is not configured. Add one in Advanced Config to use iPhone or Apple Watch push services." : "Webhook URL is configured.")
        let testButton = NSButton(title: "Send Test Alert", target: self, action: #selector(sendTestAlert))
        testButton.bezelStyle = .rounded
        let soundButton = NSButton(title: "Test Sound", target: self, action: #selector(testSound))
        soundButton.bezelStyle = .rounded
        let localButton = NSButton(title: "Test Mac Notification", target: self, action: #selector(testLocalNotification))
        localButton.bezelStyle = .rounded
        let webhookButton = NSButton(title: "Test Webhook", target: self, action: #selector(testWebhook))
        webhookButton.bezelStyle = .rounded
        let configButton = NSButton(title: "Open Advanced Config", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded

        return pageStack([title, body] + controls + [webhook, row([testButton, soundButton]), row([localButton, webhookButton, configButton])])
    }

    private func buildPermissionsPage() -> NSView {
        let title = heading("Permissions")
        let body = paragraph("Use these steps after installing the app. macOS requires you to approve notifications before banners and sounds can appear. Input Monitoring may be needed for the external keyboard and mouse desk-activity signal.")

        let notificationStep = numberedStep(
            "1. Allow notifications",
            "Click Request Notification Permission, then allow MagSafe Watch when macOS prompts. If you miss the prompt, open Notification Settings and enable alerts for MagSafe Watch."
        )
        let notificationRequest = NSButton(title: "Request Notification Permission", target: self, action: #selector(requestNotificationPermission))
        notificationRequest.bezelStyle = .rounded
        let notificationSettings = NSButton(title: "Open Notification Settings", target: self, action: #selector(openNotificationSettings))
        notificationSettings.bezelStyle = .rounded

        let inputStep = numberedStep(
            "2. Allow Input Monitoring if prompted",
            "Open Input Monitoring and enable MagSafe Watch if macOS lists it there. This helps the app tell external keyboard or mouse activity apart from built-in laptop input."
        )
        let inputSettings = NSButton(title: "Open Input Monitoring", target: self, action: #selector(openInputMonitoringSettings))
        inputSettings.bezelStyle = .rounded

        let loginStep = numberedStep(
            "3. Optional launch at login",
            "Open Login Items if you want MagSafe Watch to start automatically when you sign in."
        )
        let loginSettings = NSButton(title: "Open Login Items", target: self, action: #selector(openLoginItemsSettings))
        loginSettings.bezelStyle = .rounded

        let privacySettings = NSButton(title: "Open Privacy & Security", target: self, action: #selector(openPrivacySettings))
        privacySettings.bezelStyle = .rounded

        return pageStack([
            title,
            body,
            notificationStep,
            row([notificationRequest, notificationSettings]),
            inputStep,
            row([inputSettings, privacySettings]),
            loginStep,
            loginSettings
        ])
    }

    private func buildStatusPage() -> NSView {
        let title = heading("Status")
        let description = paragraph("You can close this window and the charger monitor will keep running from the menu bar.")

        let powerLabel = label("Power")
        let idleLabel = label("Activity")
        let motionLabel = label("Motion")
        let inputLabel = label("Input")
        let updateLabel = label("Updates")
        let diagnosticsLabel = label("Diagnostics")
        diagnosticsValue.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsValue.textColor = .secondaryLabelColor
        diagnosticsValue.maximumNumberOfLines = 8
        diagnosticsValue.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true

        let grid = NSGridView(views: [
            [powerLabel, powerValue],
            [idleLabel, idleValue],
            [motionLabel, motionValue],
            [inputLabel, inputValue],
            [updateLabel, updateValue],
            [diagnosticsLabel, diagnosticsValue]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.xPlacement = .leading

        let updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        openReleaseButton.target = self
        openReleaseButton.action = #selector(openLatestRelease)
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.isEnabled = false

        let quitButton = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        return pageStack([title, description, grid, row([updateButton, openReleaseButton, quitButton])])
    }

    private func pageStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 26, weight: .semibold)
        return field
    }

    private func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        return field
    }

    private func numberedStep(_ title: String, _ detail: String) -> NSView {
        let titleField = label(title)
        let detailField = paragraph(detail)
        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        return stack
    }

    private func checkbox(title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    @objc private func sendTestAlert() {
        testAlertHandler()
    }

    @objc private func testSound() {
        soundTestHandler()
    }

    @objc private func testLocalNotification() {
        localNotificationTestHandler()
    }

    @objc private func testWebhook() {
        webhookTestHandler()
    }

    @objc private func openSettingsPage() {
        selectPage(1)
    }

    @objc private func openNotificationsPage() {
        selectPage(2)
    }

    @objc private func openConfig() {
        openConfigHandler()
    }

    @objc private func checkForUpdates() {
        checkForUpdatesHandler()
    }

    @objc private func openLatestRelease() {
        openLatestReleaseHandler()
    }

    @objc private func requestNotificationPermission() {
        notificationPermissionHandler()
        openNotificationSettings()
    }

    @objc private func openNotificationSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ])
    }

    @objc private func openInputMonitoringSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    @objc private func openLoginItemsSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.users?LoginItems"
        ])
    }

    @objc private func openPrivacySettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ])
    }

    private func openSystemSettings(_ rawURLs: [String]) {
        for rawURL in rawURLs {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @objc private func toggleMonitor(_ sender: NSButton) {
        settings.monitorEnabled = sender.state == .on
        settings.save()
        monitorChangedHandler()
    }

    @objc private func toggleShowMenuBarItem(_ sender: NSButton) {
        settings.showMenuBarItem = sender.state == .on
        if !settings.showMenuBarItem && !settings.showDockIcon {
            settings.showDockIcon = true
        }
        settings.save()
        presentationChangedHandler()
        selectPage(1)
    }

    @objc private func toggleShowDockIcon(_ sender: NSButton) {
        settings.showDockIcon = sender.state == .on
        if !settings.showDockIcon && !settings.showMenuBarItem {
            settings.showMenuBarItem = true
        }
        settings.save()
        presentationChangedHandler()
        selectPage(1)
    }

    @objc private func toggleMotionDetection(_ sender: NSButton) {
        settings.motionDetectionEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleIdleFallback(_ sender: NSButton) {
        settings.idleFallbackEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleRepeatReminders(_ sender: NSButton) {
        settings.repeatRemindersEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleShowAllSnoozeOptions(_ sender: NSButton) {
        settings.showAllSnoozeOptions = sender.state == .on
        settings.save()
    }

    @objc private func toggleExternalInputDeskSignal(_ sender: NSButton) {
        settings.externalInputDeskSignalEnabled = sender.state == .on
        settings.save()
    }

    @objc private func updateDefaultSnoozeKind() {
        settings.defaultSnoozeKind = defaultSnoozeKindPopup.indexOfSelectedItem == 0 ? .time : .battery
        defaultSnoozeValueField.stringValue = "\(settings.defaultSnoozeValue)"
        settings.save()
    }

    @objc private func updateDefaultSnooze() {
        let rawValue = Int(defaultSnoozeValueField.stringValue) ?? settings.defaultSnoozeValue
        switch settings.defaultSnoozeKind {
        case .time:
            settings.defaultSnoozeMinutes = max(rawValue, 1)
            defaultSnoozeValueField.stringValue = "\(settings.defaultSnoozeMinutes)"
        case .battery:
            settings.defaultSnoozeBatteryThreshold = min(max(rawValue, 1), 100)
            defaultSnoozeValueField.stringValue = "\(settings.defaultSnoozeBatteryThreshold)"
        }
        settings.save()
    }

    @objc private func toggleAutoUpdateChecks(_ sender: NSButton) {
        settings.autoUpdateChecksEnabled = sender.state == .on
        settings.save()
        updateScheduleChangedHandler()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        settings.launchAtLoginEnabled = sender.state == .on
        settings.save()
        launchAtLoginChangedHandler()
    }

    @objc private func toggleLocalNotifications(_ sender: NSButton) {
        settings.localNotificationsEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleSound(_ sender: NSButton) {
        settings.soundEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleWebhook(_ sender: NSButton) {
        settings.webhookNotificationsEnabled = sender.state == .on
        settings.save()
    }
}

struct PowerState: Equatable {
    let isOnACPower: Bool
    let sourceDescription: String
    let batteryPercent: Int?
}

enum MotionResult {
    case stationary(maxDelta: Double, sampleCount: Int)
    case moving(maxDelta: Double, sampleCount: Int)
    case unavailable

    var statusDescription: String {
        switch self {
        case .stationary(let maxDelta, let sampleCount):
            return String(format: "Stationary, max delta %.3f (%d samples)", maxDelta, sampleCount)
        case .moving(let maxDelta, let sampleCount):
            return String(format: "Moving, max delta %.3f (%d samples)", maxDelta, sampleCount)
        case .unavailable:
            return "No user-space motion samples"
        }
    }

    var alertReason: String {
        switch self {
        case .stationary:
            return "No movement was detected after unplug."
        case .moving:
            return "Movement was detected after unplug."
        case .unavailable:
            return "Motion sensor is unavailable."
        }
    }
}

final class MotionClassifier {
    private var manager: IOHIDManager?
    private var sampleTimer: Timer?
    private var finishTimer: Timer?
    private var samples: [Double] = []
    private var completion: ((MotionResult) -> Void)?
    private var threshold: Double = 0.08

    var statusDescription: String {
        "Motion checked after unplug"
    }

    func classify(sampleDuration: TimeInterval, movementThreshold: Double, completion: @escaping (MotionResult) -> Void) {
        stop()
        threshold = movementThreshold
        self.completion = completion
        samples = []

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matches: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Sensor,
                kIOHIDDeviceUsageKey as String: kHIDUsage_Snsr_Motion_Accelerometer3D
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Sensor,
                kIOHIDDeviceUsageKey as String: kHIDUsage_Snsr_Motion_Accelerometer
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let classifier = Unmanaged<MotionClassifier>.fromOpaque(context).takeUnretainedValue()
            classifier.collect(value: value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            stop()
            completion(.unavailable)
            return
        }

        finishTimer = Timer.scheduledTimer(
            timeInterval: sampleDuration,
            target: self,
            selector: #selector(finishClassification),
            userInfo: nil,
            repeats: false
        )
    }

    func stop() {
        sampleTimer?.invalidate()
        finishTimer?.invalidate()
        sampleTimer = nil
        finishTimer = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        completion = nil
        samples.removeAll()
    }

    private func collect(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_Sensor else { return }

        let usage = IOHIDElementGetUsage(element)
        let usageIsRelevant = usage == kHIDUsage_Snsr_Motion_Accelerometer ||
            usage == kHIDUsage_Snsr_Motion_Accelerometer1D ||
            usage == kHIDUsage_Snsr_Motion_Accelerometer2D ||
            usage == kHIDUsage_Snsr_Motion_Accelerometer3D ||
            usage == kHIDUsage_Snsr_Motion_LinearAccelerometer

        guard usageIsRelevant else { return }
        samples.append(IOHIDValueGetScaledValue(value, IOHIDValueScaleType(kIOHIDValueScaleTypePhysical)))
    }

    @objc private func finishClassification() {
        sampleTimer?.invalidate()
        finishTimer?.invalidate()
        sampleTimer = nil
        finishTimer = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil

        let result = classifySamples()
        let callback = completion
        completion = nil
        samples.removeAll()
        callback?(result)
    }

    private func classifySamples() -> MotionResult {
        guard let baseline = samples.first, samples.count >= 3 else {
            return .unavailable
        }

        let maxDelta = samples
            .map { abs($0 - baseline) }
            .max() ?? 0

        if maxDelta >= threshold {
            return .moving(maxDelta: maxDelta, sampleCount: samples.count)
        }
        return .stationary(maxDelta: maxDelta, sampleCount: samples.count)
    }
}

final class DiagnosticsLog: @unchecked Sendable {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let lock = NSLock()
    private var entries: [String] = []
    private let limit = 60

    func add(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = "\(formatter.string(from: Date())) \(message)"
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        NSLog("MagSafe Watch diagnostic: \(message)")
    }

    func summary(maxLines: Int = 8) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return "No diagnostics recorded yet." }
        return entries.suffix(maxLines).joined(separator: "\n")
    }
}

final class PowerMonitor {
    var onChange: ((PowerState) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var previousState: PowerState?

    func start() {
        previousState = currentState()
        if let previousState {
            onChange?(previousState)
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.publishIfChanged()
        }, context).takeRetainedValue()

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private func publishIfChanged() {
        let state = currentState()
        guard state != previousState else { return }
        previousState = state
        onChange?(state)
    }

    private func currentState() -> PowerState {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else {
            return PowerState(isOnACPower: false, sourceDescription: "Unknown", batteryPercent: batteryPercent())
        }

        let isAC = source == kIOPSACPowerValue
        let description: String
        switch source {
        case kIOPSACPowerValue:
            description = "Power Adapter"
        case kIOPSBatteryPowerValue:
            description = "Battery"
        case kIOPSOffLineValue:
            description = "Offline"
        default:
            description = source
        }

        return PowerState(isOnACPower: isAC, sourceDescription: description, batteryPercent: batteryPercent())
    }

    private func batteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = details[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = details[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0 else {
                continue
            }

            return Int((Double(current) / Double(maximum) * 100).rounded())
        }

        return nil
    }
}

enum UserActivity {
    static var idleSeconds: TimeInterval {
        let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let combined = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return min(hid, combined)
    }
}

enum InputContext {
    case externalRecent(age: TimeInterval)
    case builtInRecent(age: TimeInterval)
    case idle
}

final class InputActivityMonitor {
    private var manager: IOHIDManager?
    private var lastExternalInputAt: Date?
    private var lastBuiltInInputAt: Date?

    var statusDescription: String {
        let externalAge = ageDescription(lastExternalInputAt)
        let builtInAge = ageDescription(lastBuiltInInputAt)
        return "External \(externalAge), built-in \(builtInAge)"
    }

    func start() {
        stop()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matches: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Digitizer,
                kIOHIDDeviceUsageKey as String: kHIDUsage_Dig_TouchPad
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<InputActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.record(value: value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    func context(recentThreshold: TimeInterval) -> InputContext {
        let now = Date()
        let externalAge = lastExternalInputAt.map { now.timeIntervalSince($0) }
        let builtInAge = lastBuiltInInputAt.map { now.timeIntervalSince($0) }

        if let externalAge, externalAge <= recentThreshold {
            return .externalRecent(age: externalAge)
        }
        if let builtInAge, builtInAge <= recentThreshold {
            return .builtInRecent(age: builtInAge)
        }
        return .idle
    }

    private func record(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard IOHIDValueGetIntegerValue(value) != 0 || usagePage == kHIDPage_GenericDesktop else {
            return
        }

        let device = IOHIDElementGetDevice(element)
        if isBuiltIn(device: device) {
            lastBuiltInInputAt = Date()
        } else {
            lastExternalInputAt = Date()
        }
        _ = usage
    }

    private func isBuiltIn(device: IOHIDDevice) -> Bool {
        if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) {
            if CFGetTypeID(builtIn) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((builtIn as! CFBoolean))
            }
            if let number = builtIn as? NSNumber {
                return number.boolValue
            }
        }

        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "").lowercased()

        if product.contains("internal") || product.contains("built-in") || product.contains("trackpad") {
            return true
        }
        if transport.contains("usb") || transport.contains("bluetooth") {
            return false
        }
        return false
    }

    private func ageDescription(_ date: Date?) -> String {
        guard let date else { return "none" }
        let age = max(0, Int(Date().timeIntervalSince(date).rounded()))
        return "\(age)s ago"
    }
}

enum UpdateCheckResult {
    case available(version: String, url: URL)
    case current(version: String, url: URL?)
    case notConfigured
    case failed(message: String)
}

private final class UpdateCompletionBox: @unchecked Sendable {
    let completion: (UpdateCheckResult) -> Void

    init(_ completion: @escaping (UpdateCheckResult) -> Void) {
        self.completion = completion
    }
}

final class UpdateChecker {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func check(completion: @escaping (UpdateCheckResult) -> Void) {
        guard let feedURL = settings.updateFeedURL else {
            completion(.notConfigured)
            return
        }

        let completionBox = UpdateCompletionBox(completion)
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completionBox.completion(.failed(message: error.localizedDescription))
                return
            }

            guard let data else {
                completionBox.completion(.failed(message: "No update data was returned."))
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestVersion = Version(release.tagName)
                let currentVersion = Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")

                let releaseURL = URL(string: release.htmlURL)
                if latestVersion > currentVersion, let url = releaseURL {
                    completionBox.completion(.available(version: release.tagName, url: url))
                } else {
                    completionBox.completion(.current(version: currentVersion.description, url: releaseURL))
                }
            } catch {
                completionBox.completion(.failed(message: "The update feed could not be read: \(error.localizedDescription)"))
            }
        }.resume()
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]
    let raw: String

    init(_ raw: String) {
        self.raw = raw
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        parts = cleaned
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    var description: String {
        raw
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct NotificationEvent {
    let title: String
    let message: String
    let source: String
}

protocol NotificationProvider {
    var name: String { get }
    func send(_ event: NotificationEvent)
}

final class SoundNotificationProvider: NotificationProvider {
    let name = "Sound"
    private let settings: AppSettings
    private let diagnosticsLog: DiagnosticsLog

    init(settings: AppSettings, diagnosticsLog: DiagnosticsLog) {
        self.settings = settings
        self.diagnosticsLog = diagnosticsLog
    }

    func send(_ event: NotificationEvent) {
        guard settings.soundEnabled else {
            diagnosticsLog.add("Sound skipped: sound notifications disabled.")
            return
        }
        NSSound(named: "Basso")?.play()
        diagnosticsLog.add("Sound played for: \(event.title).")
    }
}

final class LocalNotificationProvider: NotificationProvider {
    let name = "Mac Notification"
    private let settings: AppSettings
    private let diagnosticsLog: DiagnosticsLog

    init(settings: AppSettings, diagnosticsLog: DiagnosticsLog) {
        self.settings = settings
        self.diagnosticsLog = diagnosticsLog
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [diagnosticsLog] granted, error in
            if let error {
                diagnosticsLog.add("Notification authorization failed: \(error.localizedDescription)")
                NSLog("Notification authorization failed: \(error.localizedDescription)")
            }
            if granted {
                diagnosticsLog.add("Notification authorization granted.")
            } else {
                diagnosticsLog.add("Notification authorization was not granted.")
                NSLog("Notification authorization was not granted.")
            }
        }
    }

    func send(_ event: NotificationEvent) {
        guard settings.localNotificationsEnabled else {
            diagnosticsLog.add("Mac notification skipped: local notifications disabled.")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [diagnosticsLog] error in
            if let error {
                diagnosticsLog.add("Mac notification failed: \(error.localizedDescription)")
                NSLog("Notification delivery failed: \(error.localizedDescription)")
            } else {
                diagnosticsLog.add("Mac notification delivered: \(event.title).")
            }
        }
    }
}

final class WebhookNotificationProvider: NotificationProvider, @unchecked Sendable {
    let name = "Webhook"
    private let settings: AppSettings
    private let diagnosticsLog: DiagnosticsLog
    private let retryDelays: [TimeInterval] = [0, 2, 5]

    init(settings: AppSettings, diagnosticsLog: DiagnosticsLog) {
        self.settings = settings
        self.diagnosticsLog = diagnosticsLog
    }

    func send(_ event: NotificationEvent) {
        guard settings.webhookNotificationsEnabled else {
            diagnosticsLog.add("Webhook skipped: webhook notifications disabled.")
            return
        }
        guard let webhookURL = settings.webhookURL else {
            diagnosticsLog.add("Webhook skipped: no webhook URL configured.")
            return
        }
        send(event, to: webhookURL, attempt: 1)
    }

    private func send(_ event: NotificationEvent, to webhookURL: URL, attempt: Int) {
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": event.title,
            "message": event.message,
            "source": event.source
        ])

        diagnosticsLog.add("Webhook attempt \(attempt)/\(retryDelays.count): \(event.title).")
        URLSession.shared.dataTask(with: request) { [diagnosticsLog] _, response, error in
            if let error {
                diagnosticsLog.add("Webhook attempt \(attempt) failed: \(error.localizedDescription)")
                self.retryIfPossible(event, webhookURL: webhookURL, attempt: attempt)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                diagnosticsLog.add("Webhook attempt \(attempt) completed without HTTP status.")
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                diagnosticsLog.add("Webhook delivered with HTTP \(httpResponse.statusCode).")
                return
            }

            diagnosticsLog.add("Webhook attempt \(attempt) returned HTTP \(httpResponse.statusCode).")
            if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                self.retryIfPossible(event, webhookURL: webhookURL, attempt: attempt)
            }
        }.resume()
    }

    private func retryIfPossible(_ event: NotificationEvent, webhookURL: URL, attempt: Int) {
        guard attempt < retryDelays.count else {
            diagnosticsLog.add("Webhook failed after \(attempt) attempts.")
            return
        }
        let nextAttempt = attempt + 1
        let delay = retryDelays[attempt]
        diagnosticsLog.add("Webhook retry \(nextAttempt) scheduled in \(Int(delay))s.")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(event, to: webhookURL, attempt: nextAttempt)
        }
    }
}

final class AlertNotifier {
    private let soundProvider: SoundNotificationProvider
    private let localProvider: LocalNotificationProvider
    private let webhookProvider: WebhookNotificationProvider

    init(settings: AppSettings, diagnosticsLog: DiagnosticsLog) {
        soundProvider = SoundNotificationProvider(settings: settings, diagnosticsLog: diagnosticsLog)
        localProvider = LocalNotificationProvider(settings: settings, diagnosticsLog: diagnosticsLog)
        webhookProvider = WebhookNotificationProvider(settings: settings, diagnosticsLog: diagnosticsLog)
    }

    func requestAuthorization() {
        localProvider.requestAuthorization()
    }

    func alert(title: String, body: String) {
        let event = NotificationEvent(title: title, message: body, source: Host.current().localizedName ?? "Mac")
        soundProvider.send(event)
        localProvider.send(event)
    }

    func sendWebhookIfConfigured(title: String, message: String) {
        webhookProvider.send(NotificationEvent(title: title, message: message, source: Host.current().localizedName ?? "Mac"))
    }

    func testSound() {
        soundProvider.send(NotificationEvent(title: "Sound test", message: "Testing alert sound.", source: Host.current().localizedName ?? "Mac"))
    }

    func testLocalNotification() {
        localProvider.send(NotificationEvent(title: "MagSafe Watch notification test", message: "Mac notifications are working.", source: Host.current().localizedName ?? "Mac"))
    }

    func testWebhook() {
        webhookProvider.send(NotificationEvent(title: "MagSafe Watch webhook test", message: "Webhook delivery is working.", source: Host.current().localizedName ?? "Mac"))
    }
}

final class AppSettings {
    var showMenuBarItem: Bool
    var showDockIcon: Bool
    var monitorEnabled: Bool
    var motionDetectionEnabled: Bool
    var idleFallbackEnabled: Bool
    var externalInputDeskSignalEnabled: Bool
    var repeatRemindersEnabled: Bool
    var localNotificationsEnabled: Bool
    var soundEnabled: Bool
    var webhookNotificationsEnabled: Bool
    var autoUpdateChecksEnabled: Bool
    var launchAtLoginEnabled: Bool
    var showAllSnoozeOptions: Bool
    var defaultSnoozeKind: SnoozeKind
    var defaultSnoozeMinutes: Int
    var defaultSnoozeBatteryThreshold: Int
    var stationaryIdleThreshold: TimeInterval
    var repeatAlertInterval: TimeInterval
    var motionSampleWindow: TimeInterval
    var inputActivityWindow: TimeInterval
    var updateCheckInterval: TimeInterval
    var movementThreshold: Double
    var webhookURL: URL?
    var updateFeedURL: URL?
    let configFileURL: URL

    var defaultSnooze: WarningSnooze {
        switch defaultSnoozeKind {
        case .time:
            return .minutes(defaultSnoozeMinutes)
        case .battery:
            return .batteryThreshold(defaultSnoozeBatteryThreshold)
        }
    }

    var defaultSnoozeTitle: String {
        switch defaultSnoozeKind {
        case .time:
            return "\(defaultSnoozeMinutes) min"
        case .battery:
            return "battery \(defaultSnoozeBatteryThreshold)%"
        }
    }

    var defaultSnoozeValue: Int {
        switch defaultSnoozeKind {
        case .time:
            return defaultSnoozeMinutes
        case .battery:
            return defaultSnoozeBatteryThreshold
        }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagSafeWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        configFileURL = support.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            let defaults = """
            {
              "showMenuBarItem": true,
              "showDockIcon": true,
              "monitorEnabled": true,
              "motionDetectionEnabled": true,
              "idleFallbackEnabled": true,
              "externalInputDeskSignalEnabled": true,
              "repeatRemindersEnabled": true,
              "localNotificationsEnabled": true,
              "soundEnabled": true,
              "webhookNotificationsEnabled": false,
              "autoUpdateChecksEnabled": true,
              "launchAtLoginEnabled": false,
              "showAllSnoozeOptions": true,
              "defaultSnoozeKind": "time",
              "defaultSnoozeMinutes": 5,
              "defaultSnoozeBatteryThreshold": 20,
              "stationaryIdleThresholdSeconds": 90,
              "motionSampleWindowSeconds": 10,
              "inputActivityWindowSeconds": 15,
              "movementThresholdG": 0.08,
              "repeatAlertIntervalSeconds": 300,
              "updateCheckIntervalHours": 24,
              "updateFeedURL": "",
              "webhookURL": ""
            }
            """
            try? defaults.write(to: configFileURL, atomically: true, encoding: .utf8)
        }

        let data = (try? Data(contentsOf: configFileURL)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        showMenuBarItem = object["showMenuBarItem"] as? Bool ?? true
        showDockIcon = object["showDockIcon"] as? Bool ?? true
        if !showMenuBarItem && !showDockIcon {
            showDockIcon = true
        }
        monitorEnabled = object["monitorEnabled"] as? Bool ?? true
        motionDetectionEnabled = object["motionDetectionEnabled"] as? Bool ?? true
        idleFallbackEnabled = object["idleFallbackEnabled"] as? Bool ?? true
        externalInputDeskSignalEnabled = object["externalInputDeskSignalEnabled"] as? Bool ?? true
        repeatRemindersEnabled = object["repeatRemindersEnabled"] as? Bool ?? true
        localNotificationsEnabled = object["localNotificationsEnabled"] as? Bool ?? true
        soundEnabled = object["soundEnabled"] as? Bool ?? true
        webhookNotificationsEnabled = object["webhookNotificationsEnabled"] as? Bool ?? false
        autoUpdateChecksEnabled = object["autoUpdateChecksEnabled"] as? Bool ?? true
        launchAtLoginEnabled = object["launchAtLoginEnabled"] as? Bool ?? false
        showAllSnoozeOptions = object["showAllSnoozeOptions"] as? Bool ?? true
        defaultSnoozeKind = SnoozeKind(rawValue: object["defaultSnoozeKind"] as? String ?? "") ?? .time
        defaultSnoozeMinutes = max(object["defaultSnoozeMinutes"] as? Int ?? 5, 1)
        defaultSnoozeBatteryThreshold = min(max(object["defaultSnoozeBatteryThreshold"] as? Int ?? 20, 1), 100)
        stationaryIdleThreshold = object["stationaryIdleThresholdSeconds"] as? TimeInterval ?? 90
        motionSampleWindow = object["motionSampleWindowSeconds"] as? TimeInterval ?? 10
        inputActivityWindow = object["inputActivityWindowSeconds"] as? TimeInterval ?? 15
        movementThreshold = object["movementThresholdG"] as? Double ?? 0.08
        repeatAlertInterval = object["repeatAlertIntervalSeconds"] as? TimeInterval ?? 300
        updateCheckInterval = ((object["updateCheckIntervalHours"] as? TimeInterval) ?? 24) * 3600

        if let rawURL = object["webhookURL"] as? String, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webhookURL = URL(string: rawURL)
        } else {
            webhookURL = nil
        }

        if let rawURL = object["updateFeedURL"] as? String, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateFeedURL = URL(string: rawURL)
        } else {
            updateFeedURL = nil
        }
    }

    func save() {
        let object: [String: Any] = [
            "showMenuBarItem": showMenuBarItem,
            "showDockIcon": showDockIcon,
            "monitorEnabled": monitorEnabled,
            "motionDetectionEnabled": motionDetectionEnabled,
            "idleFallbackEnabled": idleFallbackEnabled,
            "externalInputDeskSignalEnabled": externalInputDeskSignalEnabled,
            "repeatRemindersEnabled": repeatRemindersEnabled,
            "localNotificationsEnabled": localNotificationsEnabled,
            "soundEnabled": soundEnabled,
            "webhookNotificationsEnabled": webhookNotificationsEnabled,
            "autoUpdateChecksEnabled": autoUpdateChecksEnabled,
            "launchAtLoginEnabled": launchAtLoginEnabled,
            "showAllSnoozeOptions": showAllSnoozeOptions,
            "defaultSnoozeKind": defaultSnoozeKind.rawValue,
            "defaultSnoozeMinutes": defaultSnoozeMinutes,
            "defaultSnoozeBatteryThreshold": defaultSnoozeBatteryThreshold,
            "stationaryIdleThresholdSeconds": stationaryIdleThreshold,
            "motionSampleWindowSeconds": motionSampleWindow,
            "inputActivityWindowSeconds": inputActivityWindow,
            "movementThresholdG": movementThreshold,
            "repeatAlertIntervalSeconds": repeatAlertInterval,
            "updateCheckIntervalHours": updateCheckInterval / 3600,
            "updateFeedURL": updateFeedURL?.absoluteString ?? "",
            "webhookURL": webhookURL?.absoluteString ?? ""
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: configFileURL, options: .atomic)
    }
}
