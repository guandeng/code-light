import Foundation
import CommonCrypto

// ============================================================
// S3 Provider 预设
// ============================================================

struct S3Provider {
    let name: String
    let endpoint: String   // 空=用户填写; 含 {region} 占位符
    let region: String     // 默认 region
    let service: String    // sig v4 service name: s3 / oss / cos / obs
    let pathStyle: Bool    // true=path-style, false=virtual-hosted
}

// ============================================================
// S3Sync — S3 兼容对象存储同步（自实现 AWS Signature V4）
// ============================================================

class S3Sync {
    static let shared = S3Sync()

    static let presets: [S3Provider] = [
        .init(name: "AWS S3",        endpoint: "",                                        region: "us-east-1",    service: "s3",  pathStyle: false),
        .init(name: "Cloudflare R2", endpoint: "<account-id>.r2.cloudflarestorage.com",   region: "auto",         service: "s3",  pathStyle: false),
        .init(name: "MinIO",         endpoint: "",                                        region: "us-east-1",    service: "s3",  pathStyle: true),
        .init(name: "Alibaba OSS",   endpoint: "oss-{region}.aliyuncs.com",               region: "cn-hangzhou",  service: "oss", pathStyle: false),
        .init(name: "Tencent COS",   endpoint: "cos.{region}.myqcloud.com",               region: "ap-guangzhou", service: "cos", pathStyle: false),
        .init(name: "Huawei OBS",    endpoint: "obs.{region}.myhuaweicloud.com",          region: "cn-north-4",   service: "obs", pathStyle: false),
        .init(name: "Custom",        endpoint: "",                                        region: "",             service: "s3",  pathStyle: true),
    ]

    private let session: URLSession
    private let timeout: TimeInterval = 15

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// 上传配置到 S3
    func uploadConfig(_ config: AppConfig, completion: @escaping (Bool, String) -> Void) {
        guard !config.s3Bucket.isEmpty, !config.s3AccessKeyID.isEmpty else {
            completion(false, "缺少 Bucket 或 Access Key ID")
            return
        }
        let json = config.toJSON()
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) else {
            completion(false, "JSON 序列化失败")
            return
        }
        guard let url = buildObjectURL(config) else {
            completion(false, "URL 构建失败")
            return
        }
        let provider = resolveProvider(config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signRequest(request: &request, method: "PUT", url: url,
                    region: config.s3Region, service: provider.service,
                    ak: config.s3AccessKeyID, sk: config.s3SecretAccessKey,
                    payload: data)
        request.httpBody = data

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, "上传失败: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 201 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                completion(true, "上传成功 (\(size))")
            } else {
                completion(false, "上传失败 (HTTP \(code))")
            }
        }.resume()
    }

    /// 从 S3 下载配置
    func downloadConfig(_ config: AppConfig, completion: @escaping (Bool, String, [String: Any]?) -> Void) {
        guard !config.s3Bucket.isEmpty else {
            completion(false, "缺少 Bucket", nil)
            return
        }
        guard let url = buildObjectURL(config) else {
            completion(false, "URL 构建失败", nil)
            return
        }
        let provider = resolveProvider(config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        signRequest(request: &request, method: "GET", url: url,
                    region: config.s3Region, service: provider.service,
                    ak: config.s3AccessKeyID, sk: config.s3SecretAccessKey,
                    payload: nil)

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "下载失败: \(error.localizedDescription)", nil)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data else {
                completion(false, "下载失败 (HTTP \(code))", nil)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, "JSON 解析失败", nil)
                return
            }
            completion(true, "下载成功", json)
        }.resume()
    }

    /// 测试 S3 连接
    func testConnection(_ config: AppConfig, completion: @escaping (Bool, String) -> Void) {
        guard !config.s3Bucket.isEmpty else {
            completion(false, "缺少 Bucket")
            return
        }
        guard let url = buildBucketURL(config) else {
            completion(false, "URL 构建失败")
            return
        }
        let provider = resolveProvider(config)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        signRequest(request: &request, method: "HEAD", url: url,
                    region: config.s3Region, service: provider.service,
                    ak: config.s3AccessKeyID, sk: config.s3SecretAccessKey,
                    payload: nil)

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, "连接失败: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                completion(true, "连接成功 ✓")
            } else if code == 403 {
                completion(false, "认证失败 (HTTP 403)")
            } else if code == 404 {
                completion(false, "Bucket 不存在 (HTTP 404)")
            } else {
                completion(false, "连接失败 (HTTP \(code))")
            }
        }.resume()
    }

    // MARK: - URL Building

    private func resolveProvider(_ config: AppConfig) -> S3Provider {
        let idx = max(0, min(config.s3ProviderPreset, S3Sync.presets.count - 1))
        return S3Sync.presets[idx]
    }

    /// 解析最终 endpoint URL（不含 bucket）
    private func resolveEndpoint(_ config: AppConfig) -> String {
        let provider = resolveProvider(config)
        var ep = config.s3Endpoint.isEmpty ? provider.endpoint : config.s3Endpoint
        if ep.isEmpty && provider.pathStyle == false && config.s3ProviderPreset == 0 {
            // AWS S3 默认
            ep = "s3.\(config.s3Region).amazonaws.com"
        }
        // 替换 {region} 占位符
        ep = ep.replacingOccurrences(of: "{region}", with: config.s3Region)
        // 确保 https://
        if !ep.isEmpty && !ep.hasPrefix("http://") && !ep.hasPrefix("https://") {
            ep = "https://\(ep)"
        }
        return ep.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 构建 object 完整 URL
    private func buildObjectURL(_ config: AppConfig) -> URL? {
        let provider = resolveProvider(config)
        let ep = resolveEndpoint(config)
        let path = config.s3RemotePath.hasPrefix("/") ? config.s3RemotePath : "/\(config.s3RemotePath)"

        if provider.pathStyle {
            // path-style: https://endpoint/bucket/path
            let urlString = "\(ep)/\(config.s3Bucket)\(path)"
            return URL(string: urlString)
        } else {
            // virtual-hosted: https://bucket.endpoint/path
            guard let epURL = URL(string: ep) else { return nil }
            var components = URLComponents(url: epURL, resolvingAgainstBaseURL: false)
            let originalHost = components?.host ?? ""
            components?.host = "\(config.s3Bucket).\(originalHost)"
            components?.path = path
            return components?.url
        }
    }

    /// 构建 bucket URL（用于 HEAD 测试）
    private func buildBucketURL(_ config: AppConfig) -> URL? {
        let provider = resolveProvider(config)
        let ep = resolveEndpoint(config)

        if provider.pathStyle {
            return URL(string: "\(ep)/\(config.s3Bucket)")
        } else {
            guard let epURL = URL(string: ep) else { return nil }
            var components = URLComponents(url: epURL, resolvingAgainstBaseURL: false)
            let originalHost = components?.host ?? ""
            components?.host = "\(config.s3Bucket).\(originalHost)"
            return components?.url
        }
    }

    // MARK: - AWS Signature V4

    private func signRequest(request: inout URLRequest, method: String, url: URL,
                             region: String, service: String,
                             ak: String, sk: String, payload: Data?) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateTimeStamp = dateFormatter.string(from: now)
        let dateStamp = String(dateTimeStamp.prefix(8))

        // Payload hash
        let payloadHash = sha256Hex(payload ?? Data())

        // Host
        let host = url.host ?? ""

        // Canonical headers (sorted alphabetically)
        var headers: [(String, String)] = [
            ("content-type", request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"),
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", dateTimeStamp),
        ]
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map { $0.0 }.joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"

        // Canonical request
        let path = url.path.isEmpty ? "/" : url.path
        let canonicalRequest = "\(method)\n\(path)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"

        // Credential scope
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        // String to sign
        let stringToSign = "AWS4-HMAC-SHA256\n\(dateTimeStamp)\n\(credentialScope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        // Signing key
        let signingKey = deriveSigningKey(secretKey: sk, date: dateStamp, region: region, service: service)

        // Signature
        let signature = hmacSHA256(signingKey, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        // Authorization header
        let authHeader = "AWS4-HMAC-SHA256 Credential=\(ak)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(dateTimeStamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    }

    private func deriveSigningKey(secretKey: String, date: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(Data("AWS4\(secretKey)".utf8), Data(date.utf8))
        let kRegion = hmacSHA256(kDate, Data(region.utf8))
        let kService = hmacSHA256(kRegion, Data(service.utf8))
        let kSigning = hmacSHA256(kService, Data("aws4_request".utf8))
        return kSigning
    }

    // MARK: - Crypto Helpers

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(_ key: Data, _ data: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyPtr.baseAddress, key.count, dataPtr.baseAddress, data.count, &hmac)
            }
        }
        return Data(hmac)
    }
}
