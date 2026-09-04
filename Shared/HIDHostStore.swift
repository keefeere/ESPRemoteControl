import Foundation

struct SavedHIDHost: Codable, Identifiable, Equatable {
    let id: UUID
    var discoveredName: String?
    var customName: String?
    var supportsOutgoingConnection = false
    var lastConnectedAt: Date?

    var name: String {
        customName ?? discoveredName ?? "Комп’ютер · \(id.uuidString.prefix(8))"
    }
}

/// App-local host selection, not the system Bluetooth bond database. The Share
/// extension intentionally uses a separate defaults container and host key.
final class HIDHostStore {
    private struct Snapshot: Codable {
        var hosts: [SavedHIDHost] = []
        var selectedHostID: UUID?
        var hasManagedHosts = false
    }

    private let defaults: UserDefaults
    private let hostKey: String
    private let registryKey: String
    private var snapshot: Snapshot

    var hosts: [SavedHIDHost] { snapshot.hosts }
    var selectedHostID: UUID? { snapshot.selectedHostID }
    var shouldPairOnStart: Bool { !snapshot.hasManagedHosts && selectedHostID == nil }

    init(defaults: UserDefaults = .standard, hostKey: String = "directHID.selectedHost") {
        self.defaults = defaults
        self.hostKey = hostKey
        registryKey = hostKey + ".registry"
        if let data = defaults.data(forKey: registryKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
            // A damaged registry must not silently reopen pairing to any host.
            snapshot.hasManagedHosts = defaults.object(forKey: registryKey) != nil
            let selected = defaults.string(forKey: hostKey).flatMap(UUID.init(uuidString:))
            let outgoing = defaults.string(forKey: "directHID.outgoingHost").flatMap(UUID.init(uuidString:))
            for id in Set([selected, outgoing].compactMap { $0 }) {
                snapshot.hosts.append(SavedHIDHost(
                    id: id,
                    discoveredName: id == outgoing ? Self.clean(defaults.string(forKey: "directHID.outgoingHostName")) : nil,
                    supportsOutgoingConnection: id == outgoing
                ))
            }
            snapshot.selectedHostID = selected
            snapshot.hasManagedHosts = snapshot.hasManagedHosts || !snapshot.hosts.isEmpty
            persist()
        }
    }

    func host(_ id: UUID) -> SavedHIDHost? { hosts.first { $0.id == id } }

    func select(_ id: UUID, name: String?, supportsOutgoing: Bool) {
        if let index = snapshot.hosts.firstIndex(where: { $0.id == id }) {
            if let name = Self.clean(name) { snapshot.hosts[index].discoveredName = name }
            snapshot.hosts[index].supportsOutgoingConnection = snapshot.hosts[index].supportsOutgoingConnection || supportsOutgoing
        } else {
            snapshot.hosts.append(SavedHIDHost(id: id, discoveredName: Self.clean(name), supportsOutgoingConnection: supportsOutgoing))
        }
        snapshot.selectedHostID = id
        snapshot.hasManagedHosts = true
        persist()
    }

    func connected(_ id: UUID, name: String?, supportsOutgoing: Bool) {
        select(id, name: name, supportsOutgoing: supportsOutgoing)
        if let index = snapshot.hosts.firstIndex(where: { $0.id == id }) {
            snapshot.hosts[index].lastConnectedAt = Date()
        }
        persist()
    }

    func updateDiscoveredName(_ name: String, for id: UUID) {
        guard let name = Self.clean(name), let index = snapshot.hosts.firstIndex(where: { $0.id == id }),
              snapshot.hosts[index].discoveredName != name else { return }
        snapshot.hosts[index].discoveredName = name
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = snapshot.hosts.firstIndex(where: { $0.id == id }) else { return }
        snapshot.hosts[index].customName = Self.clean(name)
        persist()
    }

    func forget(_ id: UUID) {
        snapshot.hosts.removeAll { $0.id == id }
        if selectedHostID == id { snapshot.selectedHostID = nil }
        snapshot.hasManagedHosts = true
        if defaults.string(forKey: "directHID.outgoingHost") == id.uuidString {
            defaults.removeObject(forKey: "directHID.outgoingHost")
            defaults.removeObject(forKey: "directHID.outgoingHostName")
        }
        persist()
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: registryKey) }
        if let selectedHostID { defaults.set(selectedHostID.uuidString, forKey: hostKey) }
        else { defaults.removeObject(forKey: hostKey) }
    }
}

/// Serializes asynchronous advertising requests. In particular, two unsubscribe
/// callbacks must not issue two starts before the first start completes.
struct HIDAdvertisingState {
    enum Action: Equatable { case start, stop }
    private enum Phase { case idle, starting, advertising }
    private var phase = Phase.idle
    private var wanted = false

    init(isAdvertising: Bool = false) {
        phase = isAdvertising ? .advertising : .idle
    }

    mutating func update(wanted: Bool) -> Action? {
        self.wanted = wanted
        switch phase {
        case .idle where wanted:
            phase = .starting
            return .start
        case .advertising where !wanted:
            phase = .idle
            return .stop
        default:
            return nil
        }
    }

    mutating func didStart(succeeded: Bool) -> Action? {
        phase = succeeded ? .advertising : .idle
        // Do not retry a failed request in a tight loop. A later explicit
        // reconnect or Bluetooth state/subscription change can retry it.
        guard succeeded else { return nil }
        return update(wanted: wanted)
    }
}
