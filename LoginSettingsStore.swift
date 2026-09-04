import Foundation
import Security

struct SynologyLoginSettings: Equatable {
    let lastServer: String
    let lastAccount: String
    let savedServers: [String]
}

struct SynologyLoginSettingsStore {
    static let defaultServerURLString = "https://nas.carlzhang.ltd:52268/"

    private let defaults = UserDefaults.standard
    private let lastServerKey = "synology.lastServerURL"
    private let lastAccountKey = "synology.lastAccount"
    private let savedServersKey = "synology.savedServers"

    func load() -> SynologyLoginSettings {
        SynologyLoginSettings(
            lastServer: defaults.string(forKey: lastServerKey) ?? "",
            lastAccount: defaults.string(forKey: lastAccountKey) ?? "",
            savedServers: defaults.stringArray(forKey: savedServersKey) ?? []
        )
    }

    func save(serverURLString: String, account: String, password: String, deviceID: String?) {
        let normalizedServer = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServer.isEmpty, !normalizedAccount.isEmpty else {
            return
        }

        defaults.set(normalizedServer, forKey: lastServerKey)
        defaults.set(normalizedAccount, forKey: lastAccountKey)

        var servers = defaults.stringArray(forKey: savedServersKey) ?? []
        servers.removeAll { $0 == normalizedServer }
        servers.insert(normalizedServer, at: 0)
        defaults.set(Array(servers.prefix(8)), forKey: savedServersKey)

        KeychainStore.save(password, service: passwordService(serverURLString: normalizedServer), account: normalizedAccount)

        if let deviceID, !deviceID.isEmpty {
            KeychainStore.save(deviceID, service: deviceIDService(serverURLString: normalizedServer), account: normalizedAccount)
        }
    }

    func loadPassword(serverURLString: String, account: String) -> String? {
        readSecret(serverURLString: serverURLString, account: account, serviceBuilder: passwordService)
    }

    func loadDeviceID(serverURLString: String, account: String) -> String? {
        readSecret(serverURLString: serverURLString, account: account, serviceBuilder: deviceIDService)
    }

    private func readSecret(
        serverURLString: String,
        account: String,
        serviceBuilder: (String) -> String
    ) -> String? {
        let normalizedServer = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServer.isEmpty, !normalizedAccount.isEmpty else {
            return nil
        }

        return KeychainStore.read(service: serviceBuilder(normalizedServer), account: normalizedAccount)
    }

    private func passwordService(serverURLString: String) -> String {
        "SynologyView.password.\(serverURLString)"
    }

    private func deviceIDService(serverURLString: String) -> String {
        "SynologyView.deviceID.\(serverURLString)"
    }
}

enum KeychainStore {
    static func save(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else {
            return
        }

        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
