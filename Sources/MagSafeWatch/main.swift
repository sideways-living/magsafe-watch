import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.ps
import UserNotifications

@main
@MainActor
final class MagSafeWatchApp: NSObject, NSApplicationDelegate {
    private let monitor = PowerMonitor()
    private let motionClassifier = MotionClassifier()
    private let inputMonitor = InputActivityMonitor()
    private let settings = AppSettings()
    private lazy var notifier = AlertNotifier(settings: settings)
    private lazy var updateChecker = UpdateChecker(settings: settings)
    private var statusItem: NSStatusItem!
    private var statusWindowController: StatusWindowController?
    private var reminderTimer: Timer?
    private var updateTimer: Timer?
    private var latestState = PowerState(isOnACPower: true, sourceDescription: "Unknown")
    private var motionCheckID = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureStatusItem()
        showStatusWindow()
        notifier.requestAuthorization()

        monitor.onChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handlePowerState(state)
            }
        }
        monitor.start()
        inputMonitor.start()
        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        inputMonitor.stop()
        updateTimer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuBarImage = NSImage(named: "MagSafeWatchMenuBar") ?? NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "MagSafe Watch")
        menuBarImage?.isTemplate = true
        statusItem.button?.image = menuBarImage

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "MagSafe Watch", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Status Window", action: #selector(showStatusWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Send Test Alert", action: #selector(sendTestAlert), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
            motionCheckID = UUID()
            reminderTimer?.invalidate()
            reminderTimer = nil
            return
        }

        classifyDisconnect(state: state)
    }

    private func updateStatusIcon(for state: PowerState) {
        statusItem.button?.toolTip = "MagSafe Watch: \(state.sourceDescription)"
    }

    private func classifyDisconnect(state: PowerState) {
        guard settings.motionDetectionEnabled else {
            classifyDisconnectWithIdleFallback(state: state, reason: "Motion detection is switched off.")
            return
        }

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
                self.sendAccidentalUnplugAlert(source: state.sourceDescription, reason: result.alertReason)
                self.scheduleBatteryReminder()
            case .moving:
                self.scheduleBatteryReminder()
            case .unavailable:
                self.classifyDisconnectWithIdleFallback(state: state, reason: result.alertReason)
                self.scheduleBatteryReminder()
            }
        }
    }

    private func classifyDisconnectWithIdleFallback(state: PowerState, reason: String) {
        guard settings.idleFallbackEnabled else { return }
        if settings.externalInputDeskSignalEnabled {
            let inputContext = inputMonitor.context(recentThreshold: settings.inputActivityWindow)
            switch inputContext {
            case .externalRecent(let age):
                sendAccidentalUnplugAlert(source: state.sourceDescription, reason: reason + " External keyboard or mouse activity was detected \(Int(age.rounded()))s ago, so the Mac appears active at the desk.")
                return
            case .builtInRecent:
                return
            case .idle:
                break
            }
        }

        let idleSeconds = UserActivity.idleSeconds
        guard idleSeconds >= settings.stationaryIdleThreshold else { return }
        sendAccidentalUnplugAlert(source: state.sourceDescription, reason: reason + " Idle fallback: \(Int(idleSeconds.rounded()))s.")
    }

    private func sendAccidentalUnplugAlert(source: String, reason: String) {
        notifier.alert(
            title: "MacBook is running on battery",
            body: "Power changed to \(source). \(reason) Check the MagSafe cable."
        )
        notifier.sendWebhookIfConfigured(
            title: "MacBook unplugged",
            message: "Power changed to \(source). \(reason)"
        )
    }

    private func scheduleBatteryReminder() {
        guard settings.repeatRemindersEnabled else { return }
        reminderTimer?.invalidate()
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
                self.notifier.alert(
                    title: "Still on battery",
                    body: "The MacBook is still unplugged and motionless."
                )
                self.notifier.sendWebhookIfConfigured(
                    title: "MacBook still unplugged",
                    message: "The MacBook is still unplugged and motionless."
                )
            case .moving:
                break
            case .unavailable:
                self.sendIdleFallbackReminder()
            }
        }
    }

    private func sendIdleFallbackReminder() {
        guard settings.idleFallbackEnabled else { return }
        if settings.externalInputDeskSignalEnabled {
            switch inputMonitor.context(recentThreshold: settings.inputActivityWindow) {
            case .externalRecent:
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
                return
            case .idle:
                break
            }
        }

        guard UserActivity.idleSeconds >= settings.stationaryIdleThreshold else { return }
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

    @objc private func showStatusWindow() {
        if statusWindowController == nil {
            statusWindowController = StatusWindowController(
                settings: settings,
                testAlertHandler: { [weak self] in self?.sendTestAlert() },
                checkForUpdatesHandler: { [weak self] in self?.checkForUpdates(manual: true) },
                updateScheduleChangedHandler: { [weak self] in self?.scheduleUpdateChecks() },
                openConfigHandler: { [weak self] in self?.openConfigFile() }
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
                    self.statusWindowController?.updateUpdateStatus("Update available: \(version)")
                    self.notifier.alert(
                        title: "MagSafe Watch update available",
                        body: "Version \(version) is available. Open the release page from Advanced Config or GitHub."
                    )
                    if manual {
                        NSWorkspace.shared.open(url)
                    }
                case .current(let version):
                    self.statusWindowController?.updateUpdateStatus("Up to date: \(version)")
                    if manual {
                        self.notifier.alert(title: "MagSafe Watch is up to date", body: "You are running version \(version).")
                    }
                case .notConfigured:
                    self.statusWindowController?.updateUpdateStatus("Update feed not configured")
                    if manual {
                        self.notifier.alert(
                            title: "Update feed not configured",
                            body: "Add a GitHub latest-release API URL in Advanced Config."
                        )
                    }
                case .failed(let message):
                    self.statusWindowController?.updateUpdateStatus("Update check failed")
                    if manual {
                        self.notifier.alert(title: "Update check failed", body: message)
                    }
                }
            }
        }
    }

    @objc private func openSettings() {
        showStatusWindow()
        statusWindowController?.showSettingsPage()
    }

    private func openConfigFile() {
        NSWorkspace.shared.open(settings.configFileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class StatusWindowController: NSWindowController {
    private let settings: AppSettings
    private let testAlertHandler: () -> Void
    private let checkForUpdatesHandler: () -> Void
    private let updateScheduleChangedHandler: () -> Void
    private let openConfigHandler: () -> Void
    private let powerValue = NSTextField(labelWithString: "Checking...")
    private let idleValue = NSTextField(labelWithString: "Checking...")
    private let motionValue = NSTextField(labelWithString: "Checking...")
    private let inputValue = NSTextField(labelWithString: "Checking...")
    private let updateValue = NSTextField(labelWithString: "Not checked")
    private let pageTabs = NSSegmentedControl(labels: ["Intro", "Settings", "Notifications", "Status"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageContainer = NSView()

    init(settings: AppSettings, testAlertHandler: @escaping () -> Void, checkForUpdatesHandler: @escaping () -> Void, updateScheduleChangedHandler: @escaping () -> Void, openConfigHandler: @escaping () -> Void) {
        self.settings = settings
        self.testAlertHandler = testAlertHandler
        self.checkForUpdatesHandler = checkForUpdatesHandler
        self.updateScheduleChangedHandler = updateScheduleChangedHandler
        self.openConfigHandler = openConfigHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
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
    }

    func showSettingsPage() {
        selectPage(1)
    }

    func showStatusPage() {
        selectPage(3)
    }

    func updateUpdateStatus(_ status: String) {
        updateValue.stringValue = status
    }

    private func buildContentView() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        pageTabs.selectedSegment = 0
        pageTabs.target = self
        pageTabs.action = #selector(changePage)
        pageTabs.segmentStyle = .rounded
        pageTabs.translatesAutoresizingMaskIntoConstraints = false

        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(pageTabs)
        content.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            pageTabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            pageTabs.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            pageTabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            pageContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: pageTabs.bottomAnchor, constant: 18),
            pageContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        selectPage(0)
        return content
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
            checkbox(title: "Monitor MagSafe and power adapter changes", isOn: settings.monitorEnabled, action: #selector(toggleMonitor(_:))),
            checkbox(title: "Use motion detection when sensor events are available", isOn: settings.motionDetectionEnabled, action: #selector(toggleMotionDetection(_:))),
            checkbox(title: "Use idle-time fallback when motion data is unavailable", isOn: settings.idleFallbackEnabled, action: #selector(toggleIdleFallback(_:))),
            checkbox(title: "Treat external keyboard or mouse input as desk activity", isOn: settings.externalInputDeskSignalEnabled, action: #selector(toggleExternalInputDeskSignal(_:))),
            checkbox(title: "Repeat reminders while the Mac remains unplugged", isOn: settings.repeatRemindersEnabled, action: #selector(toggleRepeatReminders(_:))),
            checkbox(title: "Automatically check for app updates", isOn: settings.autoUpdateChecksEnabled, action: #selector(toggleAutoUpdateChecks(_:)))
        ]

        let timing = paragraph("Current timing: \(Int(settings.motionSampleWindow))s motion sample, \(Int(settings.stationaryIdleThreshold))s idle fallback, \(Int(settings.inputActivityWindow))s input window, \(Int(settings.repeatAlertInterval))s repeat reminders, \(Int(settings.updateCheckInterval / 3600))h update checks.")
        let updateFeed = paragraph(settings.updateFeedURL == nil ? "Update feed is not configured. Add a GitHub latest-release API URL in Advanced Config when the repository has releases." : "Update feed is configured.")
        let configButton = NSButton(title: "Open Advanced Config", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded

        return pageStack([title, body] + controls + [timing, updateFeed, configButton])
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
        let configButton = NSButton(title: "Open Advanced Config", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded

        return pageStack([title, body] + controls + [webhook, row([testButton, configButton])])
    }

    private func buildStatusPage() -> NSView {
        let title = heading("Status")
        let description = paragraph("You can close this window and the charger monitor will keep running from the menu bar.")

        let powerLabel = label("Power")
        let idleLabel = label("Activity")
        let motionLabel = label("Motion")
        let inputLabel = label("Input")
        let updateLabel = label("Updates")

        let grid = NSGridView(views: [
            [powerLabel, powerValue],
            [idleLabel, idleValue],
            [motionLabel, motionValue],
            [inputLabel, inputValue],
            [updateLabel, updateValue]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.xPlacement = .leading

        let updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        return pageStack([title, description, grid, row([updateButton, quitButton])])
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

    private func checkbox(title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    @objc private func sendTestAlert() {
        testAlertHandler()
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

    @objc private func toggleMonitor(_ sender: NSButton) {
        settings.monitorEnabled = sender.state == .on
        settings.save()
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

    @objc private func toggleExternalInputDeskSignal(_ sender: NSButton) {
        settings.externalInputDeskSignalEnabled = sender.state == .on
        settings.save()
    }

    @objc private func toggleAutoUpdateChecks(_ sender: NSButton) {
        settings.autoUpdateChecksEnabled = sender.state == .on
        settings.save()
        updateScheduleChangedHandler()
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
            return PowerState(isOnACPower: false, sourceDescription: "Unknown")
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

        return PowerState(isOnACPower: isAC, sourceDescription: description)
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
    case current(version: String)
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

                if latestVersion > currentVersion, let url = URL(string: release.htmlURL) {
                    completionBox.completion(.available(version: release.tagName, url: url))
                } else {
                    completionBox.completion(.current(version: currentVersion.description))
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

final class AlertNotifier {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Notification authorization failed: \(error.localizedDescription)")
            }
            if !granted {
                NSLog("Notification authorization was not granted.")
            }
        }
    }

    func alert(title: String, body: String) {
        if settings.soundEnabled {
            NSSound(named: "Basso")?.play()
        }

        guard settings.localNotificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    func sendWebhookIfConfigured(title: String, message: String) {
        guard settings.webhookNotificationsEnabled else { return }
        guard let webhookURL = settings.webhookURL else { return }

        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "message": message,
            "source": Host.current().localizedName ?? "Mac"
        ])

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                NSLog("Webhook alert failed: \(error.localizedDescription)")
            }
        }.resume()
    }
}

final class AppSettings {
    var monitorEnabled: Bool
    var motionDetectionEnabled: Bool
    var idleFallbackEnabled: Bool
    var externalInputDeskSignalEnabled: Bool
    var repeatRemindersEnabled: Bool
    var localNotificationsEnabled: Bool
    var soundEnabled: Bool
    var webhookNotificationsEnabled: Bool
    var autoUpdateChecksEnabled: Bool
    var stationaryIdleThreshold: TimeInterval
    var repeatAlertInterval: TimeInterval
    var motionSampleWindow: TimeInterval
    var inputActivityWindow: TimeInterval
    var updateCheckInterval: TimeInterval
    var movementThreshold: Double
    var webhookURL: URL?
    var updateFeedURL: URL?
    let configFileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagSafeWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        configFileURL = support.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            let defaults = """
            {
              "monitorEnabled": true,
              "motionDetectionEnabled": true,
              "idleFallbackEnabled": true,
              "externalInputDeskSignalEnabled": true,
              "repeatRemindersEnabled": true,
              "localNotificationsEnabled": true,
              "soundEnabled": true,
              "webhookNotificationsEnabled": false,
              "autoUpdateChecksEnabled": true,
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

        monitorEnabled = object["monitorEnabled"] as? Bool ?? true
        motionDetectionEnabled = object["motionDetectionEnabled"] as? Bool ?? true
        idleFallbackEnabled = object["idleFallbackEnabled"] as? Bool ?? true
        externalInputDeskSignalEnabled = object["externalInputDeskSignalEnabled"] as? Bool ?? true
        repeatRemindersEnabled = object["repeatRemindersEnabled"] as? Bool ?? true
        localNotificationsEnabled = object["localNotificationsEnabled"] as? Bool ?? true
        soundEnabled = object["soundEnabled"] as? Bool ?? true
        webhookNotificationsEnabled = object["webhookNotificationsEnabled"] as? Bool ?? false
        autoUpdateChecksEnabled = object["autoUpdateChecksEnabled"] as? Bool ?? true
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
            "monitorEnabled": monitorEnabled,
            "motionDetectionEnabled": motionDetectionEnabled,
            "idleFallbackEnabled": idleFallbackEnabled,
            "externalInputDeskSignalEnabled": externalInputDeskSignalEnabled,
            "repeatRemindersEnabled": repeatRemindersEnabled,
            "localNotificationsEnabled": localNotificationsEnabled,
            "soundEnabled": soundEnabled,
            "webhookNotificationsEnabled": webhookNotificationsEnabled,
            "autoUpdateChecksEnabled": autoUpdateChecksEnabled,
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
