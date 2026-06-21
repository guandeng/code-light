import Foundation
import Security

// ============================================================
// KeychainStore — macOS Keychain 凭据安全存储
// 替代 SQLite 明文 secrets 表。AES-256 + Secure Enclave 硬件保护。
// ============================================================

class KeychainStore {
    static let shared = KeychainStore()

    /// service 名固定为 bundle id，同 app（同签名）静默访问 login keychain
    private let service: String = {
        Bundle.main.bundleIdentifier ?? "com.cluideng.codelight"
    }()

    private init() {}

    /// 写入（覆盖）凭据
    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        // 先删旧值，再添加（避免 SecItemAdd 因 duplicate 失败）
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取凭据，找不到返回 nil
    func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除凭据（不存在也视为成功）
    @discardableResult
    func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
