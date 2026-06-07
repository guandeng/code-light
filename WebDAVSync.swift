import Foundation

// ============================================================
// WebDAVSync — 通过 WebDAV 同步配置
// ============================================================

class WebDAVSync {
    static let shared = WebDAVSync()

    var onSyncResult: ((Bool, String) -> Void)?

    private let session: URLSession
    private let timeout: TimeInterval = 15

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
    }

    // MARK: - Upload Config

    func uploadConfig(_ config: AppConfig, completion: @escaping (Bool, String) -> Void) {
        guard !config.webdavURL.isEmpty else {
            completion(false, "未配置 WebDAV 地址")
            return
        }

        let json = config.toJSON()
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            completion(false, "配置序列化失败")
            return
        }

        let urlStr = buildURL(config.webdavURL, path: config.webdavPath)
        guard let url = URL(string: urlStr) else {
            completion(false, "WebDAV 地址格式错误")
            return
        }

        // 先确保远程目录存在（MKCOL），再上传（PUT）
        ensureRemoteDir(urlStr, user: config.webdavUser, pass: config.webdavPass) { [weak self] success in
            guard let self = self else { return }
            if !success {
                // 目录可能已存在，继续尝试上传
            }
            self.putRequest(url: url, data: data, user: config.webdavUser, pass: config.webdavPass, completion: completion)
        }
    }

    // MARK: - Download Config

    func downloadConfig(_ config: AppConfig, completion: @escaping (Bool, String, [String: Any]?) -> Void) {
        guard !config.webdavURL.isEmpty else {
            completion(false, "未配置 WebDAV 地址", nil)
            return
        }

        let urlStr = buildURL(config.webdavURL, path: config.webdavPath)
        guard let url = URL(string: urlStr) else {
            completion(false, "WebDAV 地址格式错误", nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if !config.webdavUser.isEmpty {
            let creds = "\(config.webdavUser):\(config.webdavPass)"
            if let encoded = creds.data(using: .utf8) {
                request.setValue("Basic \(encoded.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "下载失败: \(error.localizedDescription)", nil)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false, "下载失败: 无响应", nil)
                return
            }
            if http.statusCode == 404 {
                completion(false, "远程配置不存在", nil)
                return
            }
            guard http.statusCode == 200, let data = data else {
                completion(false, "下载失败: HTTP \(http.statusCode)", nil)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, "远程配置格式错误", nil)
                return
            }
            completion(true, "下载成功", json)
        }.resume()
    }

    // MARK: - Test Connection

    func testConnection(_ config: AppConfig, completion: @escaping (Bool, String) -> Void) {
        guard !config.webdavURL.isEmpty else {
            completion(false, "未配置 WebDAV 地址")
            return
        }

        let urlStr = config.webdavURL.hasSuffix("/") ? config.webdavURL : config.webdavURL + "/"
        guard let url = URL(string: urlStr) else {
            completion(false, "地址格式错误")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 10
        request.setValue("0", forHTTPHeaderField: "Depth")
        if !config.webdavUser.isEmpty {
            let creds = "\(config.webdavUser):\(config.webdavPass)"
            if let encoded = creds.data(using: .utf8) {
                request.setValue("Basic \(encoded.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, "连接失败: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false, "连接失败: 无响应")
                return
            }
            if http.statusCode == 207 {
                completion(true, "连接成功 ✓")
            } else if http.statusCode == 401 {
                completion(false, "认证失败: 用户名或密码错误")
            } else if http.statusCode >= 200 && http.statusCode < 300 {
                completion(true, "连接成功 ✓ (HTTP \(http.statusCode))")
            } else {
                completion(false, "连接失败: HTTP \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: - Private

    private func buildURL(_ base: String, path: String) -> String {
        var url = base.hasSuffix("/") ? base : base + "/"
        // 移除路径开头的 /
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        url += cleanPath
        return url
    }

    private func ensureRemoteDir(_ fileURL: String, user: String, pass: String, completion: @escaping (Bool) -> Void) {
        // 从文件 URL 提取目录 URL
        var components = fileURL.components(separatedBy: "/")
        if !components.isEmpty {
            _ = components.removeLast() // 去掉文件名
        }
        let dirURL = components.joined(separator: "/") + "/"
        guard let url = URL(string: dirURL) else { completion(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        request.timeoutInterval = 10
        if !user.isEmpty {
            let creds = "\(user):\(pass)"
            if let encoded = creds.data(using: .utf8) {
                request.setValue("Basic \(encoded.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                // 201 = created, 405/409 = already exists — both OK
                completion(http.statusCode == 201 || http.statusCode == 405 || http.statusCode == 409)
            } else {
                completion(false)
            }
        }.resume()
    }

    private func putRequest(url: URL, data: Data, user: String, pass: String, completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !user.isEmpty {
            let creds = "\(user):\(pass)"
            if let encoded = creds.data(using: .utf8) {
                request.setValue("Basic \(encoded.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, "上传失败: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false, "上传失败: 无响应")
                return
            }
            if http.statusCode == 201 || http.statusCode == 200 || http.statusCode == 204 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                completion(true, "上传成功 (\(size))")
            } else {
                completion(false, "上传失败: HTTP \(http.statusCode)")
            }
        }.resume()
    }
}
