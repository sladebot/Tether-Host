import Foundation
import Darwin

public enum FirewallPolicyGenerator {
    public static func generate(_ request: HostFirewallRequest) throws -> HostFirewallPlan {
        guard request.policyRevision == HostFirewallRequest.supportedPolicyRevision else {
            throw FirewallRequestError.unsupportedRevision
        }
        guard request.guestAddresses.contains(where: { $0.family == .ipv4 }) else {
            throw FirewallRequestError.missingAddressFamily(.ipv4)
        }
        guard request.guestAddresses.contains(where: { $0.family == .ipv6 }) else {
            throw FirewallRequestError.missingAddressFamily(.ipv6)
        }
        for address in request.guestAddresses {
            try validate(address)
            guard isPrivateGuestAddress(address) else {
                throw FirewallRequestError.invalidAddress(address.value)
            }
        }

        var uniqueAllowances = Set<EgressAllowance>()
        for allowance in request.egressAllowances {
            guard allowance.port > 0 else { throw FirewallRequestError.invalidPort }
            try validate(allowance.destination)
            guard isPublicUnicast(allowance.destination) else {
                throw FirewallRequestError.forbiddenDestination(allowance.destination.value)
            }
            guard uniqueAllowances.insert(allowance).inserted else {
                throw FirewallRequestError.duplicateAllowance
            }
        }

        var rules: [FirewallRule] = []
        for source in request.guestAddresses.sorted(by: addressSort) {
            let matching = request.egressAllowances
                .filter { $0.destination.family == source.family }
                .sorted(by: allowanceSort)
            for allowance in matching {
                rules.append(FirewallRule(
                    action: .pass,
                    family: source.family,
                    source: source,
                    destination: allowance.destination,
                    transport: allowance.transport,
                    port: allowance.port
                ))
            }
            rules.append(FirewallRule(
                action: .block,
                family: source.family,
                source: source,
                destination: nil,
                transport: nil,
                port: nil
            ))
        }
        return HostFirewallPlan(
            installationID: request.installationID,
            virtualMachineID: request.virtualMachineID,
            policyRevision: request.policyRevision,
            rules: rules
        )
    }

    /// Produces deterministic review text only. Applying it belongs to an authenticated helper.
    public static func reviewText(_ plan: HostFirewallPlan) -> String {
        plan.rules.map { rule in
            let family = rule.family == .ipv4 ? "inet" : "inet6"
            if let destination = rule.destination, let transport = rule.transport, let port = rule.port {
                return "pass out quick \(family) proto \(transport.rawValue) from \(rule.source.value) to \(destination.value) port \(port)"
            }
            return "block drop out quick \(family) from \(rule.source.value) to any"
        }.joined(separator: "\n")
    }

    private static func validate(_ address: NetworkAddress) throws {
        var storage = in6_addr()
        let expectedFamily = address.family == .ipv4 ? AF_INET : AF_INET6
        let result = address.value.withCString { pointer in
            withUnsafeMutablePointer(to: &storage) { inet_pton(expectedFamily, pointer, $0) }
        }
        guard result == 1 else { throw FirewallRequestError.invalidAddress(address.value) }
        let containsColon = address.value.contains(":")
        guard (address.family == .ipv6) == containsColon else {
            throw FirewallRequestError.mismatchedAddressFamily(address.value)
        }
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        var value = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1 else { return nil }
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private static func isPrivateGuestAddress(_ address: NetworkAddress) -> Bool {
        switch address.family {
        case .ipv4:
            guard let b = ipv4Bytes(address.value) else { return false }
            return b[0] == 10
                || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168)
        case .ipv6:
            guard let b = ipv6Bytes(address.value) else { return false }
            return b[0] & 0xfe == 0xfc
        }
    }

    private static func isPublicUnicast(_ address: NetworkAddress) -> Bool {
        switch address.family {
        case .ipv4:
            guard let b = ipv4Bytes(address.value) else { return false }
            if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
            if b[0] == 100 && (64...127).contains(b[1]) { return false }
            if b[0] == 169 && b[1] == 254 { return false }
            if b[0] == 172 && (16...31).contains(b[1]) { return false }
            if b[0] == 192 && b[1] == 168 { return false }
            return true
        case .ipv6:
            guard let b = ipv6Bytes(address.value) else { return false }
            if b.allSatisfy({ $0 == 0 }) || (b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1) { return false }
            if b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] == 0xff { return false }
            return true
        }
    }

    private static func addressSort(_ lhs: NetworkAddress, _ rhs: NetworkAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family.rawValue < rhs.family.rawValue }
        return lhs.value < rhs.value
    }

    private static func allowanceSort(_ lhs: EgressAllowance, _ rhs: EgressAllowance) -> Bool {
        if lhs.destination.value != rhs.destination.value { return lhs.destination.value < rhs.destination.value }
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        return lhs.transport.rawValue < rhs.transport.rawValue
    }
}
