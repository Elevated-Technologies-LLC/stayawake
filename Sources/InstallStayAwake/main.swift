import AppKit
import CryptoKit
import Darwin
import Foundation

private let manifestURL = stayAwakeUpdateManifestURL()
private let installerName = "Install StayAwake"
private let appName = "StayAwake"
private let launchAgentLabel = "com.elvtech.stayawake"

private func installerVersionText() -> String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    if build.isEmpty || build == version {
        return "Installer version \(version)"
    }
    return "Installer version \(version) (\(build))"
}

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
    private let detailLabel = NSTextField(labelWithString: "The installer installs StayAwake into Applications and opens the menu bar app.")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let versionLabel = NSTextField(labelWithString: installerVersionText())
    private let installButton = NSButton(title: "Install StayAwake", target: nil, action: nil)
    private let screenButton = NSButton(title: "Open Menu Bar Settings", target: nil, action: nil)
    private let launchButton = NSButton(title: "Open StayAwake", target: nil, action: nil)
    private let rollbackButton = NSButton(title: "Rollback Install", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private var stepLabels: [NSTextField] = []

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

        versionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(versionLabel)

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
            "Install app",
            "Open StayAwake",
            "Enable menu bar item if needed"
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

        for button in [installButton, screenButton, launchButton, rollbackButton, quitButton] {
            button.bezelStyle = .rounded
            button.target = self
            buttonStack.addArrangedSubview(button)
        }
        installButton.action = #selector(startInstall)
        screenButton.action = #selector(openMenuBarSettings)
        launchButton.action = #selector(openStayAwake)
        rollbackButton.action = #selector(rollbackInstall)
        quitButton.action = #selector(quit)
        screenButton.isEnabled = false
        launchButton.isEnabled = false
        rollbackButton.isEnabled = false
        screenButton.isHidden = true
        launchButton.isHidden = true
        rollbackButton.isHidden = true

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

            versionLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            versionLabel.topAnchor.constraint(equalTo: owner.bottomAnchor, constant: 4),
            versionLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),

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
        launchButton.isEnabled = false
        screenButton.isHidden = true
        launchButton.isHidden = true
        rollbackButton.isHidden = false
        rollbackButton.isEnabled = true

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

            try await setStatus("Installing StayAwake", detail: "Replacing any existing app and preparing the menu bar item.", progress: 0.60, step: 2)
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
            try registerInstalledApp()
            try removeLaunchAgent()
            try? FileManager.default.removeItem(at: temp)

            try await setStatus("Opening StayAwake", detail: "StayAwake does not require Screen Recording or Accessibility. Opening the menu bar app now.", progress: 0.84, step: 3)
            await MainActor.run {
                rollbackButton.isHidden = false
                rollbackButton.isEnabled = true
                openStayAwake()
            }
            appendLog("Installed \(appPath).")
            appendLog("StayAwake uses caffeinate and does not require Accessibility or Screen Recording permissions.")
        } catch {
            await MainActor.run {
                statusLabel.stringValue = "Install failed"
                detailLabel.stringValue = "\(error)"
                progress.doubleValue = 0
                installButton.isEnabled = true
                rollbackButton.isHidden = false
                rollbackButton.isEnabled = true
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

    private func registerInstalledApp() throws {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.fileExists(atPath: lsregister) {
            _ = try? run(lsregister, ["-f", appPath])
        }
        _ = try? run("/usr/bin/mdimport", [appPath])
        appendLog("Registered installed StayAwake app with macOS services.")
    }

    @objc private func rollbackInstall() {
        rollbackButton.isEnabled = false
        Task {
            await rollbackInstalledApp()
        }
    }

    private func rollbackInstalledApp() async {
        await MainActor.run {
            statusLabel.stringValue = "Rolling back StayAwake"
            detailLabel.stringValue = "Stopping the menu item and restoring the previous app if a backup exists."
            progress.doubleValue = 0.20
            appendLog("Rollback started.")
        }

        do {
            try stopOldStayAwake()
            try removeLaunchAgent()
            let result = try rollbackAppBundle()
            resetTCCPermissions()
            await MainActor.run {
                screenButton.isHidden = true
                launchButton.isHidden = true
                installButton.isEnabled = true
                rollbackButton.isEnabled = true
                statusLabel.stringValue = "Rollback finished"
                detailLabel.stringValue = "\(result) StayAwake privacy permission records were reset."
                progress.doubleValue = 0
                appendLog(result)
            }
        } catch {
            await MainActor.run {
                rollbackButton.isEnabled = true
                statusLabel.stringValue = "Rollback failed"
                detailLabel.stringValue = "\(error)"
                appendLog("Rollback failed: \(error)")
            }
        }
    }

    private func removeLaunchAgent() throws {
        let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
        if FileManager.default.fileExists(atPath: launchAgentPath.path) {
            try FileManager.default.removeItem(at: launchAgentPath)
        }
    }

    private func latestBackupURL() -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: installDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let backups = contents.filter { $0.lastPathComponent.hasPrefix("\(appName).app.before-") }
        return backups.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }.first
    }

    private func rollbackAppBundle() throws -> String {
        let backup = latestBackupURL()
        do {
            if FileManager.default.fileExists(atPath: appURL.path) {
                try FileManager.default.removeItem(at: appURL)
            }
            if let backup {
                try FileManager.default.moveItem(at: backup, to: appURL)
                _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
                return "Restored previous StayAwake from \(backup.lastPathComponent)."
            }
            return "Removed the installed StayAwake app. No previous backup was found."
        } catch {
            try rollbackAppBundleWithPrivileges(backup: backup)
            if let backup {
                return "Restored previous StayAwake from \(backup.lastPathComponent)."
            }
            return "Removed the installed StayAwake app. No previous backup was found."
        }
    }

    private func rollbackAppBundleWithPrivileges(backup: URL?) throws {
        var command = """
        set -e
        app=\(shellQuote(appPath))
        rm -rf "$app"
        """
        if let backup {
            command += """
            mv \(shellQuote(backup.path)) "$app"
            /usr/bin/xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
            """
        }
        let osa = "do shell script \(appleScriptString(command)) with administrator privileges"
        try run("/usr/bin/osascript", ["-e", osa])
    }

    private func resetTCCPermissions() {
        let bundleIdentifiers = [
            "com.elvtech.stayawake",
            "com.elvtech.stayawake.installer"
        ]
        for service in ["Accessibility", "ScreenCapture"] {
            for bundleIdentifier in bundleIdentifiers {
                do {
                    _ = try run("/usr/bin/tccutil", ["reset", service, bundleIdentifier])
                    appendLog("Reset \(service) TCC record for \(bundleIdentifier).")
                } catch {
                    appendLog("No \(service) TCC record reset for \(bundleIdentifier): \(error)")
                }
            }
        }
    }

    @objc private func openStayAwake() {
        appendLog("Opening StayAwake.")
        _ = try? run("/usr/bin/open", ["-g", appPath, "--args", "--enable-login-item"])
        progress.doubleValue = 0.94
        markStep(3, state: "done")
        markStep(4, state: "active")
        screenButton.isHidden = true
        launchButton.isHidden = false
        launchButton.isEnabled = true
        screenButton.title = "Open Menu Bar Settings"
        screenButton.isHidden = false
        screenButton.isEnabled = true
        statusLabel.stringValue = "Opening StayAwake"
        detailLabel.stringValue = "The installer is checking that StayAwake stayed open. If the cup is hidden, use Open Menu Bar Settings."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.verifyStayAwakeOpened()
        }
    }

    private func verifyStayAwakeOpened() {
        if stayAwakeIsRunning() {
            appendLog("StayAwake is running after open.")
            statusLabel.stringValue = "StayAwake is open"
            detailLabel.stringValue = "If the coffee cup is not visible, click Open Menu Bar Settings and enable StayAwake."
            progress.doubleValue = 1
        } else {
            appendLog("StayAwake did not stay running after open.")
            statusLabel.stringValue = "StayAwake did not stay open"
            detailLabel.stringValue = "Click Open StayAwake again. If it still does not appear, use Rollback Install and reinstall."
            markStep(3, state: "active")
        }
    }

    private func stayAwakeIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.elvtech.stayawake"
        }
    }

    private func openSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension?MenuBar") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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
