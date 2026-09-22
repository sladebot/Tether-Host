import AppKit
import Darwin

@main
final class TetherGuestInstaller: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!

    static func main() {
        let app = NSApplication.shared
        let delegate = TetherGuestInstaller()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 470, height: 255)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Tether Guest Installer"
        window.center()

        let content = NSView(frame: frame)
        window.contentView = content

        let title = NSTextField(labelWithString: "Set up Tether inside this VM")
        title.font = .boldSystemFont(ofSize: 20)
        title.frame = NSRect(x: 30, y: 184, width: 410, height: 30)
        content.addSubview(title)

        let explanation = NSTextField(wrappingLabelWithString:
            "This installer checks the VM’s Internet connection, installs or configures Tailscale and Hermes, then verifies the connection. macOS will ask you to approve the package, VPN, and computer-use permissions.")
        explanation.frame = NSRect(x: 30, y: 99, width: 410, height: 74)
        content.addSubview(explanation)

        status = NSTextField(wrappingLabelWithString: "Run this only after the VM reaches the macOS desktop.")
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 64, width: 410, height: 30)
        content.addSubview(status)

        let start = NSButton(title: "Start setup", target: self, action: #selector(startSetup))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.frame = NSRect(x: 324, y: 24, width: 116, height: 32)
        content.addSubview(start)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startSetup() {
        guard isVirtualMac else {
            showError("This installer must run inside the macOS VM, not on the physical Mac.")
            return
        }
        let command = Bundle.main.resourceURL!.appendingPathComponent("Set up Tether Guest.command")
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            showError("The guest setup program is missing from this installer app.")
            return
        }
        // Terminal supplies the interactive TTY needed for Tailscale sign-in,
        // model authentication, and macOS permission prompts.
        guard NSWorkspace.shared.open(command) else {
            showError("macOS could not open the installer. Try opening this app again.")
            return
        }
        status.stringValue = "Setup is running in Terminal inside this VM. Follow its prompts."
    }

    private var isVirtualMac: Bool {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return false }
        return String(cString: bytes).hasPrefix("VirtualMac")
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tether Guest Installer"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
