import Foundation

// MARK: - Data Models

enum SkillsError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let s): return s }
    }
}

enum SkillType: String { case skill, command }
enum SkillSource { case local, remote }

struct SkillItem {
    let name: String
    let description: String
    let type: SkillType
    let source: SkillSource
    let localPath: String?
    let downloadURL: String?
    let repoOwner: String?
    let repoName: String?
    let remotePath: String?
    var isInstalled: Bool = false
}

// MARK: - SkillsManager (local scanning + install/uninstall)

class SkillsManager {
    static let shared = SkillsManager()
    private let fm = FileManager.default

    var skillsDir: String { NSHomeDirectory() + "/.claude/skills" }
    var commandsDir: String { NSHomeDirectory() + "/.claude/commands" }
    var pluginsDir: String { NSHomeDirectory() + "/.claude/plugins/marketplaces" }

    // MARK: Local Scanning

    func scanLocalSkills() -> [SkillItem] {
        var items: [SkillItem] = []
        let skillsPath = skillsDir
        guard let contents = try? fm.contentsOfDirectory(atPath: skillsPath) else { return items }

        for entry in contents {
            let fullPath = (skillsPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            if isDir.boolValue {
                // 子目录模式: name/SKILL.md
                let skillFile = (fullPath as NSString).appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: skillFile),
                   let content = try? String(contentsOfFile: skillFile, encoding: .utf8) {
                    let meta = parseFrontmatter(from: content)
                    items.append(SkillItem(
                        name: meta.name.isEmpty ? entry : meta.name,
                        description: meta.description,
                        type: .skill, source: .local,
                        localPath: skillFile, downloadURL: nil,
                        repoOwner: nil, repoName: nil, remotePath: nil
                    ))
                }
            } else if entry.hasSuffix(".md") {
                // 平铺模式: name.md
                let name = (entry as NSString).deletingPathExtension
                guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
                let meta = parseFrontmatter(from: content)
                items.append(SkillItem(
                    name: meta.name.isEmpty ? name : meta.name,
                    description: meta.description,
                    type: .skill, source: .local,
                    localPath: fullPath, downloadURL: nil,
                    repoOwner: nil, repoName: nil, remotePath: nil
                ))
            }
        }
        return items
    }

    func scanLocalCommands() -> [SkillItem] {
        var items: [SkillItem] = []
        let cmdPath = commandsDir
        guard let contents = try? fm.contentsOfDirectory(atPath: cmdPath) else { return items }

        for entry in contents where entry.hasSuffix(".md") {
            let name = (entry as NSString).deletingPathExtension
            let fullPath = (cmdPath as NSString).appendingPathComponent(entry)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let meta = parseFrontmatter(from: content)
            items.append(SkillItem(
                name: meta.name.isEmpty ? name : meta.name,
                description: meta.description,
                type: .command, source: .local,
                localPath: fullPath, downloadURL: nil,
                repoOwner: nil, repoName: nil, remotePath: nil
            ))
        }
        return items
    }

    // MARK: Plugin Scanning

    func scanPlugins() -> [SkillItem] {
        var items: [SkillItem] = []
        let pluginsPath = pluginsDir
        guard let pluginDirs = try? fm.contentsOfDirectory(atPath: pluginsPath) else { return items }

        for pluginEntry in pluginDirs {
            let pluginPath = (pluginsPath as NSString).appendingPathComponent(pluginEntry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: pluginPath, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            // 读取 plugin.json 获取命名空间
            let pluginJsonPath = (pluginPath as NSString).appendingPathComponent("plugin.json")
            var namespace = pluginEntry
            if let data = fm.contents(atPath: pluginJsonPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                namespace = name
            }

            // 扫描 commands/*.md
            let commandsPath = (pluginPath as NSString).appendingPathComponent("commands")
            if let cmdFiles = try? fm.contentsOfDirectory(atPath: commandsPath) {
                for file in cmdFiles where file.hasSuffix(".md") {
                    let cmdName = (file as NSString).deletingPathExtension
                    let fullPath = (commandsPath as NSString).appendingPathComponent(file)
                    guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
                    let meta = parseFrontmatter(from: content)
                    items.append(SkillItem(
                        name: "\(namespace):\(cmdName)",
                        description: meta.description,
                        type: .command, source: .local,
                        localPath: fullPath, downloadURL: nil,
                        repoOwner: nil, repoName: nil, remotePath: nil
                    ))
                }
            }

            // 扫描 skills/*/SKILL.md
            let skillsPath = (pluginPath as NSString).appendingPathComponent("skills")
            if let skillDirs = try? fm.contentsOfDirectory(atPath: skillsPath) {
                for skillEntry in skillDirs {
                    let skillDirPath = (skillsPath as NSString).appendingPathComponent(skillEntry)
                    var isSkillDir: ObjCBool = false
                    fm.fileExists(atPath: skillDirPath, isDirectory: &isSkillDir)
                    guard isSkillDir.boolValue else { continue }

                    let skillFile = (skillDirPath as NSString).appendingPathComponent("SKILL.md")
                    if fm.fileExists(atPath: skillFile),
                       let content = try? String(contentsOfFile: skillFile, encoding: .utf8) {
                        let meta = parseFrontmatter(from: content)
                        items.append(SkillItem(
                            name: "\(namespace):\(meta.name.isEmpty ? skillEntry : meta.name)",
                            description: meta.description,
                            type: .skill, source: .local,
                            localPath: skillFile, downloadURL: nil,
                            repoOwner: nil, repoName: nil, remotePath: nil
                        ))
                    }
                }
            }
        }
        return items
    }

    func scanAll() -> [SkillItem] {
        return scanLocalSkills() + scanLocalCommands() + scanPlugins()
    }

    // MARK: Install / Uninstall

    func installSkill(_ remote: SkillItem, content: String) -> Bool {
        let dir: String
        let filePath: String

        if remote.type == .command {
            dir = commandsDir
            filePath = (dir as NSString).appendingPathComponent("\(remote.name).md")
        } else {
            dir = (skillsDir as NSString).appendingPathComponent(remote.name)
            filePath = (dir as NSString).appendingPathComponent("SKILL.md")
        }

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func uninstall(_ item: SkillItem) -> Bool {
        guard let path = item.localPath else { return false }
        do {
            if item.type == .skill {
                // 子目录模式时删除整个目录
                let dir = (path as NSString).deletingLastPathComponent
                let parentDir = (skillsDir as NSString).lastPathComponent
                if (dir as NSString).lastPathComponent == parentDir {
                    // 平铺 .md 文件，直接删文件
                    try fm.removeItem(atPath: path)
                } else {
                    // 子目录模式，删整个子目录
                    try fm.removeItem(atPath: dir)
                }
            } else {
                try fm.removeItem(atPath: path)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Frontmatter Parsing

    func parseFrontmatter(from markdown: String) -> (name: String, description: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            // 无 frontmatter，从标题或首段提取
            return extractFromContent(markdown)
        }

        // 找到第二个 ---
        var endIdx = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIdx = i
                break
            }
        }
        if endIdx < 0 { return extractFromContent(markdown) }

        var name = ""
        var description = ""

        for i in 1..<endIdx {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = trimmed.replacingOccurrences(of: "^name:\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
            } else if trimmed.hasPrefix("description:") {
                let desc = trimmed.replacingOccurrences(of: "^description:\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                // 处理多行描述的起始
                if desc.hasPrefix("|-") || desc.hasPrefix("|") || desc.isEmpty {
                    // 多行描述，收集后续缩进行
                    var multiLines: [String] = []
                    for j in i+1..<endIdx {
                        let sub = lines[j]
                        if sub.hasPrefix("  ") || sub.hasPrefix("\t") {
                            multiLines.append(sub.trimmingCharacters(in: .whitespaces))
                        } else { break }
                    }
                    description = multiLines.joined(separator: " ")
                } else {
                    description = desc
                        .replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
                }
            }
        }

        // 如果 description 为空，尝试从内容部分提取
        if description.isEmpty {
            let contentStart = endIdx + 1
            if contentStart < lines.count {
                let contentLines = lines[contentStart...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let first = contentLines.first {
                    description = first
                        .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return (name, String(description.prefix(120)))
    }

    private func extractFromContent(_ markdown: String) -> (name: String, description: String) {
        let lines = markdown.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return ("", "") }
        let desc = first.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return ("", String(desc.prefix(120)))
    }

    /// 检查本地是否已安装某个 skill（按名称匹配）
    func isInstalled(name: String, type: SkillType) -> Bool {
        if type == .command {
            let path = (commandsDir as NSString).appendingPathComponent("\(name).md")
            return fm.fileExists(atPath: path)
        } else {
            // 检查平铺或子目录两种模式
            let flatPath = (skillsDir as NSString).appendingPathComponent("\(name).md")
            let dirPath = (skillsDir as NSString).appendingPathComponent(name)
            let skillPath = (dirPath as NSString).appendingPathComponent("SKILL.md")
            return fm.fileExists(atPath: flatPath) || fm.fileExists(atPath: skillPath)
        }
    }
}

// MARK: - SkillsGitHubClient (remote discovery)

class SkillsGitHubClient {
    static let shared = SkillsGitHubClient()
    private let session: URLSession
    private var cachedCatalog: [SkillItem]?
    private var lastFetchTime: Date?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: Fetch Catalog

    func fetchCatalog(owner: String, repo: String, path: String,
                      completion: @escaping (Result<[SkillItem], SkillsError>) -> Void) {
        // 使用缓存（5 分钟过期）
        if let cached = cachedCatalog, let last = lastFetchTime,
           Date().timeIntervalSince(last) < 300 {
            completion(.success(cached))
            return
        }

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)"
        guard let url = URL(string: urlString) else {
            completion(.failure(.message("无效的仓库地址")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodeLight/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.message("网络错误: \(error.localizedDescription)"))) }
                return
            }

            guard let httpResp = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.message("无效响应"))) }
                return
            }

            if httpResp.statusCode == 403 {
                DispatchQueue.main.async { completion(.failure(.message("GitHub API 速率限制，请稍后重试"))) }
                return
            }

            guard httpResp.statusCode == 200, let data = data else {
                DispatchQueue.main.async { completion(.failure(.message("HTTP \(httpResp.statusCode)"))) }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion(.failure(.message("解析目录列表失败"))) }
                return
            }

            var items: [SkillItem] = []
            for entry in json {
                guard let name = entry["name"] as? String,
                      let type = entry["type"] as? String else { continue }

                if type == "dir" {
                    let remotePath = entry["path"] as? String ?? "\(path)/\(name)"
                    let htmlUrl = entry["html_url"] as? String
                    items.append(SkillItem(
                        name: name,
                        description: "加载中...",
                        type: .skill, source: .remote,
                        localPath: nil,
                        downloadURL: htmlUrl,
                        repoOwner: owner, repoName: repo,
                        remotePath: remotePath
                    ))
                }
            }

            // 缓存
            self?.cachedCatalog = items
            self?.lastFetchTime = Date()
            DispatchQueue.main.async { completion(.success(items)) }
        }.resume()
    }

    // MARK: Fetch Skill Details (SKILL.md content)

    func fetchSkillDetail(_ item: SkillItem, completion: @escaping (Result<(String, SkillItem), SkillsError>) -> Void) {
        guard let owner = item.repoOwner, let repo = item.repoName,
              let remotePath = item.remotePath else {
            completion(.failure(.message("缺少仓库信息")))
            return
        }

        // 尝试获取 SKILL.md
        let skillPath = remotePath.hasSuffix("/SKILL.md") ? remotePath : "\(remotePath)/SKILL.md"
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(skillPath)"
        guard let url = URL(string: urlString) else {
            completion(.failure(.message("无效的文件路径")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodeLight/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.message(error.localizedDescription))) }
                return
            }

            guard let httpResp = response as? HTTPURLResponse,
                  httpResp.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let downloadURL = json["download_url"] as? String else {
                // 可能不是子目录模式，尝试平铺的 .md 文件
                DispatchQueue.main.async {
                    // 回退：使用名称.md
                    self.fetchFlatSkillContent(owner: owner, repo: repo,
                                               path: remotePath, name: item.name,
                                               original: item, completion: completion)
                }
                return
            }

            // 下载实际内容
            self.downloadContent(downloadURL: downloadURL) { result in
                switch result {
                case .success(let content):
                    let meta = SkillsManager.shared.parseFrontmatter(from: content)
                    let updated = SkillItem(
                        name: meta.name.isEmpty ? item.name : meta.name,
                        description: meta.description,
                        type: item.type, source: .remote,
                        localPath: nil, downloadURL: downloadURL,
                        repoOwner: owner, repoName: repo,
                        remotePath: remotePath
                    )
                    DispatchQueue.main.async { completion(.success((content, updated))) }
                case .failure(let err):
                    DispatchQueue.main.async { completion(.failure(err)) }
                }
            }
        }.resume()
    }

    private func fetchFlatSkillContent(owner: String, repo: String, path: String,
                                       name: String, original: SkillItem,
                                       completion: @escaping (Result<(String, SkillItem), SkillsError>) -> Void) {
        // 尝试 path.md 或 path/name.md
        let candidates = [
            "\(path).md",
            "\(path)/\(name).md",
            "\(path)/SKILL.md"
        ]

        func tryCandidate(_ index: Int) {
            guard index < candidates.count else {
                completion(.success(("", original)))  // 无法获取内容，返回空
                return
            }

            let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(candidates[index])"
            guard let url = URL(string: urlString) else { tryCandidate(index + 1); return }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("CodeLight/1.0", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: request) { data, response, error in
                guard let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let downloadURL = json["download_url"] as? String else {
                    tryCandidate(index + 1)
                    return
                }

                self.downloadContent(downloadURL: downloadURL) { result in
                    switch result {
                    case .success(let content):
                        let meta = SkillsManager.shared.parseFrontmatter(from: content)
                        let updated = SkillItem(
                            name: meta.name.isEmpty ? name : meta.name,
                            description: meta.description,
                            type: original.type, source: .remote,
                            localPath: nil, downloadURL: downloadURL,
                            repoOwner: owner, repoName: repo,
                            remotePath: path
                        )
                        DispatchQueue.main.async { completion(.success((content, updated))) }
                    case .failure:
                        tryCandidate(index + 1)
                    }
                }
            }.resume()
        }

        tryCandidate(0)
    }

    // MARK: Download Raw Content

    func downloadContent(downloadURL: String, completion: @escaping (Result<String, SkillsError>) -> Void) {
        guard let url = URL(string: downloadURL) else {
            completion(.failure(.message("无效的下载地址")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("CodeLight/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.message(error.localizedDescription))) }
                return
            }
            guard let data = data,
                  let content = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(.failure(.message("下载内容失败"))) }
                return
            }
            DispatchQueue.main.async { completion(.success(content)) }
        }.resume()
    }

    /// 使缓存失效
    func invalidateCache() {
        cachedCatalog = nil
        lastFetchTime = nil
    }
}
