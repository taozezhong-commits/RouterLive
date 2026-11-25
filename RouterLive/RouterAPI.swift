//
//  RouterAPI.swift
//  路由器实时监控 · 后台接口数据层
//
//  移植来源：Scriptable 脚本 RouterLive.js（数据层 27-212 行 + 轮询 760-810 行）
//  目标固件：MW305R（securityEncode 挑战-应答鉴权，3 个数据块）
//
//  用法：
//      let provider = RouterLiveDataProvider(host: "192.168.0.1", password: "A12345678")
//      provider.onData = { snapshot in DispatchQueue.main.async { /* 更新 UI */ } }
//      provider.onError = { msg in ... }
//      provider.start()          // 立即抓一次，之后每 1.5s 轮询
//      // 页面退出时：provider.stop()
//
//  设计约束：本文件为新增独立文件，不修改 IPA 中任何现有源码，因此不影响原有功能。
//  最低要求：iOS 15+（async/await）。若工程需支持 iOS 14，把 fetch/post 改为
//            URLSession.dataTask(with:completionHandler:) 回调即可，其余逻辑不变。
//
//  ⚠ Info.plist 必须允许本地网络明文 HTTP，否则请求会被 ATS 拦截：
//      <key>NSAppTransportSecurity</key>
//      <dict><key>NSAllowsLocalNetworking</key><true/></dict>
//    （或 NSAllowsArbitraryLoads = true）
//

import Foundation

// MARK: - 对外数据模型

public struct RouterClient: Equatable, Sendable {
    public let name: String
    public let ip: String
    public let down: Double   // 字节/秒
    public let up: Double     // 字节/秒

    public init(name: String, ip: String, down: Double, up: Double) {
        self.name = name; self.ip = ip; self.down = down; self.up = up
    }
}

public struct RouterSnapshot: Sendable {
    public let down: Double            // WAN 下行 B/s（对应 wan.inRates）
    public let up: Double              // WAN 上行 B/s（对应 wan.outRates）
    public let online: Int             // 在线设备数
    public let clients: [RouterClient] // 按 IP 升序，最多 maxDevices 台

    public init(down: Double, up: Double, online: Int, clients: [RouterClient]) {
        self.down = down; self.up = up; self.online = online; self.clients = clients
    }
}

public enum RouterAPIError: Error, LocalizedError {
    case noChallenge
    case authFailed
    case blockFailed(Int)
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .noChallenge: return "未获取到路由器认证挑战"
        case .authFailed: return "路由器认证失败"
        case .blockFailed(let id): return "读取数据块 \(id) 失败"
        case .invalidHost: return "路由器地址无效"
        }
    }
}

// MARK: - 配置

public struct RouterConfig: Sendable {
    public var host: String
    public var password: String
    public var maxDevices: Int
    public var refreshSeconds: Double
    public var timeout: Double

    /// 固件认证常量（来自路由器前端脚本，与 Scriptable 主组件一致）
    public let salt = "RDpbLfCPsJZ7fiv"
    public let charset = "yLwVl0zKqws7LgKPRQ84Mdt708T1qQ3Ha7xv3H7NyU84p21BriUWBU43odz3iP4rBL3cD02KZciXTysVXiV8ngg6vL48rPJyAUw0HurW20xqxv9aYb4M9wK1Ae0wlro510qXeU07kV57fQMc8L6aLgMLwygtc0F10a0Dg70TOoouyFhdysuRMO51yY5ZlOZZLEal1h0t9YQW0Ko7oBwmCAHoic4HYbUyVeU3sfQ1xtXcPcf1aT303wAQhv66qzW"

    public init(host: String, password: String, maxDevices: Int = 12,
                refreshSeconds: Double = 1.5, timeout: Double = 8) {
        self.host = host
        self.password = password
        self.maxDevices = maxDevices
        self.refreshSeconds = refreshSeconds
        self.timeout = timeout
    }
}

// MARK: - 数据层

public final class RouterLiveDataProvider {

    public var config: RouterConfig
    public var onData: ((RouterSnapshot) -> Void)?
    public var onError: ((String) -> Void)?

    private var cachedSession: String?
    private var lastGood: RouterSnapshot?
    private var running = false
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    /// 最近请求过程，供界面显示诊断信息（不超过 2000 字符）
    public private(set) var debugLog = ""
    private func log(_ line: String) {
        debugLog = String((debugLog + line + "\n").suffix(2000))
    }

    private static let userAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1"
    private static let blockLine = try! NSRegularExpression(
        pattern: #"^([A-Za-z][A-Za-z0-9_]*)(?:\s+(\d+))?\s+(.*)$"#)

    public init(config: RouterConfig) {
        self.config = config
    }

    // MARK: 轮询控制

    /// 立即抓一次数据，随后每 refreshSeconds 秒轮询。重复调用会先停止上一次。
    public func start() {
        stop()
        lock.lock(); running = true; lock.unlock()
        let interval = config.refreshSeconds
        task = Task { [weak self] in
            guard let self else { return }
            // 首次立即抓取，避免打开页面空白
            await self.tick()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1_000_000_000))
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        task?.cancel(); task = nil
    }

    private func tick() async {
        do {
            let snap = try await fetchRouterData()
            onData?(snap)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    // MARK: 请求

    private func post(_ path: String, body: String?) async -> String {
        guard let url = URL(string: "http://" + config.host + path) else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("http://" + config.host + "/", forHTTPHeaderField: "Referer")
        if let body { req.httpBody = body.data(using: .utf8) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("POST \(path) HTTP=\(code) len=\(text.count) head=\(String(text.prefix(60)))")
            return text
        } catch {
            log("POST \(path) 网络错误: \(error.localizedDescription)")
            return ""
        }
    }

    // MARK: 鉴权算法（与 JS securityEncode 逐字符等价）

    /// - Parameters:
    ///   - a: 明文（密码 / 挑战串）
    ///   - b: 盐或已编码密码
    ///   - c: 字符集
    public static func securityEncode(_ a: String, _ b: String, _ c: String) -> String {
        // JS 的 charCodeAt/charAt 以 UTF-16 code unit 为单位。salt/charset/密码/挑战串
        // 都是 ASCII，故用 unicodeScalars 逐字符取值与其等价，且不会像 UInt8 那样溢出。
        let aa = Array(a.unicodeScalars).map { Int($0.value) }
        let bb = Array(b.unicodeScalars).map { Int($0.value) }
        let cc = Array(c)
        let f = aa.count, h = bb.count, m = cc.count
        let e = max(f, h)
        guard m > 0 else { return "" }
        var out = ""
        out.reserveCapacity(e)
        for g in 0..<e {
            var k = 187, l = 187
            if g >= f {                 // k 保持 187
                l = bb[g]
            } else if g >= h {          // l 保持 187
                k = aa[g]
            } else {
                k = aa[g]
                l = bb[g]
            }
            out.append(cc[(k ^ l) % m])
        }
        return out
    }

    private func login(force: Bool = false) async throws -> String {
        if !force, let s = cachedSession { return s }

        // 1) 取认证挑战：两行一组，第一行含非数字且长度>=6，第二行长度>20
        let challengeText = await post("?code=2&asyn=1", body: "")
        // 路由器返回 CRLF；必须用与 JS /\r?\n/ 相同的方式归一化，
        // 否则 .newlines 会把 \r\n 拆成两行（中间夹空行），相邻两行配对失败。
        let normalizedChallenge = challengeText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedChallenge.components(separatedBy: "\n")
        log("挑战响应: 行数=\(lines.count) 长度=\(challengeText.count)")
        log("挑战原文: \(String(challengeText.prefix(200)))")
        var challenge = "", key = ""
        if lines.count >= 2 {
            for i in 0..<(lines.count - 1) {
                let s = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                let next = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let hasNonDigit = s.unicodeScalars.contains { $0.value < 48 || $0.value > 57 }
                if s.count >= 6 && hasNonDigit && next.count > 20 {
                    challenge = s; key = next; break
                }
            }
        }
        log("解析结果: challenge=\(String(challenge.prefix(10))) key长度=\(key.count)")
        guard !challenge.isEmpty, !key.isEmpty else { throw RouterAPIError.noChallenge }

        // 2) 密码预编码，再与挑战做第二次编码得到 session
        let encodedPwd = Self.securityEncode(config.password, config.salt, config.charset)
        let session = Self.securityEncode(challenge, encodedPwd, key)

        // 3) 提交 session，返回必须以 "00000" 开头
        let result = await post("?code=7&asyn=0&id=" + pct(session), body: "")
        log("登录响应: \(String(result.prefix(30)))")
        guard result.hasPrefix("00000") else { throw RouterAPIError.authFailed }

        cachedSession = session
        return session
    }

    // MARK: 数据块解析

    /// 解析 "FIELD [idx] value" 文本；无索引字段存到键 0。
    private func parseBlock(_ text: String) -> [String: [Int: String]] {
        var out: [String: [Int: String]] = [:]
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = Self.blockLine.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)
            ) else { continue }
            let field = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 3))
            let ir = m.range(at: 2)
            if ir.location == NSNotFound {
                out[field, default: [:]][0] = value
            } else {
                let idx = Int(ns.substring(with: ir)) ?? 0
                out[field, default: [:]][idx] = value
            }
        }
        return out
    }

    private typealias Blocks = (wan: [String: [Int: String]],
                                sta: [String: [Int: String]],
                                dhcp: [String: [Int: String]])

    private func readBlock(_ session: String, _ id: Int) async throws -> [String: [Int: String]] {
        let text = await post("?code=2&asyn=0&id=" + pct(session), body: "id \(id)\r\n")
        log("数据块 \(id) 响应: \(String(text.prefix(30)))")
        guard text.hasPrefix("00000") else { throw RouterAPIError.blockFailed(id) }
        return parseBlock(text)
    }

    private func readAllBlocks(_ session: String) async throws -> Blocks {
        let wan = try await readBlock(session, 23)   // WAN 总上下行 B/s
        let sta = try await readBlock(session, 13)   // 每设备实时速率 B/s
        let dhcp = try await readBlock(session, 9)   // MAC -> 主机名
        return (wan, sta, dhcp)
    }

    // MARK: 汇总

    public func fetchRouterData() async throws -> RouterSnapshot {
        var blocks: Blocks?
        do {
            blocks = try await readAllBlocks(try await login())
        } catch {
            blocks = nil
        }
        if blocks == nil {
            // 读块失败多半是 session 失效：强制重登后再试一次
            cachedSession = nil
            blocks = try? await readAllBlocks(try await login(force: true))
        }
        guard let b = blocks else {
            // 仍失败则沿用上次成功数据，避免界面跳成 0
            if let last = lastGood { return last }
            throw RouterAPIError.blockFailed(-1)
        }

        let wan = b.wan, sta = b.sta, dhcp = b.dhcp

        // MAC -> 主机名（过滤空 MAC 与占位地址）
        var nameByMac: [String: String] = [:]
        if let macs = dhcp["mac"] {
            for (k, mac) in macs {
                let nm = dhcp["hostName"]?[k] ?? ""
                if !mac.isEmpty, mac != "00-00-00-00-00-00", !nm.isEmpty {
                    nameByMac[mac] = nm
                }
            }
        }

        // 设备列表：只取在线且 IP 有效的客户端
        var devices: [RouterClient] = []
        if let ips = sta["ip"] {
            for (k, ip) in ips {
                if ip.isEmpty || ip == "0.0.0.0" { continue }
                if sta["online"]?[k] != "1" { continue }
                let mac = sta["mac"]?[k] ?? ""
                let nm = sta["name"]?[k] ?? nameByMac[mac] ?? ip
                devices.append(RouterClient(
                    name: nm,
                    ip: ip,
                    down: num(sta["down"]?[k]),
                    up: num(sta["up"]?[k])
                ))
            }
        }
        // 按 IP 数值段升序，位置固定不跳动
        devices.sort { a, b in
            let x = ipNum(a.ip), y = ipNum(b.ip)
            return x != y ? x < y : a.ip < b.ip
        }

        let snap = RouterSnapshot(
            down: num(wan["inRates"]?[0]),
            up: num(wan["outRates"]?[0]),
            online: devices.count,
            clients: Array(devices.prefix(max(0, config.maxDevices)))
        )
        lastGood = snap
        return snap
    }

    // MARK: 小工具

    private func num(_ s: String?) -> Double {
        guard let s else { return 0 }
        let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        return v?.isFinite == true ? v! : 0
    }

    private func ipNum(_ ip: String) -> UInt64 {
        let p = ip.split(separator: ".", omittingEmptySubsequences: false)
        var v: UInt64 = 0
        for i in 0..<4 {
            let n = i < p.count ? UInt64(p[i]) ?? 0 : 0
            v = v * 256 + n
        }
        return v
    }

    private func pct(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
