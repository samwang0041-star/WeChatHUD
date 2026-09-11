import SwiftUI
import AppKit

/// A deliberately narrow, user-shareable diagnostics snapshot. It contains
/// environment and aggregate state only; account identifiers, paths, keys,
/// provider endpoints and message text never enter the copied payload.
struct SupportDiagnosticsView: View {
    @EnvironmentObject private var store: HUDStore
    @EnvironmentObject private var monitor: ChatMonitor
    @State private var copyFeedback: String?

    var body: some View {
        SettingsSection("诊断概况") {
            SettingsRow("版本") { Text(version).font(.system(size: 12)).foregroundColor(.secondary) }
            SettingsRowDivider()
            SettingsRow("macOS") { Text(macOSVersion).font(.system(size: 12)).foregroundColor(.secondary) }
            SettingsRowDivider()
            SettingsRow("架构") { Text(architecture).font(.system(size: 12)).foregroundColor(.secondary) }
            SettingsRowDivider()
            SettingsRow("同步状态", subtitle: lastSyncText, icon: "arrow.triangle.2.circlepath", iconColor: syncColor) {
                Text(syncLabel).font(.system(size: 12)).foregroundColor(.secondary)
            }
            SettingsRowDivider()
            SettingsRow("汇总数量", subtitle: countSummary, icon: "number", iconColor: .secondary) {
                Text("仅统计").font(.system(size: 12)).foregroundColor(.secondary)
            }
            SettingsRowDivider()
            SettingsRow("密钥文件") {
                Text(keyState).font(.system(size: 12)).foregroundColor(keyColor)
            }
            SettingsRowDivider()
            SettingsRow("AI 服务") {
                Text(aiProviderLabel).font(.system(size: 12)).foregroundColor(.secondary)
            }
            SettingsRowDivider()
            HStack {
                Button("复制诊断概况", action: copySummary)
                if let copyFeedback {
                    Text(copyFeedback)
                        .font(.system(size: 12))
                        .foregroundColor(copyFeedback == "已复制" ? .secondary : .red)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    private var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var syncLabel: String {
        switch monitor.stats.syncStatus {
        case .idle: return "等待首次同步"
        case .syncing: return "同步中"
        case .ok: return "正常"
        case .stale: return "延迟"
        case .waitingForWeChat: return "等待微信"
        case .accountSwitched: return "数据目录失效"
        case .error: return "异常"
        }
    }

    private var syncColor: Color {
        switch monitor.stats.syncStatus {
        case .ok: return .green
        case .error, .accountSwitched: return .red
        default: return .orange
        }
    }

    private var lastSyncText: String {
        guard let date = monitor.stats.lastSyncAt else { return "最近成功同步：尚无记录" }
        return "最近成功同步：\(date.formatted(date: .abbreviated, time: .standard))"
    }

    private var countSummary: String {
        "关注 \(store.getWhitelist().count) · 待分类 \(store.classificationQueueCount()) · 草稿 \(store.workspaceDraftCount())"
    }

    private var keyState: String {
        switch monitor.reader.accessMaterialState {
        case .available: return "可读取"
        case .missing: return "未找到"
        case .unreadable: return "不可读取"
        }
    }

    private var keyColor: Color {
        switch monitor.reader.accessMaterialState {
        case .available: return .secondary
        case .missing, .unreadable: return .orange
        }
    }

    private var aiProviderLabel: String {
        let slot = store.loadAIConfig().provider
        return AIProvider.find(slot.providerID)?.name ?? (slot.providerID == "custom" ? "自定义服务" : slot.providerID)
    }

    private var summaryText: String {
        let process = SupportDiagnosticsSnapshot.current()
        return [
            "WeChatHUD 诊断概况",
            "版本：\(version)",
            "macOS：\(macOSVersion)",
            "架构：\(architecture)",
            "同步状态：\(syncLabel)",
            lastSyncText,
            "数量：\(countSummary)",
            "密钥文件：\(keyState)",
            "AI 服务：\(aiProviderLabel)",
            "当前进程快照：",
            process.exportLines.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copyFeedback = pasteboard.setString(summaryText, forType: .string) ? "已复制" : "复制失败，请重试"
    }
}
