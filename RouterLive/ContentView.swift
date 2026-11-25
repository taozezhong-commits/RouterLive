//
//  ContentView.swift
//  路由器实时监控 · 最小可编译界面
//  数据层：RouterAPI.swift（来自 RouterLive.js 的移植）
//

import SwiftUI
import Combine
import Foundation

// MARK: - 视图模型

final class RouterViewModel: ObservableObject {
    @Published var snapshot: RouterSnapshot?
    @Published var errorMessage: String?
    @Published var debugText = ""
    @Published var isRunning = false

    private var provider: RouterLiveDataProvider?

    func start(host: String, password: String) {
        stop()
        let cfg = RouterConfig(host: host, password: password)
        let p = RouterLiveDataProvider(config: cfg)
        p.onData = { [weak self, weak p] snap in
            DispatchQueue.main.async {
                self?.snapshot = snap
                self?.errorMessage = nil
                self?.debugText = p?.debugLog ?? ""
            }
        }
        p.onError = { [weak self, weak p] msg in
            DispatchQueue.main.async {
                self?.errorMessage = msg
                self?.debugText = p?.debugLog ?? ""
            }
        }
        p.start()
        provider = p
        isRunning = true
    }

    func stop() {
        provider?.stop()
        provider = nil
        isRunning = false
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var vm = RouterViewModel()
    @AppStorage("router.host") private var host = "192.168.0.1"
    @AppStorage("router.password") private var password = "A12345678"

    var body: some View {
        NavigationView {
            Form {
                Section("路由器") {
                    TextField("地址", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("管理密码", text: $password)
                    HStack {
                        Button(vm.isRunning ? "停止" : "开始监控") {
                            if vm.isRunning { vm.stop() } else { vm.start(host: host, password: password) }
                        }
                        Spacer()
                        if let e = vm.errorMessage {
                            Text(e).font(.caption).foregroundColor(.red).lineLimit(2)
                        } else if vm.isRunning {
                            Text("已连接 · 1.5s 刷新").font(.caption).foregroundColor(.green)
                        }
                    }
                }

                Section("连接诊断（失败时请截图这一块）") {
                    Text("首次打开若弹出“本地网络”权限，请点允许；若已拒绝，到 iPhone 设置 → 隐私与安全性 → 本地网络 → 打开“路由器监控”。")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(vm.debugText.isEmpty ? "尚未发起请求" : vm.debugText)
                        .font(.caption2).monospacedDigit()
                        .textSelection(.enabled)
                }

                Section("WAN 实时速率") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("下载").font(.caption).foregroundColor(.secondary)
                            Text(fmt(vm.snapshot?.down ?? 0)).font(.system(size: 28, weight: .semibold))
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("上传").font(.caption).foregroundColor(.secondary)
                            Text(fmt(vm.snapshot?.up ?? 0)).font(.system(size: 28, weight: .semibold))
                        }
                    }
                    Text("单位 MB/s · 数值来自路由器后台 wan.inRates / outRates")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Section("在线设备（\(vm.snapshot?.online ?? 0)）") {
                    if let clients = vm.snapshot?.clients, !clients.isEmpty {
                        ForEach(clients, id: \.ip) { c in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(c.name)
                                    Text(c.ip).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("↓\(fmt(c.down)) ↑\(fmt(c.up))")
                                    .font(.caption).monospacedDigit()
                            }
                        }
                    } else {
                        Text("暂无设备数据").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("路由器监控")
            .onAppear { vm.start(host: host, password: password) }
            .onDisappear { vm.stop() }
        }
    }

    private func fmt(_ bytes: Double) -> String {
        String(format: "%.2f", bytes / 1024 / 1024)
    }
}
