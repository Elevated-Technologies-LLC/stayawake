import AppKit
import CryptoKit
import Darwin
import Foundation

private let manifestURL = stayAwakeUpdateManifestURL()
private let installerName = "Install StayAwake"
private let appName = "StayAwake"
private let launchAgentLabel = "com.elvtech.stayawake"

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

private enum PermissionKind: Equatable {
    case screenRecording
    case accessibility

    var displayName: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility"
        }
    }

    var settingsURL: String {
        switch self {
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }

    var checkArgument: String {
        switch self {
        case .screenRecording:
            return "--check-screen-recording"
        case .accessibility:
            return "--check-accessibility"
        }
    }
}

private enum InstallerError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

@main
private enum InstallerMain {
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Ready to install StayAwake")
    private let detailLabel = NSTextField(labelWithString: "The installer installs StayAwake into Applications and walks through the needed Mac permissions.")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let installButton = NSButton(title: "Install StayAwake", target: nil, action: nil)
    private let screenButton = NSButton(title: "Open Screen Recording", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Open Accessibility", target: nil, action: nil)
    private let launchButton = NSButton(title: "Open StayAwake", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private var stepLabels: [NSTextField] = []
    private var permissionPollTimer: Timer?
    private var activePermissionWait: PermissionKind?

    private var installDirectoryURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["STAYAWAKE_INSTALL_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    private var appURL: URL {
        installDirectoryURL.appendingPathComponent("\(appName).app", isDirectory: true)
    }

    private var appPath: String {
        appURL.path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        appendLog("Installer ready.")
        appendLog("Install destination: \(appPath)")
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About \(installerName)", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(installerName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        for item in appMenu.items {
            item.target = self
        }
    }

    private func buildWindow() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = installerName
        window.contentView = content
        window.isReleasedWhenClosed = false

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1.0).cgColor
        iconView.layer?.cornerRadius = 20
        content.addSubview(iconView)

        let title = NSTextField(labelWithString: installerName)
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let owner = NSTextField(labelWithString: "Owned by Elevated Technologies LLC")
        owner.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        owner.textColor = .secondaryLabelColor
        owner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(owner)

        statusLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(detailLabel)

        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isIndeterminate = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(progress)

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.spacing = 8
        steps.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(steps)

        for text in [
            "Download latest StayAwake release",
            "Verify GitHub checksum",
            "Install app and menu item",
            "Grant Screen Recording and Accessibility",
            "Open StayAwake"
        ] {
            let label = NSTextField(labelWithString: "[ ] \(text)")
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            stepLabels.append(label)
            steps.addArrangedSubview(label)
        }

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.string = ""
        scroll.documentView = logView
        content.addSubview(scroll)

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonStack)

        for button in [installButton, screenButton, accessibilityButton, launchButton, quitButton] {
            button.bezelStyle = .rounded
            button.target = self
            buttonStack.addArrangedSubview(button)
        }
        installButton.action = #selector(startInstall)
        screenButton.action = #selector(openScreenRecording)
        accessibilityButton.action = #selector(openAccessibility)
        launchButton.action = #selector(openStayAwake)
        quitButton.action = #selector(quit)
        screenButton.isEnabled = false
        accessibilityButton.isEnabled = false
        launchButton.isEnabled = false
        screenButton.isHidden = true
        accessibilityButton.isHidden = true
        launchButton.isHidden = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 180),
            iconView.heightAnchor.constraint(equalToConstant: 96),

            title.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            owner.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            owner.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            owner.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            statusLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 22),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),

            detailLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            detailLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            progress.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            progress.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 18),
            progress.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),

            steps.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            steps.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 18),
            steps.widthAnchor.constraint(equalToConstant: 340),

            scroll.leadingAnchor.constraint(equalTo: steps.trailingAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: steps.topAnchor),
            scroll.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 210),

            buttonStack.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startInstall() {
        installButton.isEnabled = false
        screenButton.isEnabled = false
        accessibilityButton.isEnabled = false
        launchButton.isEnabled = false
        screenButton.isHidden = true
        accessibilityButton.isHidden = true
        launchButton.isHidden = true

        Task {
            await install()
        }
    }

    private func install() async {
        do {
            try await setStatus("Loading release information", detail: "Reading the StayAwake release manifest.", progress: 0.08, step: 0)
            let manifest = try await loadManifest()
            appendLog("Latest StayAwake version: \(manifest.version)")

            try await setStatus("Preparing StayAwake \(manifest.version)", detail: "Loading the signed macOS app package.", progress: 0.24, step: 0)
            let zipData = try await loadAppZip(for: manifest)
            appendLog("Loaded app package: \(zipData.count) bytes.")

            try await setStatus("Verifying download", detail: "Checking the SHA-256 checksum from the release manifest.", progress: 0.42, step: 1)
            let actual = sha256Hex(zipData)
            guard actual.lowercased() == manifest.assets.macArm64.sha256.lowercased() else {
                throw InstallerError.message("Checksum mismatch. Expected \(manifest.assets.macArm64.sha256), got \(actual).")
            }
            appendLog("Checksum verified.")

            try await setStatus("Installing StayAwake", detail: "Replacing any existing app and setting up the menu item.", progress: 0.60, step: 2)
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stayawake-installer-\(UUID().uuidString)", isDirectory: true)
            let zip = temp.appendingPathComponent("StayAwake-mac-arm64.zip")
            let extract = temp.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
            try zipData.write(to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])
            let sourceApp = extract.appendingPathComponent("StayAwake.app")
            guard FileManager.default.fileExists(atPath: sourceApp.appendingPathComponent("Contents/MacOS/StayAwake").path) else {
                throw InstallerError.message("The downloaded package did not contain StayAwake.app.")
            }

            try stopOldStayAwake()
            try installApp(from: sourceApp)
            try writeLaunchAgent()
            try run("/usr/bin/open", ["-gj", appPath])
            try? FileManager.default.removeItem(at: temp)

            try await setStatus("StayAwake is installed", detail: "StayAwake is open so macOS can show it in Privacy settings.", progress: 0.82, step: 3)
            await MainActor.run {
                beginPermissionWorkflow()
            }
            appendLog("Installed \(appPath).")
            appendLog("Next: the installer will guide each required Privacy permission one at a time.")
        } catch {
            await MainActor.run {
                statusLabel.stringValue = "Install failed"
                detailLabel.stringValue = "\(error)"
                progress.doubleValue = 0
                installButton.isEnabled = true
            }
            appendLog("ERROR: \(error)")
        }
    }

    private func loadManifest() async throws -> UpdateManifest {
        if let localURL = Bundle.main.url(forResource: "stayawake-manifest", withExtension: "json") {
            appendLog("Using bundled StayAwake release manifest.")
            let data = try Data(contentsOf: localURL)
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        }

        appendLog("Downloading StayAwake release manifest.")
        let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
        return try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
    }

    private func loadAppZip(for manifest: UpdateManifest) async throws -> Data {
        if let localURL = Bundle.main.url(forResource: "StayAwake-mac-arm64", withExtension: "zip") {
            appendLog("Using bundled StayAwake app package.")
            return try Data(contentsOf: localURL)
        }

        guard let zipURL = URL(string: manifest.assets.macArm64.url) else {
            throw InstallerError.message("Release ZIP URL is invalid.")
        }

        appendLog("Downloading StayAwake app package.")
        let (zipData, _) = try await URLSession.shared.data(from: zipURL)
        return zipData
    }

    private func setStatus(_ status: String, detail: String, progress value: Double, step: Int) async throws {
        await MainActor.run {
            statusLabel.stringValue = status
            detailLabel.stringValue = detail
            progress.doubleValue = value
            markStep(step, state: "active")
            for index in 0..<step {
                markStep(index, state: "done")
            }
        }
        appendLog(status)
    }

    private func markStep(_ index: Int, state: String) {
        guard stepLabels.indices.contains(index) else { return }
        let raw = stepLabels[index].stringValue
            .replacingOccurrences(of: "[ ] ", with: "")
            .replacingOccurrences(of: "[*] ", with: "")
            .replacingOccurrences(of: "[x] ", with: "")
        switch state {
        case "done":
            stepLabels[index].stringValue = "[x] \(raw)"
            stepLabels[index].textColor = NSColor.systemGreen
        case "active":
            stepLabels[index].stringValue = "[*] \(raw)"
            stepLabels[index].textColor = NSColor.labelColor
        default:
            stepLabels[index].stringValue = "[ ] \(raw)"
            stepLabels[index].textColor = NSColor.secondaryLabelColor
        }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let text = "[\(formatter.string(from: Date()))] \(line)\n"
            self.logView.string += text
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func stopOldStayAwake() throws {
        let domain = "gui/\(getuid())"
        let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
            .path
        _ = try? run("/bin/launchctl", ["bootout", domain, launchAgentPath])
        _ = try? run("/bin/launchctl", ["disable", "\(domain)/\(launchAgentLabel)"])
        _ = try? run("/usr/bin/pkill", ["-x", appName])
    }

    private func installApp(from source: URL) throws {
        let destination = appURL
        let backup = URL(fileURLWithPath: "\(appPath).before-\(timestamp())")
        do {
            try FileManager.default.createDirectory(at: installDirectoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
            }
            try run("/usr/bin/ditto", [source.path, destination.path])
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        } catch {
            appendLog("Standard install needs administrator approval.")
            try installAppWithPrivileges(from: source.path)
        }
    }

    private func installAppWithPrivileges(from sourcePath: String) throws {
        let command = """
        set -e; \
        install_dir=\(shellQuote(installDirectoryURL.path)); \
        mkdir -p "$install_dir"; \
        app="$install_dir/\(appName).app"; \
        if [ -e "$app" ]; then mv "$app" "$app.before-$(date +%Y%m%d%H%M%S)"; fi; \
        /usr/bin/ditto \(shellQuote(sourcePath)) "$app"; \
        /usr/bin/xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
        """
        let osa = "do shell script \(appleScriptString(command)) with administrator privileges"
        try run("/usr/bin/osascript", ["-e", osa])
    }

    private func writeLaunchAgent() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logDir = home.appendingPathComponent("Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plistPath = launchAgentDir.appendingPathComponent("\(launchAgentLabel).plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-gj</string>
            <string>\(appPath)</string>
          </array>
          <key>AssociatedBundleIdentifiers</key>
          <array>
            <string>com.elvtech.stayawake</string>
          </array>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <false/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>StandardOutPath</key>
          <string>\(logDir.appendingPathComponent("StayAwake.launchd.log").path)</string>
          <key>StandardErrorPath</key>
          <string>\(logDir.appendingPathComponent("StayAwake.launchd.err").path)</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistPath, atomically: true, encoding: .utf8)
        try run("/usr/bin/plutil", ["-lint", plistPath.path])
        let domain = "gui/\(getuid())"
        _ = try? run("/bin/launchctl", ["bootout", domain, plistPath.path])
        _ = try? run("/bin/launchctl", ["enable", "\(domain)/\(launchAgentLabel)"])
        _ = try? run("/bin/launchctl", ["bootstrap", domain, plistPath.path])
        _ = try? run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(launchAgentLabel)"])
    }

    @objc private func openScreenRecording() {
        _ = try? run("/usr/bin/open", ["-gj", appPath])
        startPermissionWait(.screenRecording)
    }

    @objc private func openAccessibility() {
        _ = try? run("/usr/bin/open", ["-gj", appPath])
        startPermissionWait(.accessibility)
    }

    private func beginPermissionWorkflow() {
        let screenGranted = permissionIsGranted(.screenRecording)
        let accessibilityGranted = permissionIsGranted(.accessibility)
        continuePermissionWorkflow(screenGranted: screenGranted, accessibilityGranted: accessibilityGranted)
    }

    private func continuePermissionWorkflow(screenGranted: Bool, accessibilityGranted: Bool) {
        if !screenGranted {
            showPermissionStep(.screenRecording)
            return
        }
        if !accessibilityGranted {
            showPermissionStep(.accessibility)
            return
        }

        appendLog("All required permissions are granted.")
        openStayAwake()
    }

    private func showPermissionStep(_ kind: PermissionKind) {
        permissionPollTimer?.invalidate()
        activePermissionWait = kind
        screenButton.isHidden = kind != .screenRecording
        accessibilityButton.isHidden = kind != .accessibility
        launchButton.isHidden = true
        screenButton.isEnabled = kind == .screenRecording
        accessibilityButton.isEnabled = kind == .accessibility
        launchButton.isEnabled = false
        statusLabel.stringValue = "Grant \(kind.displayName)"
        detailLabel.stringValue = "Click the \(kind.displayName) button, turn StayAwake on in System Settings, and the installer will continue automatically."
        markStep(3, state: "active")
        schedulePermissionPolling(kind)
    }

    private func startPermissionWait(_ kind: PermissionKind) {
        permissionPollTimer?.invalidate()
        activePermissionWait = kind
        statusLabel.stringValue = "Waiting for \(kind.displayName)"
        detailLabel.stringValue = "Toggle StayAwake on in System Settings. This installer is paused and will not trigger repeated Apple permission prompts."
        appendLog("Opening \(kind.displayName) settings. Toggle StayAwake on; installer is waiting quietly.")
        openSettingsPane(kind.settingsURL)
        progress.doubleValue = max(progress.doubleValue, 0.90)
        markStep(3, state: "active")
        schedulePermissionPolling(kind)
    }

    private func schedulePermissionPolling(_ kind: PermissionKind) {
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.pollPermission(kind)
        }
        timer.tolerance = 1
        permissionPollTimer = timer
        pollPermission(kind)
    }

    private func pollPermission(_ kind: PermissionKind) {
        DispatchQueue.global(qos: .utility).async {
            let granted = self.permissionIsGranted(kind)
            let screenGranted = self.permissionIsGranted(.screenRecording)
            let accessibilityGranted = self.permissionIsGranted(.accessibility)
            DispatchQueue.main.async {
                guard self.activePermissionWait == kind else {
                    return
                }
                if granted {
                    self.appendLog("\(kind.displayName) is granted.")
                    self.permissionPollTimer?.invalidate()
                    self.permissionPollTimer = nil
                    self.activePermissionWait = nil
                    self.continuePermissionWorkflow(screenGranted: screenGranted, accessibilityGranted: accessibilityGranted)
                }
            }
        }
    }

    private func permissionIsGranted(_ kind: PermissionKind) -> Bool {
        let executable = appURL.appendingPathComponent("Contents/MacOS/StayAwake").path
        guard FileManager.default.fileExists(atPath: executable) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [kind.checkArgument]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func openStayAwake() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        activePermissionWait = nil
        appendLog("Opening StayAwake.")
        _ = try? run("/usr/bin/open", [appPath])
        progress.doubleValue = 1
        markStep(3, state: "done")
        markStep(4, state: "done")
        screenButton.isHidden = true
        accessibilityButton.isHidden = true
        launchButton.isHidden = false
        launchButton.isEnabled = true
        statusLabel.stringValue = "StayAwake is ready"
        detailLabel.stringValue = "Use the menu bar item to keep the Mac awake and check for updates."
    }

    private func openSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let alert = NSAlert()
        alert.messageText = installerName
        alert.informativeText = "Version \(version)\nOwned by Elevated Technologies LLC."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        permissionPollTimer?.invalidate()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        var combined = Data()
        combined.append(data)
        combined.append(errorData)
        let text = String(data: combined, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw InstallerError.message(text.isEmpty ? "\(executable) failed with code \(process.terminationStatus)" : text)
        }
        return text
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}
