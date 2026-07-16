import AppKit
import SwiftUI
import AudioToolboxCore

public struct ResultSheet: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case succeeded
        case warning
        case failed
        case notProcessed

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "全部"
            case .succeeded: "成功"
            case .warning: "有警告"
            case .failed: "失败"
            case .notProcessed: "未处理"
            }
        }
    }

    public let summary: BatchEditSummary
    public let onClose: () -> Void

    @State private var filter: Filter = .all

    public init(summary: BatchEditSummary, onClose: @escaping () -> Void) {
        self.summary = summary
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            resultList
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(hasWarnings ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("批量编辑完成")
                    .font(.title2.weight(.semibold))
                Text("共 \(summary.results.count) 个文件")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            resultCount(title: "成功", value: summary.cleanSucceededCount, color: .green)
            resultCount(
                title: "成功有警告",
                value: summary.succeededWithWarningCount,
                color: .orange
            )
            resultCount(title: "失败", value: summary.failedCount, color: .red)
            resultCount(title: "未处理", value: summary.notProcessedCount, color: .orange)
        }
        .padding(20)
    }

    private var filterBar: some View {
        HStack {
            Text("筛选结果")
                .font(.headline)
            Picker("筛选结果", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text("\(item.title)（\(count(for: item))）")
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 650)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultList: some View {
        if filteredResults.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("此筛选条件下没有文件")
                    .font(.headline)
                Text("请选择其他结果类型。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredResults.enumerated()), id: \.offset) { index, result in
                        resultRow(result)
                        if index < filteredResults.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func resultRow(_ result: BatchFileResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon(result))
                .foregroundStyle(statusColor(result))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(result.url.lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(statusTitle(result))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(result))
                }
                Text(result.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let reason = resultReason(result) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(result.status == .failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Button("显示原文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                }
                .controlSize(.small)

                if let recoveryURL = result.recoveryURL {
                    Button("显示恢复文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                    }
                    .controlSize(.small)
                    .help(recoveryURL.path)
                }
            }
        }
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack {
            if summary.succeededWithWarningCount > 0 {
                Label("部分文件修改成功但有清理警告，请确认并保留需要的恢复文件。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if summary.failedCount > 0 {
                Label("失败文件保留原文件；可查看原因后重试。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var hasWarnings: Bool {
        summary.succeededWithWarningCount > 0
            || summary.failedCount > 0
            || summary.notProcessedCount > 0
    }

    private func resultCount(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 58)
    }

    private var filteredResults: [BatchFileResult] {
        switch filter {
        case .all:
            summary.results
        case .succeeded:
            summary.cleanSucceededResults
        case .warning:
            summary.succeededWithWarnings
        case .failed:
            summary.results.filter { $0.status == .failed }
        case .notProcessed:
            summary.results.filter { $0.status == .notProcessed }
        }
    }

    private func count(for filter: Filter) -> Int {
        switch filter {
        case .all: summary.results.count
        case .succeeded: summary.cleanSucceededCount
        case .warning: summary.succeededWithWarningCount
        case .failed: summary.failedCount
        case .notProcessed: summary.notProcessedCount
        }
    }

    private func statusTitle(_ result: BatchFileResult) -> String {
        if result.isSucceededWithWarning { return "成功，有警告" }
        switch result.status {
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .notProcessed: return "未处理"
        }
    }

    private func statusIcon(_ result: BatchFileResult) -> String {
        if result.isSucceededWithWarning { return "exclamationmark.circle.fill" }
        switch result.status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .notProcessed: return "minus.circle.fill"
        }
    }

    private func statusColor(_ result: BatchFileResult) -> Color {
        if result.isSucceededWithWarning { return .orange }
        switch result.status {
        case .succeeded: return .green
        case .failed: return .red
        case .notProcessed: return .orange
        }
    }

    private func resultReason(_ result: BatchFileResult) -> String? {
        switch result.status {
        case .succeeded:
            result.message.map { "警告：\($0)" }
        case .failed:
            "原因：\(result.message ?? "未知错误")"
        case .notProcessed:
            result.message.map { "原因：\($0)" } ?? "未处理"
        }
    }
}
