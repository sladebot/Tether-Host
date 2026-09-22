import AppKit
import Darwin
import WebKit

private enum SetupStep: Int, CaseIterable {
    case internet, tailscale, hermesInstall, hermesConfigure, computerUse, verify

    var title: String {
        switch self {
        case .internet: "Check Internet"
        case .tailscale: "Connect Tailscale"
        case .hermesInstall: "Install Hermes"
        case .hermesConfigure: "Set up Hermes"
        case .computerUse: "Enable computer use"
        case .verify: "Verify connection"
        }
    }

    var description: String {
        switch self {
        case .internet:
            "Check Internet from this VM and keep it awake. If DNS is broken, the guide offers a specific repair."
        case .tailscale:
            "Install Tailscale only if it is missing. Sign in inside this VM; an existing connected installation is reused."
        case .hermesInstall:
            "Install the pinned Hermes runtime and API support. Existing Hermes data is preserved."
        case .hermesConfigure:
            "Sign in to a model and start the authenticated Hermes gateway inside this VM."
        case .computerUse:
            "Install Hermes computer use in this VM, grant its macOS permissions, and check that it is ready."
        case .verify:
            "Check private HTTPS, authentication, computer use, and a real model response before connecting your phone."
        }
    }

    var guidance: String {
        switch self {
        case .internet:
            "Use the console below for any DNS or administrator prompt. This check runs entirely from this guide."
        case .tailscale:
            "If macOS Installer or a sign-in page opens, complete it inside this VM. Return here and press Return in the console when asked."
        case .hermesInstall:
            "The console shows installation output. An optional Chromium download can be quiet for up to 10 minutes; existing Hermes data is preserved."
        case .hermesConfigure:
            "Hermes may open a browser for model sign-in. Complete that sign-in inside this VM."
        case .computerUse:
            "The guide opens this VM’s System Settings when needed. Grant Accessibility and Screen Recording to the app named by the doctor check, then return here."
        case .verify:
            "A successful check creates a private connection file in this VM. Keep its token private when adding your phone."
        }
    }

    var action: String {
        switch self {
        case .internet: "Check guest Internet"
        case .tailscale: "Set up Tailscale"
        case .hermesInstall: "Install Hermes"
        case .hermesConfigure: "Configure Hermes"
        case .computerUse: "Install computer use"
        case .verify: "Verify Tether connection"
        }
    }

    var command: String {
        switch self {
        case .internet: "01 Check Internet.command"
        case .tailscale: "02 Set up Tailscale.command"
        case .hermesInstall: "03 Install Hermes.command"
        case .hermesConfigure: "04 Configure Hermes.command"
        case .computerUse: "05 Enable Computer Use.command"
        case .verify: "06 Verify Connection.command"
        }
    }

    var scriptAction: String {
        switch self {
        case .internet: "internet"
        case .tailscale: "tailscale"
        case .hermesInstall: "hermes-install"
        case .hermesConfigure: "hermes-configure"
        case .computerUse: "computer-use"
        case .verify: "verify"
        }
    }

    var receipt: String {
        switch self {
        case .internet: "internet.ready"
        case .tailscale: "tailscale.ready"
        case .hermesInstall: "hermes-installed.ready"
        case .hermesConfigure: "hermes-configured.ready"
        case .computerUse: "computer-use.ready"
        case .verify: "verified.ready"
        }
    }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

@main
final class TetherGuestInstaller: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private static let guideSize = NSSize(width: 900, height: 690)
    private let state = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tether Host for Mac/Guest Setup", isDirectory: true)
    private var window: NSWindow!
    private var guideScrollView: NSScrollView!
    private var stepButtons: [NSButton] = []
    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var descriptionLabel: NSTextField!
    private var guidanceLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var actionButton: NSButton!
    private var terminal: WKWebView!
    private var terminalReady = false
    private var pendingOutput = Data()
    private var setupProcess: Process?
    private var terminalFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var selected: SetupStep = .internet
    private var wasRunning = false
    private var refreshTimer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = TetherGuestInstaller()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        selected = SetupStep.allCases.first(where: { !isComplete($0) }) ?? .verify
        let guideFrame = NSRect(origin: .zero, size: Self.guideSize)
        window = NSWindow(contentRect: guideFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Tether Guest Installer"
        window.delegate = self
        window.minSize = NSSize(width: 520, height: 360)
        sizeWindowToFitScreen()
        window.center()
        guideScrollView = NSScrollView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        guideScrollView.autoresizingMask = [.width, .height]
        guideScrollView.hasVerticalScroller = true
        guideScrollView.hasHorizontalScroller = true
        guideScrollView.autohidesScrollers = true
        guideScrollView.allowsMagnification = true
        guideScrollView.minMagnification = 0.8
        guideScrollView.maxMagnification = 1
        let content = NSView(frame: guideFrame)
        guideScrollView.documentView = content
        window.contentView = guideScrollView

        addLabel("Set up Tether in this VM", to: content, frame: NSRect(x: 28, y: 627, width: 830, height: 33),
                 font: .boldSystemFont(ofSize: 24))
        addLabel("Keep your existing macOS account and installed apps. Complete these six checks in order.",
                 to: content, frame: NSRect(x: 29, y: 599, width: 830, height: 22),
                 font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        addRule(to: content, frame: NSRect(x: 24, y: 584, width: 852, height: 1))
        addRule(to: content, frame: NSRect(x: 242, y: 66, width: 1, height: 506))

        for step in SetupStep.allCases {
            let button = NSButton(title: "", target: self, action: #selector(selectStep(_:)))
            button.tag = step.rawValue
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.frame = NSRect(x: 30, y: 515 - step.rawValue * 67, width: 196, height: 48)
            content.addSubview(button)
            stepButtons.append(button)
        }

        stepLabel = addLabel("", to: content, frame: NSRect(x: 274, y: 542, width: 580, height: 22),
                             font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
        titleLabel = addLabel("", to: content, frame: NSRect(x: 274, y: 502, width: 580, height: 36),
                              font: .boldSystemFont(ofSize: 25))
        descriptionLabel = addLabel("", to: content, frame: NSRect(x: 274, y: 444, width: 580, height: 55),
                                    font: .systemFont(ofSize: 14))
        guidanceLabel = addLabel("", to: content, frame: NSRect(x: 274, y: 373, width: 580, height: 47),
                                 font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        actionButton = NSButton(title: "", target: self, action: #selector(runSelectedStep))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.frame = NSRect(x: 274, y: 429, width: 210, height: 32)
        content.addSubview(actionButton)
        addLabel("SETUP CONSOLE", to: content, frame: NSRect(x: 274, y: 343, width: 580, height: 22),
                 font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        let terminalConfiguration = WKWebViewConfiguration()
        terminalConfiguration.userContentController.add(self, name: "pty")
        terminal = WKWebView(frame: NSRect(x: 274, y: 85, width: 595, height: 255), configuration: terminalConfiguration)
        terminal.navigationDelegate = self
        terminal.setValue(false, forKey: "drawsBackground")
        content.addSubview(terminal)
        if let resources = Bundle.main.resourceURL {
            terminal.loadFileURL(resources.appendingPathComponent("terminal.html"), allowingReadAccessTo: resources)
        }
        addRule(to: content, frame: NSRect(x: 24, y: 64, width: 852, height: 1))
        statusLabel = addLabel("", to: content, frame: NSRect(x: 29, y: 21, width: 830, height: 32),
                               font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

        refresh()
        fitGuideToWindowWidth()
        // AppKit's unflipped document views start at the bottom; show the title and first step first.
        guideScrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, Self.guideSize.height - guideScrollView.documentVisibleRect.height)))
        guideScrollView.reflectScrolledClipView(guideScrollView.contentView)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
        readSource?.cancel()
        if terminalFD >= 0 { Darwin.close(terminalFD) }
    }

    func windowDidResize(_ notification: Notification) {
        fitGuideToWindowWidth()
    }

    @objc private func screenConfigurationChanged() {
        sizeWindowToFitScreen()
        fitGuideToWindowWidth()
    }

    private func sizeWindowToFitScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        window.minSize = NSSize(width: min(520, visible.width), height: min(360, visible.height))
        let maximumContentSize = window.contentRect(forFrameRect: visible).size
        let size = NSSize(width: min(Self.guideSize.width, maximumContentSize.width),
                          height: min(Self.guideSize.height, maximumContentSize.height))
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrameOrigin(frame.origin)
    }

    private func fitGuideToWindowWidth() {
        guard guideScrollView != nil else { return }
        let width = guideScrollView.contentSize.width
        let magnification = min(1, max(guideScrollView.minMagnification, width / Self.guideSize.width))
        if abs(guideScrollView.magnification - magnification) > 0.001 {
            guideScrollView.magnification = magnification
        }
    }

    @objc private func selectStep(_ sender: NSButton) {
        guard let step = SetupStep(rawValue: sender.tag) else { return }
        selected = step
        refresh()
    }

    @objc private func runSelectedStep() {
        guard isVirtualMac, !isRunning, setupProcess == nil, terminalFD < 0,
              readSource == nil, isUnlocked(selected) else { return }
        let script = Bundle.main.resourceURL!.appendingPathComponent("Set up Tether Guest.command")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            showError("The setup engine is missing. Install the latest Tether guest setup disk and try again.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-e", "/dev/null", "/bin/bash", script.path, selected.scriptAction]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var terminalSize = winsize(ws_row: 14, ws_col: 78, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &terminalSize) == 0 else {
            showError("Could not create the embedded setup console.")
            return
        }
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        terminalFD = masterFD
        setupProcess = process
        pendingOutput.removeAll()
        terminal.evaluateJavaScript("window.tetherTerminal.clear(); window.tetherTerminal.focus();")
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.writeToTerminal(Data("\r\n\r\n\(finished.terminationStatus == 0 ? "Step finished." : "Step stopped. Read the error above, then try again.")\r\n".utf8))
                self.setupProcess = nil
                self.refresh()
            }
        }
        do {
            try process.run()
        } catch {
            Darwin.close(slaveFD)
            Darwin.close(masterFD)
            terminalFD = -1
            setupProcess = nil
            showError("Could not start this step: \(error.localizedDescription)")
            return
        }
        Darwin.close(slaveFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[..<count])
                DispatchQueue.main.async { self?.writeToTerminal(chunk) }
            } else {
                source.cancel()
                DispatchQueue.main.async {
                    if self?.terminalFD == masterFD {
                        self?.readSource = nil
                        self?.terminalFD = -1
                        Darwin.close(masterFD)
                        self?.refresh()
                    }
                }
            }
        }
        readSource = source
        source.resume()
        wasRunning = true
        statusLabel.stringValue = "This step is running in the setup console below."
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "pty", terminalFD >= 0, setupProcess?.isRunning == true,
              let value = message.body as? String else { return }
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(terminalFD, base.advanced(by: sent), buffer.count - sent)
                guard count > 0 else { break }
                sent += count
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        terminalReady = true
        if !pendingOutput.isEmpty {
            let bytes = pendingOutput
            pendingOutput.removeAll()
            writeToTerminal(bytes)
        }
    }

    private func writeToTerminal(_ bytes: Data) {
        guard terminalReady else { pendingOutput.append(bytes); return }
        let encoded = bytes.base64EncodedString()
        terminal.evaluateJavaScript("window.tetherTerminal.writeBase64('\(encoded)');")
    }

    private func refresh() {
        let running = isRunning
        if wasRunning && !running && isComplete(selected), let next = selected.next { selected = next }
        wasRunning = running
        for step in SetupStep.allCases {
            let marker = isComplete(step) ? "✓" : (isUnlocked(step) ? "\(step.rawValue + 1)" : "·")
            let button = stepButtons[step.rawValue]
            button.title = "\(marker)   \(step.title)"
            button.contentTintColor = selected == step ? .controlAccentColor : (isComplete(step) ? .systemGreen : .labelColor)
        }
        stepLabel.stringValue = "Step \(selected.rawValue + 1) of \(SetupStep.allCases.count)"
        titleLabel.stringValue = selected.title
        descriptionLabel.stringValue = selected.description
        guidanceLabel.stringValue = selected.guidance
        actionButton.title = isComplete(selected) ? "Run this check again" : selected.action
        actionButton.isEnabled = isVirtualMac && !running && readSource == nil && terminalFD < 0 && isUnlocked(selected)

        if !isVirtualMac {
            statusLabel.stringValue = "Open this installer inside the macOS VM. It cannot change the physical Mac."
            statusLabel.textColor = .systemOrange
        } else if running {
            let current = (try? String(contentsOf: state.appendingPathComponent("status.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            statusLabel.stringValue = current?.isEmpty == false ? current! : "A setup step is running in the console below."
            statusLabel.textColor = .secondaryLabelColor
        } else if isComplete(selected) {
            statusLabel.stringValue = selected == .verify
                ? "Guest connection verified. Add it to Tether on your iPhone."
                : "Step complete. Select the next step on the left."
            statusLabel.textColor = .systemGreen
        } else if !isUnlocked(selected) {
            statusLabel.stringValue = "Complete the previous step to unlock this action."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            let previous = (try? String(contentsOf: state.appendingPathComponent("status.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous, previous.hasPrefix("Stopped during:") {
                statusLabel.stringValue = previous
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = "Ready. Run this step using the console in this window."
                statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    private var isRunning: Bool {
        var isDirectory: ObjCBool = false
        return setupProcess?.isRunning == true || FileManager.default.fileExists(atPath: state.appendingPathComponent("running.lock").path,
                                               isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isComplete(_ step: SetupStep) -> Bool {
        FileManager.default.fileExists(atPath: state.appendingPathComponent(step.receipt).path)
            && (step != .verify || FileManager.default.fileExists(atPath: state.appendingPathComponent("connection.json").path))
    }

    private func isUnlocked(_ step: SetupStep) -> Bool {
        switch step {
        case .internet: return true
        case .tailscale, .hermesInstall: return isComplete(.internet)
        case .hermesConfigure: return isComplete(.hermesInstall)
        case .computerUse: return isComplete(.hermesConfigure)
        case .verify: return isComplete(.tailscale) && isComplete(.computerUse)
        }
    }

    private var isVirtualMac: Bool {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return false }
        return String(cString: bytes).hasPrefix("VirtualMac")
    }

    @discardableResult
    private func addLabel(_ value: String, to view: NSView, frame: NSRect,
                          font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = font
        label.textColor = color
        label.frame = frame
        view.addSubview(label)
        return label
    }

    private func addRule(to view: NSView, frame: NSRect) {
        let rule = NSBox(frame: frame)
        rule.boxType = .separator
        view.addSubview(rule)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tether Guest Installer"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
