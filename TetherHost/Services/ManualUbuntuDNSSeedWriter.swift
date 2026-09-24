import Foundation

/// A small NoCloud disk for the interactive Ubuntu Desktop live session.
/// It deliberately contains no `autoinstall` directives or account settings.
public enum ManualUbuntuDNSSeedWriter {
    private static let version = "2"

    public static func seedURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent("manual-dns-seed.iso")
    }

    private static func versionURL(in bundle: URL) -> URL {
        bundle.appendingPathComponent("manual-dns-seed.version")
    }

    public static func ensureSeed(in bundle: URL, vmID: VirtualMachineID,
                                  guestResourcesURL: URL?) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard bundle.isFileURL,
                  (try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
                  (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                throw LinuxGuestSeedError.invalidBundle
            }
            let destination = seedURL(in: bundle)
            let marker = versionURL(in: bundle)
            if fm.fileExists(atPath: destination.path),
               (try? String(contentsOf: marker, encoding: .utf8)) == version {
                return destination
            }
            let utility = URL(fileURLWithPath: "/usr/bin/hdiutil")
            guard fm.isExecutableFile(atPath: utility.path) else { throw LinuxGuestSeedError.missingDiskUtility }
            guard let guestResourcesURL,
                  (try? guestResourcesURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                throw LinuxGuestSeedError.missingResources
            }
            let scriptURL = guestResourcesURL.appendingPathComponent("dns-fallback.sh")
            guard let script = try? String(contentsOf: scriptURL, encoding: .utf8), !script.isEmpty else {
                throw LinuxGuestSeedError.missingResources
            }
            let stage = bundle.appendingPathComponent(".manual-dns-seed-\(UUID().uuidString)", isDirectory: true)
            let temporaryISO = bundle.appendingPathComponent(".manual-dns-seed-\(UUID().uuidString).iso")
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer {
                try? fm.removeItem(at: stage)
                try? fm.removeItem(at: temporaryISO)
            }
            try Data("instance-id: \(vmID.description)-manual-dns-\(version)\n".utf8)
                .write(to: stage.appendingPathComponent("meta-data"), options: .atomic)
            try Data(userData(script: script).utf8)
                .write(to: stage.appendingPathComponent("user-data"), options: .atomic)
            let process = Process()
            process.executableURL = utility
            process.arguments = ["makehybrid", "-iso", "-joliet", "-iso-volume-name", "cidata",
                                 "-joliet-volume-name", "cidata", "-o", temporaryISO.path, stage.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, fm.fileExists(atPath: temporaryISO.path) else {
                throw LinuxGuestSeedError.creationFailed
            }
            // The VM is stopped while this runs. Keep the old image until its replacement exists.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporaryISO, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try Data(version.utf8).write(to: marker, options: .atomic)
            return destination
        }.value
    }

    static func userData(script: String) -> String {
        let encodedScript = Data(script.utf8).base64EncodedString()
        return """
        #cloud-config
        users: []
        write_files:
          - path: /usr/local/lib/tether/dns-fallback.sh
            owner: root:root
            permissions: '0755'
            encoding: b64
            content: \(encodedScript)
          - path: /etc/systemd/system/tether-dns-fallback.service
            owner: root:root
            permissions: '0644'
            content: |
              [Unit]
              Description=Tether guest DNS fallback when NAT DNS is unavailable
              Wants=network-online.target
              After=network-online.target systemd-resolved.service

              [Service]
              Type=oneshot
              ExecStart=/usr/local/lib/tether/dns-fallback.sh
              TimeoutStartSec=150

              [Install]
              WantedBy=multi-user.target
          - path: /etc/systemd/system/tether-dns-fallback.timer
            owner: root:root
            permissions: '0644'
            content: |
              [Unit]
              Description=Recheck Tether guest DNS during Ubuntu installation

              [Timer]
              OnBootSec=30s
              OnUnitInactiveSec=30s
              Unit=tether-dns-fallback.service

              [Install]
              WantedBy=timers.target
          - path: /etc/NetworkManager/dispatcher.d/90-tether-dns-fallback
            owner: root:root
            permissions: '0755'
            content: |
              #!/bin/sh
              case "$1:$2" in
                en*:up|en*:dhcp4-change|en*:reapply|:dns-change)
                  systemctl --no-block start tether-dns-fallback.service >/dev/null 2>&1 || true
                  ;;
              esac
        runcmd:
          - [systemctl, daemon-reload]
          - [systemctl, enable, --now, tether-dns-fallback.service]
          - [systemctl, enable, --now, tether-dns-fallback.timer]
          - [sh, -c, "if timeout 5 getent ahostsv4 ports.ubuntu.com >/dev/null 2>&1; then if [ -c /dev/hvc0 ]; then echo TETHER_MANUAL_DNS_READY > /dev/hvc0; fi; else if [ -c /dev/hvc0 ]; then echo TETHER_MANUAL_DNS_FAILED > /dev/hvc0; fi; exit 1; fi"]
        """
    }
}
