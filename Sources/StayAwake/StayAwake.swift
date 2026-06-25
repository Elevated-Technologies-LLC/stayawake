import AppKit
import CryptoKit
import Darwin
import ApplicationServices
import CoreGraphics

private let appBundleIdentifier = "com.elvtech.stayawake"
private let updateManifestURL = stayAwakeUpdateManifestURL()

private struct UpdateManifest: Decodable {
    let version: String
    let notes: String?
    let assets: UpdateAssets
}

private struct UpdateAssets: Decodable {
    let macArm64: UpdateAsset

    private enum CodingKeys: String, CodingKey {
        case macArm64 = "mac_arm64"
    }
}

private struct UpdateAsset: Decodable {
    let url: String
    let sha256: String
    let size: Int?
}

private enum UtilityCommand: String {
    case checkAccessibility = "--check-accessibility"
    case checkScreenRecording = "--check-screen-recording"
}

private func handleUtilityCommandIfNeeded() {
    let arguments = Set(CommandLine.arguments.dropFirst())
    if arguments.contains(UtilityCommand.checkAccessibility.rawValue) {
        exit(AXIsProcessTrusted() ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    if arguments.contains(UtilityCommand.checkScreenRecording.rawValue) {
        exit(CGPreflightScreenCaptureAccess() ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

protocol MugButtonDelegate: AnyObject {
    func mugButtonDidToggle()
    func mugButtonDidRequestMenu(_ view: NSView)
}

final class MugButtonView: NSView {
    weak var delegate: MugButtonDelegate?
    var isAwake = false {
        didSet {
            toolTip = isAwake
                ? "StayAwake is on. Click to allow sleep."
                : "StayAwake is off. Click to keep the display awake."
            needsDisplay = true
        }
    }

    private let onColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.12, alpha: 1.0)
    private let offStrokeColor = NSColor(calibratedWhite: 0.98, alpha: 1.0)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        bounds.fill()

        let bodyRect = NSRect(x: 5, y: 7, width: 19, height: 14)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 4, yRadius: 4)
        let handle = NSBezierPath(ovalIn: NSRect(x: 21, y: 9, width: 9, height: 10))
        let saucer = NSBezierPath(ovalIn: NSRect(x: 6, y: 4, width: 20, height: 4))

        if isAwake {
            onColor.setFill()
            body.fill()
            onColor.setStroke()
            handle.lineWidth = 3
            handle.stroke()
            onColor.withAlphaComponent(0.72).setFill()
            saucer.fill()
            NSColor(calibratedRed: 0.88, green: 0.70, blue: 0.48, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 17, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            offStrokeColor.setStroke()
            body.lineWidth = 2
            body.stroke()
            handle.lineWidth = 2
            handle.stroke()
            saucer.lineWidth = 1.5
            saucer.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.mugButtonDidToggle()
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.mugButtonDidRequestMenu(self)
    }
}

final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuStateItem: NSMenuItem?
    private var statusMenuToggleItem: NSMenuItem?
    private var statusMenuVersionItem: NSMenuItem?
    private var awakeTopMenuItem: NSMenuItem?
    private var menuStatusItem: NSMenuItem?
    private var menuToggleItem: NSMenuItem?
    private var menuUpdateItem: NSMenuItem?
    private var awakeMenuUpdateItem: NSMenuItem?
    private var statusMenuUpdateItem: NSMenuItem?
    private var availableUpdateManifest: UpdateManifest?
    private var caffeinateProcess: Process?
    private var userActivityProcesses: [Int32: Process] = [:]
    private var watchdogTimer: Timer?
    private var userActivityTimer: Timer?
    private var updateTimer: Timer?
    private var isCheckingForUpdates = false
    private var isInstallingUpdate = false
    private var wantsAwake = true
    private var isTerminating = false
    private let onColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.12, alpha: 1.0)
    private let offColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    private let offStrokeColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/StayAwake.log")
    private let stateDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StayAwake")
    private lazy var caffeinatePIDURL = stateDirectoryURL
        .appendingPathComponent("caffeinate.pid")

    private var isAwake: Bool {
        caffeinateProcess?.isRunning == true
    }

    var statusSummaryTitle: String {
        isAwake ? "Status: Awake is on" : "Status: Sleep is allowed"
    }

    var toggleActionTitle: String {
        isAwake ? "Turn Off" : "Turn On"
    }

    var updateActionTitle: String {
        let updateAvailableTitle = availableUpdateManifest.map { "Update available (\($0.version))" } ?? "Check for Updates..."
        if isCheckingForUpdates {
            return "Checking for Updates..."
        }
        if isInstallingUpdate {
            return "Installing Update..."
        }
        return updateAvailableTitle
    }

    var updateActionEnabled: Bool {
        !isCheckingForUpdates && !isInstallingUpdate
    }

    var menuBarSymbolName: String {
        isAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    var versionDisplayTitle: String {
        versionMenuTitle()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        clearLegacyStatusItemPreferences()
        setupMainMenu()
        setupMenuBarIcon()
        requestRequiredPermissionsIfNeeded()
        startWatchdog()
        startUpdateChecks()
        cleanupStaleCaffeinate()
        log("launched")
        startAwake()
    }

    private func activateExistingInstanceIfNeeded() -> Bool {
        let currentPID = getpid()
        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: appBundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = otherInstances.first else { return false }

        existing.activate(options: [])
        log("another StayAwake instance is already running pid=\(existing.processIdentifier); exiting pid=\(currentPID)")
        return true
    }

    private func requestRequiredPermissionsIfNeeded() {
        let trustedAccessibility = AXIsProcessTrusted()
        log("accessibility permission check: trusted=\(trustedAccessibility)")
        if !trustedAccessibility {
            let promptResult = AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
            log("accessibility permission prompt result=\(promptResult)")
            if !promptResult {
                showInfo(
                    """
                    StayAwake needs Accessibility permission to keep the system awake reliably.
                    If you do not see the permission prompt, open:
                    System Settings > Privacy & Security > Accessibility
                    and enable StayAwake.
                    """
                )
            }
        }

        let trustedScreenRecording = CGPreflightScreenCaptureAccess()
        log("screen recording permission check: trusted=\(trustedScreenRecording)")
        if !trustedScreenRecording {
            let promptResult = CGRequestScreenCaptureAccess()
            log("screen recording permission prompt result=\(promptResult)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        updateTimer?.invalidate()
        updateTimer = nil
        stopUserActivityPulses()
        log("terminating")
        stopAwake()
    }

    @objc private func toggleAwake() {
        isAwake ? stopAwake() : startAwake()
    }

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        // Always open the status menu so the full controls are discoverable,
        // including the update action.
        showMenu()
    }

    @objc private func quitApp() {
        stopLaunchAgentForCurrentSession()
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdatesFromMenu() {
        log("update selected from menu")
        checkForUpdates(triggeredByUser: true, autoInstallWhenAvailable: true)
    }

    @objc private func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func checkOrInstallUpdateFromStatusMenu() {
        guard let manifest = availableUpdateManifest else {
            log("status menu update selected; no cached update; checking")
            checkForUpdates(triggeredByUser: true, autoInstallWhenAvailable: true)
            return
        }

        log("status menu update selected; applying version=\(manifest.version)")
        installUpdate(manifest)
    }

    func toggleFromMenuBar() {
        toggleAwake()
    }

    func checkOrInstallUpdateFromMenuBar() {
        checkOrInstallUpdateFromStatusMenu()
    }

    func showAboutFromMenuBar() {
        showAboutPanel()
    }

    func quitFromMenuBar() {
        quitApp()
    }

    private func clearLegacyStatusItemPreferences() {
        let defaults = UserDefaults.standard
        guard let domain = defaults.persistentDomain(forName: appBundleIdentifier) else {
            return
        }

        let legacyKeys = domain.keys.filter { $0.hasPrefix("NSStatusItem ") }
        guard !legacyKeys.isEmpty else {
            return
        }

        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.synchronize()
        log("cleared legacy status item preferences: \(legacyKeys.joined(separator: ", "))")
    }

    private func setupMenuBarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Avoid restoring a stale menu bar slot. Some Macs can keep a bad
        // saved position that leaves the status item hidden behind system extras.
        item.isVisible = true
        if let button = item.button {
            configureStatusButton(button)
            log("status item created; button=true length=\(item.length)")
        } else {
            log("status item created; button=false length=\(item.length)")
        }

        let menu = buildStatusMenu()
        item.menu = menu
        statusItem = item
        updateStatusTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.logStatusItemPlacement(reason: "after 1s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.logStatusItemPlacement(reason: "after 5s")
        }
    }

    private func configureStatusButton(_ button: NSStatusBarButton) {
        let icon = mugImage(on: isAwake)
        icon.size = NSSize(width: 24, height: 18)
        button.image = icon
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = isAwake ? "StayAwake is on" : "StayAwake is off"
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let statusItem = NSMenuItem(title: statusSummaryTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusMenuStateItem = statusItem
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: toggleActionTitle, action: #selector(toggleAwake), keyEquivalent: "")
        toggleItem.target = self
        statusMenuToggleItem = toggleItem
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: updateActionTitle, action: #selector(checkOrInstallUpdateFromStatusMenu), keyEquivalent: "")
        updateItem.target = self
        statusMenuUpdateItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About StayAwake", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let versionItem = NSMenuItem(title: versionMenuTitle(), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        statusMenuVersionItem = versionItem
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit StayAwake", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func logStatusItemPlacement(reason: String) {
        guard let item = statusItem else {
            log("status item placement \(reason): missing item")
            return
        }
        guard let button = item.button else {
            log("status item placement \(reason): missing button")
            return
        }

        let frame = NSStringFromRect(button.frame)
        let bounds = NSStringFromRect(button.bounds)
        let windowFrame = button.window.map { NSStringFromRect($0.frame) } ?? "nil"
        let screenFrame = button.window?.screen.map { NSStringFromRect($0.frame) } ?? "nil"
        let visibleFrame = button.window?.screen.map { NSStringFromRect($0.visibleFrame) } ?? "nil"
        log("status item placement \(reason): itemVisible=\(item.isVisible) frame=\(frame) bounds=\(bounds) windowFrame=\(windowFrame) screenFrame=\(screenFrame) visibleFrame=\(visibleFrame) title='\(button.title)' image=\(button.image != nil)")
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "StayAwake", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "StayAwake")
        let appStatus = NSMenuItem(title: "Status: Starting", action: nil, keyEquivalent: "")
        appStatus.isEnabled = false
        let appToggle = NSMenuItem(title: "Turn Off", action: #selector(toggleAwake), keyEquivalent: "")
        appToggle.target = self
        appMenu.addItem(appStatus)
        appMenu.addItem(appToggle)
        appMenu.addItem(NSMenuItem.separator())
        let appUpdate = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        appUpdate.target = self
        appMenu.addItem(appUpdate)
        appMenu.addItem(NSMenuItem.separator())
        let appAbout = NSMenuItem(title: "About StayAwake", action: #selector(showAboutPanel), keyEquivalent: "")
        appAbout.target = self
        appMenu.addItem(appAbout)
        appMenu.addItem(NSMenuItem.separator())
        let appVersion = NSMenuItem(title: versionMenuTitle(), action: nil, keyEquivalent: "")
        appVersion.isEnabled = false
        appMenu.addItem(appVersion)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit StayAwake", action: #selector(quitApp), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let awakeMenuItem = NSMenuItem(title: "Awake", action: nil, keyEquivalent: "")
        let awakeMenu = NSMenu(title: "Awake")
        let awakeStatus = NSMenuItem(title: "Awake is on", action: nil, keyEquivalent: "")
        awakeStatus.isEnabled = false
        let awakeToggle = NSMenuItem(title: "Turn Off", action: #selector(toggleAwake), keyEquivalent: "")
        awakeToggle.target = self
        awakeMenu.addItem(awakeStatus)
        awakeMenu.addItem(awakeToggle)
        awakeMenu.addItem(NSMenuItem.separator())
        let awakeUpdate = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        awakeUpdate.target = self
        awakeMenu.addItem(awakeUpdate)
        awakeMenu.addItem(NSMenuItem.separator())
        let awakeAbout = NSMenuItem(title: "About StayAwake", action: #selector(showAboutPanel), keyEquivalent: "")
        awakeAbout.target = self
        awakeMenu.addItem(awakeAbout)
        awakeMenu.addItem(NSMenuItem.separator())
        let awakeVersion = NSMenuItem(title: versionMenuTitle(), action: nil, keyEquivalent: "")
        awakeVersion.isEnabled = false
        awakeMenu.addItem(awakeVersion)
        awakeMenuItem.submenu = awakeMenu
        mainMenu.addItem(awakeMenuItem)

        NSApp.mainMenu = mainMenu
        awakeTopMenuItem = awakeMenuItem
        menuStatusItem = appStatus
        menuToggleItem = appToggle
        menuUpdateItem = appUpdate
        awakeMenuUpdateItem = awakeUpdate
        updateMenuStatus()
    }

    private func startAwake() {
        wantsAwake = true
        guard !isAwake else {
            updateStatusTitle()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-i", "-m"]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                let shouldRestart = self?.wantsAwake == true && self?.isTerminating == false
                self?.caffeinateProcess = nil
                self?.clearCaffeinatePID()
                self?.updateStatusTitle()
                self?.log("caffeinate exited; shouldRestart=\(shouldRestart)")
                if shouldRestart {
                    self?.restartAwakeAfterDelay()
                }
            }
        }

        do {
            try process.run()
            caffeinateProcess = process
            writeCaffeinatePID(process.processIdentifier)
            log("started caffeinate pid=\(process.processIdentifier)")
            startUserActivityPulses()
            updateStatusTitle()
        } catch {
            caffeinateProcess = nil
            clearCaffeinatePID()
            updateStatusTitle()
            log("failed to start caffeinate: \(error.localizedDescription)")
            showError("Could not start caffeinate: \(error.localizedDescription)")
        }
    }

    private func stopAwake() {
        wantsAwake = false
        stopUserActivityPulses()
        guard let process = caffeinateProcess else {
            updateStatusTitle()
            return
        }

        process.terminationHandler = nil
        if process.isRunning {
            log("stopping caffeinate pid=\(process.processIdentifier)")
            process.terminate()
        }
        caffeinateProcess = nil
        clearCaffeinatePID()
        updateStatusTitle()
    }

    private func startUserActivityPulses() {
        guard wantsAwake, !isTerminating else { return }
        pulseUserActivity()

        guard userActivityTimer == nil else { return }
        userActivityTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.pulseUserActivity()
        }
        log("started user-active renewal timer")
    }

    private func stopUserActivityPulses() {
        userActivityTimer?.invalidate()
        userActivityTimer = nil

        for process in userActivityProcesses.values where process.isRunning {
            process.terminate()
        }
        userActivityProcesses.removeAll()
        log("stopped user-active renewal timer")
    }

    private func pulseUserActivity() {
        guard wantsAwake, !isTerminating else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "90"]
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process = process else { return }
            DispatchQueue.main.async {
                self?.userActivityProcesses.removeValue(forKey: process.processIdentifier)
                self?.log("user-active pulse ended pid=\(process.processIdentifier)")
            }
        }

        do {
            try process.run()
            userActivityProcesses[process.processIdentifier] = process
            log("renewed user-active assertion pid=\(process.processIdentifier)")
        } catch {
            log("failed to renew user-active assertion: \(error.localizedDescription)")
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.verifyAwakeProcess()
        }
    }

    private func verifyAwakeProcess() {
        guard wantsAwake, !isTerminating else { return }
        if caffeinateProcess?.isRunning == true {
            updateStatusTitle()
            return
        }

        log("watchdog found caffeinate missing; restarting")
        caffeinateProcess = nil
        startAwake()
    }

    private func restartAwakeAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.wantsAwake, !self.isTerminating else { return }
            self.startAwake()
        }
    }

    private func cleanupStaleCaffeinate() {
        guard let rawPID = try? String(contentsOf: caffeinatePIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pidValue = Int32(rawPID),
              pidValue > 0
        else { return }

        if processCommand(pid: pidValue).contains("/usr/bin/caffeinate") {
            log("stopping stale caffeinate pid=\(pidValue)")
            Darwin.kill(pidValue, SIGTERM)
        }
        clearCaffeinatePID()
    }

    private func processCommand(pid: Int32) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func writeCaffeinatePID(_ pid: Int32) {
        do {
            try FileManager.default.createDirectory(
                at: stateDirectoryURL,
                withIntermediateDirectories: true
            )
            try "\(pid)\n".write(to: caffeinatePIDURL, atomically: true, encoding: .utf8)
        } catch {
            log("failed to write pid file: \(error.localizedDescription)")
        }
    }

    private func clearCaffeinatePID() {
        try? FileManager.default.removeItem(at: caffeinatePIDURL)
    }

    private func updateStatusTitle() {
        if let button = statusItem?.button {
            configureStatusButton(button)
        }
        updateMenuStatus()
        log("status item updated; isAwake=\(isAwake)")
    }

    private func versionMenuTitle() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    private func updateMenuStatus() {
        objectWillChange.send()

        let awake = isAwake
        awakeTopMenuItem?.title = awake ? "Awake On" : "Sleep OK"
        menuStatusItem?.title = awake ? "Status: Awake is on" : "Status: Sleep is allowed"
        menuToggleItem?.title = awake ? "Turn Off" : "Turn On"
        statusMenuStateItem?.title = awake ? "Status: Awake is on" : "Status: Sleep is allowed"
        statusMenuToggleItem?.title = awake ? "Turn Off" : "Turn On"
        statusMenuVersionItem?.title = versionMenuTitle()

        let updateAvailableTitle = availableUpdateManifest.map { "Update available (\($0.version))" } ?? "Check for Updates..."
        let canUseUpdateItems = !isCheckingForUpdates && !isInstallingUpdate
        let updateMenuTitle = isCheckingForUpdates
            ? "Checking for Updates..."
            : isInstallingUpdate
                ? "Installing Update..."
                : updateAvailableTitle

        statusMenuUpdateItem?.title = updateMenuTitle
        statusMenuUpdateItem?.isEnabled = canUseUpdateItems
        menuUpdateItem?.title = updateMenuTitle
        menuUpdateItem?.isEnabled = canUseUpdateItems
        awakeMenuUpdateItem?.title = updateMenuTitle
        awakeMenuUpdateItem?.isEnabled = canUseUpdateItems
        if let awakeMenu = awakeTopMenuItem?.submenu {
            awakeMenu.item(at: 0)?.title = awake ? "Awake is on" : "Sleep is allowed"
            awakeMenu.item(at: 1)?.title = awake ? "Turn Off" : "Turn On"
        }
    }

    private func mugImage(on: Bool) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let bodyRect = NSRect(x: 3.0, y: 3.0, width: 14.5, height: 11.5)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.2, yRadius: 3.2)

        if on {
            onColor.setFill()
            bodyPath.fill()
        } else {
            NSColor.clear.setFill()
            bodyPath.fill()
            offColor.setStroke()
            bodyPath.lineWidth = 2.2
            bodyPath.stroke()
        }

        let handlePath = NSBezierPath()
        handlePath.appendOval(in: NSRect(x: 15.0, y: 5.0, width: 6.5, height: 7.5))
        if on {
            onColor.setStroke()
            handlePath.lineWidth = 2.4
            handlePath.stroke()
        } else {
            offStrokeColor.setStroke()
            handlePath.lineWidth = 2.0
            handlePath.stroke()
        }

        let saucer = NSBezierPath(ovalIn: NSRect(x: 4.0, y: 1.0, width: 14.0, height: 2.8))
        if on {
            onColor.withAlphaComponent(0.72).setFill()
            saucer.fill()
        } else {
            offStrokeColor.withAlphaComponent(0.8).setStroke()
            saucer.lineWidth = 1.4
            saucer.stroke()
        }

        if on {
            NSColor(calibratedRed: 0.88, green: 0.70, blue: 0.48, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: NSRect(x: 5.5, y: 11.0, width: 10.0, height: 2.0), xRadius: 1.0, yRadius: 1.0).fill()
            let steamColor = NSColor(calibratedWhite: 0.98, alpha: 0.92)
            for x in [7.0, 11.0, 15.0] {
                let steam = NSBezierPath()
                steam.move(to: NSPoint(x: x, y: 15.0))
                steam.curve(
                    to: NSPoint(x: x + 1.2, y: 18.0),
                    controlPoint1: NSPoint(x: x - 1.0, y: 16.0),
                    controlPoint2: NSPoint(x: x + 1.8, y: 17.0)
                )
                steamColor.setStroke()
                steam.lineWidth = 1.2
                steam.lineCapStyle = .round
                steam.stroke()
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = on ? "StayAwake on" : "StayAwake off"
        return image
    }

    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: isAwake ? "Status: On" : "Status: Off", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "About StayAwake", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        let versionItem = NSMenuItem(title: versionMenuTitle(), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())
        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkOrInstallUpdateFromStatusMenu),
            keyEquivalent: ""
        )
        updateItem.target = self
        statusMenuUpdateItem = updateItem
        menu.addItem(updateItem)
        updateMenuStatus()
        menu.addItem(NSMenuItem.separator())
        let toggleItem = NSMenuItem(title: isAwake ? "Turn Off" : "Turn On", action: #selector(toggleAwake), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit StayAwake", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
            self?.statusMenuUpdateItem = nil
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "StayAwake"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "StayAwake"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func startUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(triggeredByUser: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkForUpdates(triggeredByUser: false)
        }
    }

    private func checkForUpdates(triggeredByUser: Bool, autoInstallWhenAvailable: Bool = false) {
        guard !isCheckingForUpdates, !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        updateMenuStatus()
        log("update check started (triggeredByUser=\(triggeredByUser), autoInstallWhenAvailable=\(autoInstallWhenAvailable))")

        URLSession.shared.dataTask(with: updateManifestURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckingForUpdates = false
                self.updateMenuStatus()

                if let error = error {
                    self.log("update check failed: \(error.localizedDescription)")
                    if triggeredByUser {
                        self.showError("Could not check for updates: \(error.localizedDescription)")
                    }
                    return
                }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.log("update check failed: HTTP \(http.statusCode)")
                    if triggeredByUser {
                        self.showError("Could not check for updates: GitHub returned HTTP \(http.statusCode).")
                    }
                    return
                }

                guard let data = data else {
                    self.log("update check failed: empty response")
                    if triggeredByUser {
                        self.showError("Could not check for updates: the update manifest was empty.")
                    }
                    return
                }

                do {
                    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                    self.handleUpdateManifest(manifest, triggeredByUser: triggeredByUser, autoInstallWhenAvailable: autoInstallWhenAvailable)
                } catch {
                    self.log("update manifest parse failed: \(error.localizedDescription)")
                    if triggeredByUser {
                        self.showError("Could not read the update manifest: \(error.localizedDescription)")
                    }
                }
            }
        }.resume()
    }

    private func handleUpdateManifest(_ manifest: UpdateManifest, triggeredByUser: Bool, autoInstallWhenAvailable: Bool) {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard compareVersions(manifest.version, currentVersion) == .orderedDescending else {
            log("no update available; current=\(currentVersion) manifest=\(manifest.version)")
            availableUpdateManifest = nil
            if triggeredByUser {
                showInfo("StayAwake is up to date. Current version: \(currentVersion).")
            }
            updateMenuStatus()
            return
        }

        log("update available current=\(currentVersion) new=\(manifest.version)")
        availableUpdateManifest = manifest
        updateMenuStatus()

        if autoInstallWhenAvailable {
            log("auto-installing update for user request; version=\(manifest.version)")
            installUpdate(manifest)
        }
    }

    private func installUpdate(_ manifest: UpdateManifest) {
        guard !isInstallingUpdate else { return }
        guard let assetURL = URL(string: manifest.assets.macArm64.url) else {
            log("update install failed: invalid asset URL")
            showError("The update manifest has an invalid download URL.")
            return
        }

        isInstallingUpdate = true
        statusMenuUpdateItem?.title = "Installing Update..."
        availableUpdateManifest = manifest
        updateMenuStatus()
        log("update download/install started version=\(manifest.version)")

        URLSession.shared.downloadTask(with: assetURL) { [weak self] downloadedURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.finishUpdateInstallWithError("Could not download update: \(error.localizedDescription)")
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.finishUpdateInstallWithError("Could not download update: GitHub returned HTTP \(http.statusCode).")
                    return
                }
                guard let downloadedURL = downloadedURL else {
                    self.finishUpdateInstallWithError("Could not download update: no file was returned.")
                    return
                }

                do {
                    let zipURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("StayAwake-\(manifest.version)-\(UUID().uuidString).zip")
                    try? FileManager.default.removeItem(at: zipURL)
                    try FileManager.default.moveItem(at: downloadedURL, to: zipURL)
                    try self.verifyUpdateZip(at: zipURL, expectedSHA256: manifest.assets.macArm64.sha256)
                    try self.launchUpdateInstaller(zipURL: zipURL, version: manifest.version)
                    self.log("update download/install success version=\(manifest.version)")
                } catch {
                    self.finishUpdateInstallWithError("Could not install update: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func finishUpdateInstallWithError(_ message: String) {
        isInstallingUpdate = false
        menuUpdateItem?.title = "Check for Updates..."
        awakeMenuUpdateItem?.title = "Check for Updates..."
        statusMenuUpdateItem?.title = "Check for Updates..."
        updateMenuStatus()
        log(message)
        showError(message)
    }

    private func verifyUpdateZip(at zipURL: URL, expectedSHA256: String) throws {
        let normalizedExpected = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedExpected.isEmpty else {
            throw NSError(domain: "StayAwake", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update manifest is missing a SHA-256 checksum."])
        }
        let data = try Data(contentsOf: zipURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == normalizedExpected else {
            throw NSError(domain: "StayAwake", code: 2, userInfo: [NSLocalizedDescriptionKey: "The update checksum did not match."])
        }
        log("verified update zip sha256=\(digest)")
    }

    private func launchUpdateInstaller(zipURL: URL, version: String) throws {
        let appURL = Bundle.main.bundleURL
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-stayawake-\(UUID().uuidString).zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail
        APP_PATH="$1"
        ZIP_PATH="$2"
        LOG_PATH="$HOME/Library/Logs/StayAwake-update.log"
        mkdir -p "$(dirname "$LOG_PATH")"
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') installing StayAwake update" >> "$LOG_PATH"
        WORK_DIR="$(mktemp -d)"
        cleanup() {
          rm -rf "$WORK_DIR"
        }
        trap cleanup EXIT
        /usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR"
        NEW_APP="$WORK_DIR/StayAwake.app"
        if [ ! -d "$NEW_APP" ]; then
          echo "StayAwake.app not found in update ZIP" >> "$LOG_PATH"
          exit 1
        fi
        for _ in {1..30}; do
          if ! /usr/bin/pgrep -f "$APP_PATH/Contents/MacOS/StayAwake" >/dev/null 2>&1; then
            break
          fi
          /bin/sleep 1
        done
        /bin/rm -rf "$APP_PATH"
        /usr/bin/ditto "$NEW_APP" "$APP_PATH"
        /usr/bin/xattr -cr "$APP_PATH" >/dev/null 2>&1 || true
        /usr/bin/open "$APP_PATH"
        /bin/rm -f "$ZIP_PATH" "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, appURL.path, zipURL.path]
        try process.run()
        log("update download/install success; launched updater for version \(version)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging must never interfere with keeping the Mac awake.
        }
    }

    private func stopLaunchAgentForCurrentSession() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.elvtech.stayawake.plist")
        let domain = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", domain, plist.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            log("requested launch agent bootout before quit status=\(process.terminationStatus)")
        } catch {
            log("launch agent bootout before quit failed: \(error.localizedDescription)")
        }
    }
}

@main
private enum StayAwakeApp {
    private static var delegate: AppDelegate?

    static func main() {
        handleUtilityCommandIfNeeded()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        Self.delegate = delegate
        app.run()
    }
}
