import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.ps
import UserNotifications

@main
@MainActor
final class MagSafeSentryApp: NSObject, NSApplicationDelegate {
    private let monitor = PowerMonitor()
    private let motionClassifier = MotionClassifier()
    private let notifier = AlertNotifier()
    private let settings = AppSettings()
    private var statusItem: NSStatusItem!
    private var statusWindowController: StatusWindowController?
    private var reminderTimer: Timer?
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "MagSafe Sentry")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "MagSafe Sentry", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Status Window", action: #selector(showStatusWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Send Test Alert", action: #selector(sendTestAlert), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func handlePowerState(_ state: PowerState) {
        latestState = state
        updateStatusIcon(for: state)
        statusWindowController?.update(state: state, idleSeconds: UserActivity.idleSeconds, motionStatus: motionClassifier.statusDescription)

        if state.isOnACPower {
            motionCheckID = UUID()
            reminderTimer?.invalidate()
            reminderTimer = nil
            return
        }

        classifyDisconnect(state: state)
    }

    private func updateStatusIcon(for state: PowerState) {
        let name = state.isOnACPower ? "bolt.circle" : "battery.50percent"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: state.sourceDescription)
    }

    private func classifyDisconnect(state: PowerState) {
        let checkID = UUID()
        motionCheckID = checkID
        statusWindowController?.update(state: state, idleSeconds: UserActivity.idleSeconds, motionStatus: "Sampling motion...")

        motionClassifier.classify(
            sampleDuration: settings.motionSampleWindow,
            movementThreshold: settings.movementThreshold
        ) { [weak self] result in
            guard let self, self.motionCheckID == checkID, !self.latestState.isOnACPower else { return }
            self.statusWindowController?.update(
                state: self.latestState,
                idleSeconds: UserActivity.idleSeconds,
                motionStatus: result.statusDescription
            )

            switch result {
            case .stationary:
                self.sendAccidentalUnplugAlert(source: state.sourceDescription, reason: result.alertReason)
                self.scheduleBatteryReminder()
            case .moving:
                self.scheduleBatteryReminder()
            case .unavailable:
                let idleSeconds = UserActivity.idleSeconds
                guard idleSeconds >= self.settings.stationaryIdleThreshold else {
                    self.scheduleBatteryReminder()
                    return
                }
                self.sendAccidentalUnplugAlert(source: state.sourceDescription, reason: result.alertReason + " Idle fallback: \(Int(idleSeconds.rounded()))s.")
                self.scheduleBatteryReminder()
            }
        }
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
        motionClassifier.classify(
            sampleDuration: settings.motionSampleWindow,
            movementThreshold: settings.movementThreshold
        ) { [weak self] result in
            guard let self, !self.latestState.isOnACPower else { return }
            self.statusWindowController?.update(
                state: self.latestState,
                idleSeconds: UserActivity.idleSeconds,
                motionStatus: result.statusDescription
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
                guard UserActivity.idleSeconds >= self.settings.stationaryIdleThreshold else { return }
                self.notifier.alert(
                    title: "Still on battery",
                    body: "Motion sensor is unavailable and the Mac has been idle."
                )
                self.notifier.sendWebhookIfConfigured(
                    title: "MacBook still unplugged",
                    message: "Motion sensor is unavailable and the Mac has been idle."
                )
            }
        }
    }

    @objc private func sendTestAlert() {
        notifier.alert(title: "MagSafe Sentry test", body: "Alerts are working on this Mac.")
    }

    @objc private func showStatusWindow() {
        if statusWindowController == nil {
            statusWindowController = StatusWindowController(
                settings: settings,
                testAlertHandler: { [weak self] in self?.sendTestAlert() },
                openSettingsHandler: { [weak self] in self?.openSettings() }
            )
        }

        statusWindowController?.update(state: latestState, idleSeconds: UserActivity.idleSeconds, motionStatus: motionClassifier.statusDescription)
        statusWindowController?.showWindow(nil)
        statusWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(settings.configFileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class StatusWindowController: NSWindowController {
    private let settings: AppSettings
    private let testAlertHandler: () -> Void
    private let openSettingsHandler: () -> Void
    private let powerValue = NSTextField(labelWithString: "Checking...")
    private let idleValue = NSTextField(labelWithString: "Checking...")
    private let motionValue = NSTextField(labelWithString: "Checking...")

    init(settings: AppSettings, testAlertHandler: @escaping () -> Void, openSettingsHandler: @escaping () -> Void) {
        self.settings = settings
        self.testAlertHandler = testAlertHandler
        self.openSettingsHandler = openSettingsHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MagSafe Sentry"
        window.center()
        super.init(window: window)
        window.contentView = buildContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: PowerState, idleSeconds: TimeInterval, motionStatus: String) {
        powerValue.stringValue = state.isOnACPower ? "Power Adapter" : "Battery"
        idleValue.stringValue = "\(Int(idleSeconds.rounded()))s idle"
        motionValue.stringValue = motionStatus
    }

    private func buildContentView() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "MagSafe Sentry is running")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let description = NSTextField(wrappingLabelWithString: "You can close this window and the charger monitor will keep running from the menu bar.")
        description.textColor = .secondaryLabelColor

        let powerLabel = NSTextField(labelWithString: "Power")
        powerLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let idleLabel = NSTextField(labelWithString: "Activity")
        idleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let motionLabel = NSTextField(labelWithString: "Motion")
        motionLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let threshold = NSTextField(wrappingLabelWithString: "Accidental-unplug alerts fire when power disconnects and the Mac stays physically still for \(Int(settings.motionSampleWindow))s. If motion data is unavailable, the app falls back to \(Int(settings.stationaryIdleThreshold))s idle detection.")
        threshold.textColor = .secondaryLabelColor

        let testButton = NSButton(title: "Send Test Alert", target: self, action: #selector(sendTestAlert))
        testButton.bezelStyle = .rounded

        let settingsButton = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [powerLabel, powerValue],
            [idleLabel, idleValue],
            [motionLabel, motionValue]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.xPlacement = .leading

        let buttons = NSStackView(views: [testButton, settingsButton, quitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [title, description, grid, threshold, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            threshold.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return content
    }

    @objc private func sendTestAlert() {
        testAlertHandler()
    }

    @objc private func openSettings() {
        openSettingsHandler()
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

final class AlertNotifier {
    private let settings = AppSettings()

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
        NSSound(named: "Basso")?.play()

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
    let stationaryIdleThreshold: TimeInterval
    let repeatAlertInterval: TimeInterval
    let motionSampleWindow: TimeInterval
    let movementThreshold: Double
    let webhookURL: URL?
    let configFileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagSafeSentry", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        configFileURL = support.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            let defaults = """
            {
              "stationaryIdleThresholdSeconds": 90,
              "motionSampleWindowSeconds": 10,
              "movementThresholdG": 0.08,
              "repeatAlertIntervalSeconds": 300,
              "webhookURL": ""
            }
            """
            try? defaults.write(to: configFileURL, atomically: true, encoding: .utf8)
        }

        let data = (try? Data(contentsOf: configFileURL)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        stationaryIdleThreshold = object["stationaryIdleThresholdSeconds"] as? TimeInterval ?? 90
        motionSampleWindow = object["motionSampleWindowSeconds"] as? TimeInterval ?? 10
        movementThreshold = object["movementThresholdG"] as? Double ?? 0.08
        repeatAlertInterval = object["repeatAlertIntervalSeconds"] as? TimeInterval ?? 300

        if let rawURL = object["webhookURL"] as? String, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webhookURL = URL(string: rawURL)
        } else {
            webhookURL = nil
        }
    }
}
