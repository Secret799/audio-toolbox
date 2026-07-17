import SwiftUI
import AudioToolboxCore

public struct BatchEditSheet: View {
    private enum Step {
        case values
        case preview
    }

    @ObservedObject private var viewModel: LibraryViewModel
    @State private var step: Step = .values

    private let previewLimit = 100

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .values:
                    valuesStep
                case .preview:
                    previewStep
                }
            }
            Divider()
            footer
        }
        .frame(width: step == .values ? 620 : 940, height: step == .values ? 430 : 650)
        .animation(.easeInOut(duration: 0.15), value: step)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("批量编辑元数据")
                    .font(.title2.weight(.semibold))
                Text(step == .values ? "第 1 步（共 2 步）：设置要修改的字段" : "第 2 步（共 2 步）：预览并确认")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(
                "已选择 \(viewModel.batchEditTracks.count) 个文件，将修改 "
                    + "\(viewModel.batchActualModificationCount) 个"
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var valuesStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("留空或与原值相同的字段不会修改。输入内容两端的空格和换行会在执行前移除。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    Text("作者")
                        .frame(width: 70, alignment: .trailing)
                    TextField(viewModel.batchArtistPrompt, text: $viewModel.batchArtist)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("新的作者")
                }
                GridRow {
                    Text("专辑")
                        .frame(width: 70, alignment: .trailing)
                    TextField(viewModel.batchAlbumPrompt, text: $viewModel.batchAlbum)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("新的专辑")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("修改摘要")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 7) {
                    summaryRow(
                        label: "作者",
                        value: viewModel.validatedBatchPatch?.artist
                    )
                    summaryRow(
                        label: "专辑",
                        value: viewModel.validatedBatchPatch?.album
                    )
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }

            if !viewModel.canAdvanceBatchEdit {
                Label("请填写至少一个与原值不同的非空内容。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var previewStep: some View {
        VStack(spacing: 16) {
            warning

            VStack(spacing: 0) {
                previewHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(previewTracks.enumerated()), id: \.element.id) { index, track in
                            previewRow(track: track)
                            if index < previewTracks.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(.background)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            )

            if remainingPreviewCount > 0 {
                Text(
                    "另有 \(remainingPreviewCount) 个已选文件未在预览中显示；"
                        + "执行时只处理实际需要修改的 "
                        + "\(viewModel.batchActualModificationCount) 个文件。"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("此操作不会创建永久备份", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("应用会使用安全临时副本写入，但成功替换后不会保留可供恢复的备份。请确认预览内容无误。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("我了解此操作不会保留永久备份", isOn: $viewModel.batchAcknowledgedNoBackup)
                .toggleStyle(.checkbox)
                .accessibilityLabel("确认无永久备份")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private var previewHeader: some View {
        HStack(spacing: 12) {
            Text("文件")
                .frame(width: 190, alignment: .leading)
            Text("原作者")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("新作者")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("原专辑")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("新专辑")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func previewRow(track: AudioTrack) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.url.lastPathComponent)
                    .lineLimit(1)
                Text(track.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)

            let patch = viewModel.effectiveBatchPatch(for: track)
            previewValue(originalArtist(track))
            previewValue(patch?.artist ?? "保持不变", changed: patch?.artist != nil)
            previewValue(originalAlbum(track))
            previewValue(patch?.album ?? "保持不变", changed: patch?.album != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func previewValue(_ value: String, changed: Bool = false) -> some View {
        Text(value)
            .fontWeight(changed ? .semibold : .regular)
            .foregroundStyle(changed ? Color.primary : Color.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") {
                viewModel.closeBatchEditor()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if step == .preview {
                Button("上一步") {
                    step = .values
                }
            }

            switch step {
            case .values:
                Button("下一步") {
                    step = .preview
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAdvanceBatchEdit)
            case .preview:
                Button("执行编辑") {
                    Task { await viewModel.runBatchEdit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canExecuteBatchEdit)
            }
        }
        .padding(16)
    }

    private func summaryRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            if let value {
                Text("改为“\(value)”")
                    .fontWeight(.medium)
            } else {
                Text("保持不变")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewTracks: [AudioTrack] {
        Array(viewModel.batchEditTracks.prefix(previewLimit))
    }

    private var remainingPreviewCount: Int {
        max(0, viewModel.batchEditTracks.count - previewLimit)
    }

    private func originalArtist(_ track: AudioTrack) -> String {
        displayValue(track.metadata.artists)
    }

    private func originalAlbum(_ track: AudioTrack) -> String {
        displayValue(track.metadata.albums)
    }

    private func displayValue(_ values: [String]) -> String {
        let value = values.joined(separator: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未设置" : value
    }
}

struct BatchProgressSheet: View {
    @ObservedObject var viewModel: LibraryViewModel
    let progress: BatchProgress
    let isStopping: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: isStopping ? "stop.circle" : "waveform.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(isStopping ? Color.orange : Color.accentColor)

            VStack(spacing: 6) {
                Text(isStopping ? "正在停止批量编辑" : "正在批量编辑")
                    .font(.title2.weight(.semibold))
                Text("已处理 \(progress.completed) / \(progress.total)")
                    .font(.headline.monospacedDigit())
            }

            ProgressView(
                value: Double(progress.completed),
                total: Double(max(progress.total, 1))
            )
            .frame(width: 440)

            VStack(spacing: 5) {
                Text("最近处理文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(progress.currentURL?.lastPathComponent ?? "正在准备…")
                    .lineLimit(1)
                    .help(progress.currentURL?.path ?? "正在准备批量编辑")
                if let currentURL = progress.currentURL {
                    Text(currentURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(currentURL.path)
                }
            }
            .frame(maxWidth: 500)

            Button(isStopping ? "正在停止…" : "停止") {
                Task { await viewModel.stopBatchEdit() }
            }
            .disabled(isStopping)
        }
        .padding(36)
        .frame(width: 600, height: 360)
        .accessibilityElement(children: .contain)
    }
}
