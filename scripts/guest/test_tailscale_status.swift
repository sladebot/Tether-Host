import Foundation

@main
enum TailscaleStatusTests {
    static func main() {
        func check(_ json: String, connected: Bool, name: String? = nil) {
            let result = TetherGuestInstaller.parseTailnetStatus(Data(json.utf8))
            precondition(result.connected == connected, "Unexpected connection state: \(json)")
            precondition(result.name == name, "Unexpected tailnet name: \(json)")
        }

        check(#"{"BackendState":"Running","Self":{"DNSName":"tether-vm.tailnet.ts.net."}}"#,
              connected: true, name: "tether-vm.tailnet.ts.net")
        check(#"{"BackendState":"NeedsLogin","Self":{"DNSName":"tether-vm.tailnet.ts.net."}}"#,
              connected: false)
        check(#"{"BackendState":"Running","Self":{"DNSName":"tether-vm.example.com."}}"#,
              connected: false)
        check(#"{"BackendState":"Running","Self":{}}"#, connected: false)
        check("not json", connected: false)
        print("Tailscale status tests passed")
    }
}
