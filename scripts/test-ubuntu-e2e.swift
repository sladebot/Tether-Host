import AppKit
import Darwin
import Foundation
import TetherHostCore
import Virtualization

/// Destructive only within its own --root. The test never discovers or stops
/// the user's saved VMs, and keeps its bundle for inspection after shutdown.
@main
struct UbuntuE2E {
    @MainActor private static var displayWindow: NSWindow?
    @MainActor
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            fputs("Ubuntu E2E failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--root"),
              CommandLine.arguments.indices.contains(index + 1) else {
            throw Failure("Missing --root")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            .standardizedFileURL
        guard root.path.hasPrefix("/tmp/tether-ubuntu-e2e"),
              !root.path.contains("..") else {
            throw Failure("Test root must be under /private/tmp/tether-ubuntu-e2e")
        }
        let vmRoot = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        let suite = "app.tether.ubuntu.e2e.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { throw Failure("No test defaults") }
        defer { preferences.removePersistentDomain(forName: suite) }
        let input = Pipe()
        let manager = NativeVMManager(preferences: preferences, rootURLOverride: vmRoot,
                                      serialInputHandleOverride: input.fileHandleForReading)
        if let existingIndex = CommandLine.arguments.firstIndex(of: "--existing-id"),
           CommandLine.arguments.indices.contains(existingIndex + 1) {
            guard let existingID = VirtualMachineID(CommandLine.arguments[existingIndex + 1]) else {
                throw Failure("Invalid existing VM ID")
            }
            let bundle = vmRoot.appendingPathComponent(existingID.description, isDirectory: true)
            let console = Console(serial: bundle.appendingPathComponent("serial.log"),
                                  input: input.fileHandleForWriting, startAtEnd: true)
            if CommandLine.arguments.contains("--lifecycle-e2e") {
                try await checkLifecycle(manager: manager, id: existingID, console: console)
                return
            }
            try await manager.boot(existingID)
            guard manager.runningGuestOS == .ubuntu,
                  manager.virtualMachine != nil else {
                throw Failure("Existing VM did not start as Ubuntu")
            }
            print("Existing isolated Ubuntu VM is displayed; create \(root.appendingPathComponent("shutdown.request").path) to request guest shutdown.")
            if CommandLine.arguments.contains("--diagnose") {
                let password = try readOneTimePassword(bundle.appendingPathComponent("ubuntu-credentials.txt"))
                _ = try await console.login(password: password, newPassword: nil, timeoutSeconds: 300)
                try console.send("cloud-init status --long")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 45)
                try console.send("grep -Ei 'error|failed|traceback|fatal' /var/log/cloud-init.log | tail -35")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 45)
                try console.send("sudo tail -n 100 /var/log/cloud-init-output.log")
                try await console.waitFor("[sudo] password", timeoutSeconds: 30)
                try console.send(password)
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 45)
                try console.send("sudo journalctl -u cloud-final --no-pager -n 80")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 45)
                for command in ["ip link; ip -4 address; ip -4 route; getent hosts ports.ubuntu.com",
                                "cat /etc/resolv.conf; resolvectl status --no-pager; resolvectl query ports.ubuntu.com",
                                "sudo resolvectl dns enp0s1 1.1.1.1; resolvectl status --no-pager; resolvectl query ports.ubuntu.com; curl -4 -fsSI --max-time 15 https://ports.ubuntu.com/ubuntu-ports/dists/noble/InRelease | head -n 3",
                                "getent ahostsv4 ports.ubuntu.com; ping -c 1 -W 3 192.168.64.1; ping -c 1 -W 3 1.1.1.1",
                                "sudo cat /etc/netplan/*; networkctl; sudo journalctl -u systemd-networkd --no-pager -n 40",
                                "sudo journalctl -u cloud-final -b -1 --no-pager -n 35; sudo grep -nEi 'network did not|indexes could not|scripts_user|failed|error' /var/log/cloud-init-output.log | tail -n 35",
                                "systemctl get-default; systemctl is-active lightdm.service; systemctl status lightdm.service --no-pager -n 30; dpkg-query -W lightdm lightdm-gtk-greeter xfce4-session xserver-xorg-core 2>&1",
                                "ls -la /usr/share/xgreeters /usr/share/xsessions /var/log/lightdm 2>&1; sudo journalctl -u lightdm.service -b --no-pager -n 65",
                                "sudo tail -n 85 /var/log/lightdm/lightdm.log",
                                "ls -la /dev/dri /tmp/.X11-unix 2>&1; lsmod | grep -E 'virtio_gpu|drm|gpu' || true; modinfo virtio_gpu 2>&1 | head -n 12; pgrep -a -f 'Xorg|Xwayland|lightdm|greeter' || true",
                                "cat /etc/apt/sources.list.d/ubuntu.sources; apt-cache policy xfce4 lightdm epiphany-browser",
                                "sudo blkid; sudo mkdir -p /mnt/tether-inspect; sudo mount -o ro /dev/vdb /mnt/tether-inspect; ls -la /mnt/tether-inspect; sudo umount /mnt/tether-inspect"] {
                    try console.send(command)
                    try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 90)
                }
                print("Cloud-init diagnostics captured in isolated serial.log.")
            }
            if CommandLine.arguments.contains("--repair-greeter") {
                let password = try readOneTimePassword(bundle.appendingPathComponent("ubuntu-credentials.txt"))
                _ = try await console.login(password: password, newPassword: nil, timeoutSeconds: 300)
                try console.send("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lightdm-gtk-greeter")
                try await console.waitFor("[sudo] password", timeoutSeconds: 30)
                try console.send(password)
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 600)
                try console.send("sudo systemctl reset-failed lightdm.service; sudo systemctl start lightdm.service; systemctl status lightdm.service --no-pager -n 20; ls -la /usr/share/xgreeters /tmp/.X11-unix")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 90)
                try await console.check("systemctl is-active --quiet lightdm.service && test -S /tmp/.X11-unix/X0 && pgrep -f '[l]ightdm-gtk-greeter' >/dev/null && echo REPAIR_GUI''_OK || echo REPAIR_GUI''_FAIL",
                                        pass: "REPAIR_GUI_OK", fail: "REPAIR_GUI_FAIL", timeoutSeconds: 45)
                print("Isolated Ubuntu LightDM/greeter repair passed.")
            }
            if CommandLine.arguments.contains("--clipboard-e2e") {
                let password = try readOneTimePassword(bundle.appendingPathComponent("ubuntu-credentials.txt"))
                _ = try await console.login(password: password, newPassword: nil, timeoutSeconds: 300)
                try await console.check("getent passwd tetherexpiryprobe >/dev/null && echo PROBE_''PRESENT || echo PROBE_''CLEANED",
                                        pass: "PROBE_CLEANED", fail: "PROBE_PRESENT", timeoutSeconds: 30)
                try console.send("sudo -k; sudo mkdir -p /mnt/tether-tools")
                try await console.waitFor("[sudo] password", timeoutSeconds: 30)
                try console.send(password)
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 60)
                try await console.check("sudo mount -o ro /dev/vdc /mnt/tether-tools && test -f /mnt/tether-tools/update-guest-tools.sh && echo TOOLS_''MOUNTED || echo TOOLS_''MISSING",
                                        pass: "TOOLS_MOUNTED", fail: "TOOLS_MISSING", timeoutSeconds: 60)
                try console.send("sudo sh /mnt/tether-tools/update-guest-tools.sh")
                try await console.waitFor("Tether guest tools updated", timeoutSeconds: 600)
                try await console.check("sudo sh -c \"printf '[Seat:*]\\nautologin-user=tether\\nautologin-user-timeout=0\\nuser-session=xfce\\n' > /etc/lightdm/lightdm.conf.d/90-tether-clipboard-e2e.conf\" && echo AUTOLOGIN_''SET || echo AUTOLOGIN_''FAIL",
                                        pass: "AUTOLOGIN_SET", fail: "AUTOLOGIN_FAIL", timeoutSeconds: 30)
                try console.send("sudo systemctl restart lightdm.service")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 90)
                try await console.check("for i in $(seq 1 60); do pgrep -u tether -x xfce4-session >/dev/null && break; sleep 2; done; pgrep -u tether -x xfce4-session >/dev/null && echo XFCE_SESSION_''OK || echo XFCE_SESSION_''FAIL",
                                        pass: "XFCE_SESSION_OK", fail: "XFCE_SESSION_FAIL", timeoutSeconds: 150)
                try await console.check("rm -f ~/.local/share/tether-guest/clipboard-enabled; echo CLIPBOARD_''RESET",
                                        pass: "CLIPBOARD_RESET", fail: "CLIPBOARD_RESET_FAILED", timeoutSeconds: 30)
                try console.send("printf '\\n' | XDG_SESSION_TYPE=x11 DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority /opt/tether-guest/clipboard-toggle.sh")
                try await console.waitFor("Tether text clipboard transfers are ON", timeoutSeconds: 30)
                try console.send("pgrep -a -u tether -x xfce4-session || true; loginctl list-sessions --no-legend; systemctl --user show-environment | grep -E '^(DISPLAY|XAUTHORITY|XDG_SESSION_TYPE)=' || true; ls -l ~/.Xauthority /tmp/.X11-unix/X0 2>&1")
                try await console.waitFor("tether@tether-ubuntu", timeoutSeconds: 45)
                let sample = "Ubuntu π 🧪 clipboard roundtrip"
                try await manager.writeGuestClipboardText(sample)
                let received = try await manager.readGuestClipboardText()
                guard received == sample else { throw Failure("Guest clipboard returned different text") }
                print("CLIPBOARD_ROUNDTRIP_OK")
                try console.send("printf '\\n' | XDG_SESSION_TYPE=x11 DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority /opt/tether-guest/clipboard-toggle.sh")
                try await console.waitFor("Tether text clipboard transfers are OFF", timeoutSeconds: 30)
                do {
                    try await manager.writeGuestClipboardText("should be rejected")
                    throw Failure("Guest clipboard accepted text after opt-out")
                } catch GuestClipboardError.guestRejected {
                    print("CLIPBOARD_OPTOUT_OK")
                }
                try await console.check("sudo rm -f /etc/lightdm/lightdm.conf.d/90-tether-clipboard-e2e.conf && sudo umount /mnt/tether-tools && echo TEST_CLEANUP_''OK || echo TEST_CLEANUP_''FAIL",
                                        pass: "TEST_CLEANUP_OK", fail: "TEST_CLEANUP_FAIL", timeoutSeconds: 45)
            }
            let request = root.appendingPathComponent("shutdown.request")
            while !CommandLine.arguments.contains("--diagnose") &&
                  !CommandLine.arguments.contains("--repair-greeter") &&
                  !CommandLine.arguments.contains("--clipboard-e2e") &&
                  !FileManager.default.fileExists(atPath: request.path) && manager.isRunning {
                try await Task.sleep(for: .seconds(2))
            }
            if manager.isRunning {
                manager.requestShutdown()
                let deadline = Date().addingTimeInterval(180)
                while manager.isRunning && Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                }
                if manager.isRunning { await manager.forcePowerOff() }
            }
            print("Existing isolated Ubuntu VM stopped.")
            return
        }
        var vmID: VirtualMachineID?
        do {
            print("Downloading checksum-verified Ubuntu ARM64 image into isolated test root…")
            await manager.downloadUbuntuImage()
            guard manager.ubuntuImageURL != nil else { throw Failure(manager.status) }
            guard manager.creationCPURange.contains(2), manager.creationMemoryRange.contains(4),
                  manager.creationDiskRange.contains(24) else {
                throw Failure("Host does not offer 2 CPU / 4 GiB RAM / 24 GiB disk")
            }
            manager.creationCPUCount = 2
            manager.creationMemoryGiB = 4
            manager.creationDiskGiB = 24
            print("Creating and booting isolated Ubuntu VM…")
            guard let id = await manager.installUbuntu() else { throw Failure(manager.status) }
            vmID = id
            guard manager.isRunning, manager.runningGuestOS == .ubuntu,
                  manager.runningVMID == id else { throw Failure(manager.status) }
            let bundle = vmRoot.appendingPathComponent(id.description, isDirectory: true)
            let serial = bundle.appendingPathComponent("serial.log")
            let credentials = bundle.appendingPathComponent("ubuntu-credentials.txt")
            guard FileManager.default.fileExists(atPath: serial.path),
                  FileManager.default.fileExists(atPath: credentials.path) else {
                throw Failure("Missing serial output or one-time credentials")
            }
            let password = try readOneTimePassword(credentials)
            let newPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let console = Console(serial: serial, input: input.fileHandleForWriting)
            print("Waiting for Ubuntu serial console and cloud-init…")
            let activePassword = try await console.login(password: password, newPassword: newPassword,
                                                         timeoutSeconds: 900)
            try Data("Ubuntu console user: tether\nCurrent password: \(activePassword)\n".utf8)
                .write(to: credentials, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: credentials.path)
            try await console.check("cloud-init status --wait >/dev/null 2>&1 && echo CLOUD''_OK || echo CLOUD''_FAIL",
                                    pass: "CLOUD_OK", fail: "CLOUD_FAIL", timeoutSeconds: 900)
            try await console.check("curl -fsSI --max-time 25 https://cloud-images.ubuntu.com/ >/dev/null 2>&1 && echo NET''_OK || echo NET''_FAIL",
                                    pass: "NET_OK", fail: "NET_FAIL", timeoutSeconds: 90)
            try await console.check("test -f /opt/tether-guest/setup.sh && systemctl is-active --quiet tether-vsock.service && echo GUEST''_OK || echo GUEST''_FAIL",
                                    pass: "GUEST_OK", fail: "GUEST_FAIL", timeoutSeconds: 45)
            try await console.check("sh -c 'for i in $(seq 1 30); do if systemctl is-active --quiet lightdm.service && test -S /tmp/.X11-unix/X0 && pgrep -f \"[l]ightdm-gtk-greeter\" >/dev/null; then echo GUI''_OK; exit 0; fi; sleep 2; done; echo GUI''_FAIL'",
                                    pass: "GUI_OK", fail: "GUI_FAIL", timeoutSeconds: 90)
            try await console.check("printf persisted > ~/tether-e2e-marker && sync && echo WRITE''_OK",
                                    pass: "WRITE_OK", fail: "WRITE_FAIL", timeoutSeconds: 30)
            print("First boot, cloud-init, network, and guest handoff service passed. Rebooting…")
            try console.send("sudo reboot")
            try await console.waitFor("[sudo] password", timeoutSeconds: 40)
            try console.send(activePassword)
            _ = try await console.login(password: activePassword, newPassword: nil,
                                        timeoutSeconds: 600)
            try await console.check("test \"$(cat ~/tether-e2e-marker)\" = persisted && echo PERSIST''_OK || echo PERSIST''_FAIL",
                                    pass: "PERSIST_OK", fail: "PERSIST_FAIL", timeoutSeconds: 45)
            try await console.check("curl -fsSI --max-time 25 https://cloud-images.ubuntu.com/ >/dev/null 2>&1 && echo REBOOT_NET''_OK || echo REBOOT_NET''_FAIL",
                                    pass: "REBOOT_NET_OK", fail: "REBOOT_NET_FAIL", timeoutSeconds: 90)
            try await console.check("systemctl is-active --quiet tether-vsock.service && echo REBOOT_GUEST''_OK || echo REBOOT_GUEST''_FAIL",
                                    pass: "REBOOT_GUEST_OK", fail: "REBOOT_GUEST_FAIL", timeoutSeconds: 45)
            try await console.check("sh -c 'for i in $(seq 1 30); do if systemctl is-active --quiet lightdm.service && test -S /tmp/.X11-unix/X0 && pgrep -f \"[l]ightdm-gtk-greeter\" >/dev/null; then echo REBOOT_GUI''_OK; exit 0; fi; sleep 2; done; echo REBOOT_GUI''_FAIL'",
                                    pass: "REBOOT_GUI_OK", fail: "REBOOT_GUI_FAIL", timeoutSeconds: 90)
            print("Reboot persistence passed. Requesting guest shutdown…")
            manager.requestShutdown()
            let stopDeadline = Date().addingTimeInterval(240)
            while manager.isRunning && Date() < stopDeadline { try await Task.sleep(for: .seconds(2)) }
            if manager.isRunning { await manager.forcePowerOff() }
            let log = try String(contentsOf: serial, encoding: .utf8)
            guard !log.contains(password), !log.contains(newPassword) else {
                throw Failure("Console log contains a test password; inspect privately")
            }
            let disk = bundle.appendingPathComponent("disk.img")
            var info = stat()
            guard lstat(disk.path, &info) == 0 else { throw Failure("Cannot stat disk image") }
            let logical = Int64(info.st_size)
            let allocated = Int64(info.st_blocks) * 512
            guard logical == 24 * 1_073_741_824,
                  allocated > 0, allocated < logical else {
                throw Failure("Disk is not a 24 GiB sparse image")
            }
            let report = Report(vmID: id.description, serialLog: serial.path,
                                logicalDiskBytes: logical, allocatedDiskBytes: allocated,
                                ubuntuBoot: true, cloudInit: true, network: true,
                                guestHandoffService: true, rebootPersistence: true,
                                graphicalLogin: true,
                                hermesHealth: "not exercised: guest service requires user Tailscale and Hermes credentials")
            let reportURL = root.appendingPathComponent("report.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            print("PASS: Ubuntu E2E; physical disk \(allocated / 1_048_576) MiB / 24 GiB logical; report \(reportURL.path)")
        } catch {
            if vmID != nil && manager.isRunning { await manager.forcePowerOff() }
            throw error
        }
    }

    @MainActor
    private static func checkLifecycle(manager: NativeVMManager, id: VirtualMachineID, console: Console) async throws {
        var firstBoot: Task<Void, Error>?
        do {
            let boot = Task { try await manager.boot(id) }
            firstBoot = boot
            let startDeadline = Date().addingTimeInterval(30)
            while manager.startingVMID != id && !manager.isRunning && Date() < startDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard manager.startingVMID == id, manager.isBusy else {
                throw Failure("Did not observe the VM's reserved starting state")
            }
            do {
                try await manager.boot(id)
                throw Failure("Overlapping boot of the same VM was accepted")
            } catch NativeVMError.cannotStartDuringInstall {
                print("OVERLAPPING_BOOT_REJECTED")
            }
            try await boot.value
            firstBoot = nil
            guard manager.isRunning, manager.runningVMID == id,
                  manager.startingVMID == nil, !manager.isBusy else {
                throw Failure("VM did not settle into the expected running state")
            }
            let otherID = VirtualMachineID(rawValue: UUID())
            do {
                try await manager.boot(otherID)
                throw Failure("Another VM boot was accepted while the test VM was running")
            } catch NativeVMError.anotherVMRunning {
                print("OTHER_VM_BOOT_REJECTED")
            }
            manager.requestShutdown(for: otherID)
            guard manager.isRunning, manager.runningVMID == id,
                  !manager.shutdownRequested else {
                throw Failure("Shutdown request for another VM changed the running test VM")
            }
            await manager.forcePowerOff(for: otherID)
            guard manager.isRunning, manager.runningVMID == id,
                  !manager.shutdownRequested else {
                throw Failure("Force off request for another VM changed the running test VM")
            }
            print("WRONG_VM_POWER_REQUESTS_IGNORED")
            // Wait for the guest OS to service ACPI shutdown rather than sending
            // the request while UEFI is still handing off to the kernel.
            try await console.waitFor("login:", timeoutSeconds: 120)
            manager.requestShutdown(for: id)
            guard manager.shutdownRequested else {
                throw Failure("Test VM did not accept its targeted guest shutdown request: \(manager.status)")
            }
            let stopDeadline = Date().addingTimeInterval(180)
            while manager.isRunning && Date() < stopDeadline {
                try await Task.sleep(for: .seconds(1))
            }
            guard !manager.isRunning, manager.runningVMID == nil else {
                throw Failure("Test VM did not complete a clean guest shutdown")
            }
            // Host-initiated stop does not promise a guestDidStop callback.
            // Verify completion clears the manager immediately and permits reuse.
            try await manager.boot(id)
            await manager.forcePowerOff(for: id)
            guard !manager.isRunning, !manager.isBusy, manager.runningVMID == nil,
                  manager.virtualMachine == nil else {
                throw Failure("Host force-off left stale running state")
            }
            print("HOST_FORCE_OFF_STATE_OK")
            print("LIFECYCLE_E2E_OK")
        } catch {
            if let firstBoot { _ = try? await firstBoot.value }
            if manager.runningVMID == id {
                manager.requestShutdown(for: id)
                let cleanupDeadline = Date().addingTimeInterval(45)
                while manager.runningVMID == id && Date() < cleanupDeadline {
                    try? await Task.sleep(for: .seconds(1))
                }
                if manager.runningVMID == id { await manager.forcePowerOff(for: id) }
            }
            throw error
        }
    }

    private static func readOneTimePassword(_ file: URL) throws -> String {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: {
            $0.hasPrefix("One-time password: ") || $0.hasPrefix("Current password: ")
        }),
              let value = line.split(separator: ":", maxSplits: 1).last.map(String.init),
              !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure("Cannot read one-time console password")
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

private struct Report: Encodable {
    let vmID: String
    let serialLog: String
    let logicalDiskBytes: Int64
    let allocatedDiskBytes: Int64
    let ubuntuBoot: Bool
    let cloudInit: Bool
    let network: Bool
    let guestHandoffService: Bool
    let rebootPersistence: Bool
    let graphicalLogin: Bool
    let hermesHealth: String
}

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private final class Console {
    private let serial: URL
    private let input: FileHandle
    private var offset = 0
    init(serial: URL, input: FileHandle, startAtEnd: Bool = false) {
        self.serial = serial
        self.input = input
        if startAtEnd { offset = ((try? Data(contentsOf: serial)) ?? Data()).count }
    }

    func send(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    func waitFor(_ marker: String, timeoutSeconds: TimeInterval) async throws {
        _ = try await waitForAny([marker], timeoutSeconds: timeoutSeconds)
    }

    func waitForAny(_ markers: [String], timeoutSeconds: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var observed = ""
        while Date() < deadline {
            let bytes = (try? Data(contentsOf: serial)) ?? Data()
            if bytes.count > offset {
                observed += String(decoding: bytes.dropFirst(offset), as: UTF8.self)
                offset = bytes.count
                if observed.count > 100_000 { observed = String(observed.suffix(50_000)) }
            }
            if let marker = markers.first(where: { observed.localizedCaseInsensitiveContains($0) }) {
                return marker
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure("Serial console timed out waiting for \(markers.joined(separator: " or "))")
    }

    func login(password: String, newPassword: String?, timeoutSeconds: TimeInterval) async throws -> String {
        try await waitFor("login:", timeoutSeconds: timeoutSeconds)
        try send("tether")
        try await waitFor("Password:", timeoutSeconds: 30)
        try send(password)
        var state = try await waitForAny(["New password:", "Current password:",
                                         "(current) UNIX password:",
                                         "tether@tether-ubuntu", "Login incorrect"], timeoutSeconds: 60)
        if state == "Login incorrect" { throw Failure("Ubuntu console login rejected generated password") }
        if state == "Current password:" || state == "(current) UNIX password:" {
            try send(password)
            state = try await waitForAny(["New password:", "Login incorrect"], timeoutSeconds: 30)
            if state == "Login incorrect" { throw Failure("Ubuntu password change rejected original password") }
        }
        if state == "New password:" {
            guard let newPassword else { throw Failure("Unexpected forced password change") }
            try send(newPassword)
            try await waitFor("Retype new password:", timeoutSeconds: 30)
            try send(newPassword)
            try await waitFor("tether@tether-ubuntu", timeoutSeconds: 60)
            return newPassword
        }
        return password
    }

    func check(_ command: String, pass: String, fail: String, timeoutSeconds: TimeInterval) async throws {
        try send(command)
        let marker = try await waitForAny([pass, fail], timeoutSeconds: timeoutSeconds)
        if marker == fail { throw Failure("Guest check failed: \(fail)") }
    }
}
