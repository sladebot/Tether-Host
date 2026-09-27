import Foundation

public enum LinuxGuestSeedError: LocalizedError {
    case missingResources
    case missingDiskUtility
    case invalidBundle
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .missingResources: "The Debian guest installer is missing from this app. Reinstall Tether Host before creating the VM."
        case .missingDiskUtility: "macOS cannot create the Debian first-boot setup disk because hdiutil is unavailable."
        case .invalidBundle: "The Debian VM bundle directory is unavailable."
        case .creationFailed: "Debian first-boot setup disk creation failed. Check free space and try again."
        }
    }
}

/// Creates a NoCloud seed for Debian's first boot. The one-time console
/// password is generated per VM and saved beside the VM with owner-only access.
public enum LinuxGuestSeedWriter {
    public static func credentialsURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent("debian-credentials.txt")
    }

    public static func createSeed(
        in bundle: URL,
        vmID: VirtualMachineID,
        guestResourcesURL: URL?
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard bundle.isFileURL,
                  (try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
                  (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                throw LinuxGuestSeedError.invalidBundle
            }
            let utility = URL(fileURLWithPath: "/usr/bin/hdiutil")
            guard fm.isExecutableFile(atPath: utility.path) else { throw LinuxGuestSeedError.missingDiskUtility }
            let stage = bundle.appendingPathComponent(".seed-\(UUID().uuidString)", isDirectory: true)
            let destination = bundle.appendingPathComponent("seed.iso")
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            try Data("instance-id: \(vmID.description)\nlocal-hostname: debian-tether-vm\n".utf8)
                .write(to: stage.appendingPathComponent("meta-data"), options: .atomic)
            try Data("version: 2\nethernets:\n  tether:\n    match:\n      name: \"en*\"\n    dhcp4: true\n    dhcp6: false\n".utf8)
                .write(to: stage.appendingPathComponent("network-config"), options: .atomic)
            try Data(userData(password: password).utf8)
                .write(to: stage.appendingPathComponent("user-data"), options: .atomic)
            if let guestResourcesURL,
               (try? guestResourcesURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for filename in ["update-guest-tools.sh", "setup.sh", "session-start.sh", "keep-awake.sh", "clipboard-toggle.sh", "dns-fallback.sh", "linux_guest_setup.py", "guest_installer.py", "installer_flow.py", "installer_logging.py", "vsock_helper.py", "clipboard_broker.py", "components.json", "README.txt"] {
                    let source = guestResourcesURL.appendingPathComponent(filename)
                    guard fm.fileExists(atPath: source.path) else { throw LinuxGuestSeedError.missingResources }
                    try fm.copyItem(at: source, to: stage.appendingPathComponent(filename))
                }
                let version = guestResourcesURL.appendingPathComponent("installer-version.json")
                if fm.fileExists(atPath: version.path),
                   (try? version.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                    try fm.copyItem(at: version, to: stage.appendingPathComponent("installer-version.json"))
                }
            } else {
                throw LinuxGuestSeedError.missingResources
            }
            let process = Process()
            process.executableURL = utility
            process.arguments = ["makehybrid", "-iso", "-joliet", "-iso-volume-name", "cidata",
                                 "-joliet-volume-name", "cidata", "-o", destination.path, stage.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
                try? fm.removeItem(at: destination)
                throw LinuxGuestSeedError.creationFailed
            }
            let credentials = "Debian console user: tether\nOne-time password: \(password)\nDebian requires you to choose a private password at first login.\n"
            try Data(credentials.utf8).write(to: credentialsURL(in: bundle), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL(in: bundle).path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        }.value
    }

    static func userData(password: String) -> String {
        """
        #cloud-config
        hostname: debian-tether-vm
        disable_root: true
        ssh_pwauth: false
        users:
          - name: tether
            gecos: Tether VM User
            groups: [adm, sudo, video, plugdev]
            shell: /bin/bash
            lock_passwd: false
            sudo: "ALL=(ALL) ALL"
        chpasswd:
          expire: true
          users:
            - name: tether
              password: \(password)
              type: text
        # Xfce and LightDM give CuaDriver an X11 desktop within a 24 GiB VM.
        runcmd:
          - 'set -e'
          - [sh, -c, "if [ -c /dev/hvc0 ]; then echo TETHER_CLOUD_INIT_START > /dev/hvc0; fi"]
          - [mkdir, -p, /opt/tether-guest, /mnt/tether-seed]
          - [mount, -o, ro, LABEL=cidata, /mnt/tether-seed]
          - [cp, /mnt/tether-seed/update-guest-tools.sh, /mnt/tether-seed/setup.sh, /mnt/tether-seed/session-start.sh, /mnt/tether-seed/keep-awake.sh, /mnt/tether-seed/clipboard-toggle.sh, /mnt/tether-seed/dns-fallback.sh, /mnt/tether-seed/linux_guest_setup.py, /mnt/tether-seed/guest_installer.py, /mnt/tether-seed/installer_flow.py, /mnt/tether-seed/installer_logging.py, /mnt/tether-seed/vsock_helper.py, /mnt/tether-seed/clipboard_broker.py, /mnt/tether-seed/components.json, /opt/tether-guest/]
          - [sh, -c, "if [ -f /mnt/tether-seed/installer-version.json ]; then cp /mnt/tether-seed/installer-version.json /opt/tether-guest/; fi"]
          - [umount, /mnt/tether-seed]
          - [chmod, '0755', /opt/tether-guest/setup.sh]
          - [chmod, '0755', /opt/tether-guest/update-guest-tools.sh]
          - [chmod, '0755', /opt/tether-guest/session-start.sh]
          - [chmod, '0755', /opt/tether-guest/keep-awake.sh]
          - [chmod, '0755', /opt/tether-guest/clipboard-toggle.sh]
          - [chmod, '0755', /opt/tether-guest/dns-fallback.sh]
          - [chmod, '0755', /opt/tether-guest/guest_installer.py]
          - [chmod, '0755', /opt/tether-guest/vsock_helper.py]
          - [/opt/tether-guest/dns-fallback.sh]
          - [sh, -c, "for i in 1 2 3; do apt-get update -o APT::Update::Error-Mode=any -o Acquire::Retries=3 && exit 0; sleep 5; done; echo 'Debian package indexes could not be updated' >&2; exit 1"]
          - [env, DEBIAN_FRONTEND=noninteractive, NEEDRESTART_MODE=a, apt-get, install, -y, --no-install-recommends, ca-certificates, curl, jq, python3, python3-venv, python3-yaml, python3-gi, gir1.2-gtk-3.0, gir1.2-vte-2.91, xfce4, xfce4-terminal, xfce4-power-manager, lightdm, lightdm-gtk-greeter, xorg, dbus-x11, at-spi2-core, chromium, chromium-driver, xdg-utils, xclip, xsel, wmctrl, xdotool, scrot]
          - [apt-get, clean]
          - [sh, -c, "fstrim -av >/dev/null 2>&1 || true"]
          - [systemctl, daemon-reload]
          - [systemctl, enable, --now, tether-dns-fallback.service]
          - [systemctl, enable, --now, tether-vsock.service]
          - [systemctl, set-default, graphical.target]
          - [systemctl, enable, --now, lightdm.service]
          - [sh, -c, "command -v chromium >/dev/null && dpkg-query -W -f='${Status}' chromium 2>/dev/null | grep -qx 'install ok installed' && systemctl is-active --quiet lightdm.service && systemctl is-active --quiet tether-vsock.service && test -S /tmp/.X11-unix/X0 && { [ ! -c /dev/hvc0 ] || echo TETHER_CLOUD_INIT_DONE > /dev/hvc0; }"]
        write_files:
          - path: /usr/share/applications/tether-text-clipboard.desktop
            owner: root:root
            permissions: '0644'
            content: |
              [Desktop Entry]
              Type=Application
              Name=Tether Text Clipboard
              Comment=Switch explicit host and Debian text clipboard transfers on or off
              Exec=/opt/tether-guest/clipboard-toggle.sh
              Terminal=true
              Categories=System;
          - path: /etc/systemd/system/tether-dns-fallback.service
            owner: root:root
            permissions: '0644'
            content: |
              [Unit]
              Description=Tether guest DNS fallback when NAT DNS is unavailable
              Wants=network-online.target
              After=network-online.target systemd-resolved.service
              ConditionPathExists=/opt/tether-guest/dns-fallback.sh

              [Service]
              Type=oneshot
              ExecStart=/opt/tether-guest/dns-fallback.sh
              TimeoutStartSec=150

              [Install]
              WantedBy=multi-user.target
          - path: /usr/share/applications/tether-guest-installer.desktop
            owner: root:root
            permissions: '0644'
            content: |
              [Desktop Entry]
              Type=Application
              Name=Tether Guest Installer
              Comment=Set up and verify this Debian VM
              Exec=/usr/bin/python3 /opt/tether-guest/guest_installer.py
              Terminal=false
              Categories=System;
          - path: /etc/xdg/autostart/tether-hermes-desktop.desktop
            owner: root:root
            permissions: '0644'
            content: |
              [Desktop Entry]
              Type=Application
              Name=Tether Hermes Desktop Session
              Exec=/opt/tether-guest/session-start.sh
              NoDisplay=true
          - path: /etc/systemd/system/tether-vsock.service
            owner: root:root
            permissions: '0644'
            content: |
              [Unit]
              Description=Tether private VM handoff
              After=network-online.target

              [Service]
              Type=simple
              User=tether
              Group=tether
              ExecStart=/usr/bin/python3 /opt/tether-guest/vsock_helper.py
              Restart=on-failure
              RestartSec=3
              NoNewPrivileges=true
              ProtectSystem=strict
              RestrictAddressFamilies=AF_VSOCK AF_UNIX

              [Install]
              WantedBy=multi-user.target
          - path: /etc/lightdm/lightdm.conf.d/50-tether-x11.conf
            owner: root:root
            permissions: '0644'
            content: |
              [Seat:*]
              user-session=xfce
              greeter-session=lightdm-gtk-greeter
        final_message: 'Debian first-boot setup has finished or stopped. Run cloud-init status --long to confirm success before opening Tether Guest Installer.'
        """
    }
}
