import AppKit
import SwiftUI
import AudioToolboxCore

public struct MainWindowView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    @State private var isPickingDirectory = false

    private let directoryPicker: DirectoryPicker

    public init(
        viewModel: LibraryViewModel,
        directoryPicker: DirectoryPicker = DirectoryPicker()
    ) {
        self.viewModel = viewModel
        self.directoryPicker = directoryPicker
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("Audio Toolbox")
        .toolbar { toolbarContent }
        .sheet(isPresented: batchSheetPresented) {
            batchSheetContent
                .interactiveDismissDisabled(viewModel.isBatchExecutionActive)
        }
    }

    private var sidebar: some View {
        List(selection: $viewModel.selectedGroupID) {
            Section(groupingSectionTitle) {
                if viewModel.filteredGroups.isEmpty {
                    Text(sidebarPlaceholder)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(viewModel.filteredGroups) { group in
                        HStack(spacing: 8) {
                            Text(group.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(group.trackIDs.count, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        .tag(group.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(group.displayName)，\(group.trackIDs.count) 个文件")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(
            text: $viewModel.groupSearchText,
            placement: .sidebar,
            prompt: Text(viewModel.groupSearchPrompt)
        )
        .disabled(viewModel.isLibraryInteractionLocked)
        .accessibilityLabel("音频分组")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let directoryOperationError = viewModel.directoryOperationError {
                MessageBanner(
                    title: "目录操作失败",
                    message: directoryOperationError,
                    systemImage: "folder.badge.questionmark",
                    color: .red
                )
            }

            if viewModel.scanFailureCount > 0 {
                MessageBanner(
                    title: "部分文件未能读取",
                    message: failureSummary,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            detailContent
            statusBar
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.scanState {
        case .idle:
            EmptyLibraryState(
                systemImage: "folder.badge.plus",
                title: "选择音频目录",
                message: "从工具栏选择一个目录，应用会扫描其中支持的音频文件。"
            )
        case .restoring:
            ProgressLibraryState(
                title: "正在恢复目录权限",
                message: "正在重新取得上次使用目录的访问权限…",
                progress: nil
            )
        case let .scanning(discovered, processed, loaded, _):
            if viewModel.visibleTracks.isEmpty {
                ProgressLibraryState(
                    title: "正在扫描音频文件",
                    message: scanProgressText(
                        discovered: discovered,
                        processed: processed,
                        loaded: loaded
                    ),
                    progress: scanProgress(discovered: discovered, processed: processed)
                )
            } else {
                libraryTableContent
            }
        case .loaded:
            libraryTableContent
        case .empty:
            EmptyLibraryState(
                systemImage: viewModel.scanFailureCount > 0
                    ? "exclamationmark.folder.fill"
                    : "waveform.badge.magnifyingglass",
                title: viewModel.scanFailureCount > 0
                    ? "音频文件读取失败"
                    : "没有可显示的音频文件",
                message: viewModel.emptyDirectoryMessage
                    ?? "所选目录中没有支持的音频文件。"
            )
        case let .failed(message):
            EmptyLibraryState(
                systemImage: "lock.trianglebadge.exclamationmark",
                title: "无法访问目录",
                message: "\(message)\n请重新选择目录并确认访问权限。"
            )
        }
    }

    private var libraryTableContent: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            TrackTableView(viewModel: viewModel)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.currentGroup?.displayName ?? "文件")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("当前组 \(viewModel.currentGroup?.trackIDs.count ?? 0) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            CurrentGroupSelectionToggle(
                state: viewModel.currentGroupSelectionState,
                isEnabled: viewModel.currentGroupHasEditableTracks
            ) { selected in
                viewModel.setCurrentGroupSelected(selected)
            }
            .accessibilityLabel("选择或取消选择当前组全部文件")

            Toggle(isOn: $viewModel.showsSuspectedDuplicatesOnly) {
                Label(
                    "疑似重复 \(viewModel.suspectedDuplicateTrackCount)",
                    systemImage: "doc.on.doc"
                )
            }
            .toggleStyle(.button)
            .help(viewModel.showsSuspectedDuplicatesOnly
                ? "当前只显示本分组中的疑似重复文件"
                : "只显示标题相似度不低于 85% 且时长接近的文件")
            .disabled(
                viewModel.isLibraryInteractionLocked
                    || (viewModel.suspectedDuplicateTrackCount == 0
                        && !viewModel.showsSuspectedDuplicatesOnly)
            )
            .accessibilityLabel("筛选当前分组疑似重复文件")

            TextField("搜索当前组", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                .accessibilityLabel("搜索当前分组文件")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label("已选择 \(viewModel.selectedCount)", systemImage: "checkmark.circle")
                .accessibilityLabel("全局已选择 \(viewModel.selectedCount) 个文件")
            Button {
                viewModel.clearSelection()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(
                viewModel.selectedCount == 0
                    || viewModel.isLibraryInteractionLocked
            )
            .help("清空全部选择")
            .accessibilityLabel("清空全部选择")
            Spacer()
            Text(scanStatusText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                chooseDirectory()
            } label: {
                Label("选择目录…", systemImage: "folder.badge.plus")
            }
            .disabled(isPickingDirectory || viewModel.isLibraryInteractionLocked)
            .accessibilityLabel("选择音频目录")

            Text(directorySummary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .help(viewModel.currentDirectoryURL?.path ?? "尚未选择目录")
                .accessibilityLabel("当前目录：\(directorySummary)")

            Picker("分组方式", selection: $viewModel.groupingMode) {
                Text("作者").tag(GroupingMode.artist)
                Text("专辑").tag(GroupingMode.album)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(viewModel.isLibraryInteractionLocked)
            .accessibilityLabel("按作者或专辑分组")

            Toggle(isOn: $viewModel.filtersInvalidAudioFiles) {
                Label("过滤无效文件", systemImage: "line.3.horizontal.decrease.circle")
            }
            .toggleStyle(.button)
            .help(viewModel.filtersInvalidAudioFiles
                ? "当前隐藏无法读取或无法播放的音频文件"
                : "当前显示无效文件；这些文件不能选择或编辑")
            .disabled(viewModel.isLibraryInteractionLocked)
            .accessibilityLabel("过滤无效音频文件")

            Button {
                refreshDirectory()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(
                viewModel.currentDirectoryURL == nil
                    || isScanning
                    || viewModel.isLibraryInteractionLocked
            )
            .accessibilityLabel("重新扫描当前目录")

            Button {
                viewModel.openBatchEditor()
            } label: {
                Label("批量编辑", systemImage: "square.and.pencil")
            }
            .disabled(!viewModel.canOpenBatchEditor || isScanning)
            .accessibilityLabel("批量编辑已选择文件")
        }
    }

    @ViewBuilder
    private var batchSheetContent: some View {
        switch viewModel.batchState {
        case .closed:
            EmptyView()
        case .editing:
            BatchEditSheet(viewModel: viewModel)
        case let .running(progress):
            BatchProgressSheet(
                viewModel: viewModel,
                progress: progress,
                isStopping: false
            )
        case let .stopping(progress):
            BatchProgressSheet(
                viewModel: viewModel,
                progress: progress,
                isStopping: true
            )
        case let .completed(summary):
            ResultSheet(summary: summary) {
                viewModel.closeBatchEditor()
            }
        }
    }

    private var batchSheetPresented: Binding<Bool> {
        Binding(
            get: { viewModel.isBatchSheetPresented },
            set: { isPresented in
                if !isPresented {
                    viewModel.closeBatchEditor()
                }
            }
        )
    }

    private var groupingSectionTitle: String {
        viewModel.groupingMode == .artist ? "作者" : "专辑"
    }

    private var sidebarPlaceholder: String {
        let groupQuery = viewModel.groupSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !groupQuery.isEmpty, !viewModel.groups.isEmpty {
            return viewModel.groupSearchEmptyMessage
        }
        return switch viewModel.scanState {
        case .restoring, .scanning:
            "正在扫描…"
        case .idle:
            "尚未选择目录"
        case .loaded, .empty, .failed:
            "没有分组"
        }
    }

    private var directorySummary: String {
        guard let url = viewModel.currentDirectoryURL else { return "尚未选择目录" }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private var failureSummary: String {
        let countText = "有 \(viewModel.scanFailureCount) 个文件未能读取。"
        guard let message = viewModel.scanFailureMessage else { return countText }
        return "\(countText) \(message)"
    }

    private var scanStatusText: String {
        switch viewModel.scanState {
        case .idle:
            "等待选择目录"
        case .restoring:
            "正在恢复目录权限"
        case let .scanning(discovered, processed, loaded, _):
            discovered > 0
                ? "已处理 \(processed) / 已发现 \(discovered)，有效 \(loaded)"
                : "已处理 \(processed)，有效 \(loaded)"
        case .loaded:
            libraryCountStatusText
        case .empty:
            libraryCountStatusText
        case .failed:
            "扫描失败"
        }
    }

    private var isScanning: Bool {
        switch viewModel.scanState {
        case .restoring, .scanning:
            true
        case .idle, .loaded, .empty, .failed:
            false
        }
    }

    private func chooseDirectory() {
        guard !isPickingDirectory else { return }
        Task { @MainActor in
            isPickingDirectory = true
            defer { isPickingDirectory = false }
            guard let url = await directoryPicker.pickDirectory() else { return }
            await viewModel.loadDirectory(url)
        }
    }

    private func refreshDirectory() {
        guard let url = viewModel.currentDirectoryURL else { return }
        Task { await viewModel.loadDirectory(url) }
    }

    private var libraryCountStatusText: String {
        if viewModel.hiddenInvalidTrackCount > 0 {
            return "显示 \(viewModel.visibleTrackCount) 个文件，已过滤 \(viewModel.hiddenInvalidTrackCount) 个无效文件"
        }
        return "显示 \(viewModel.visibleTrackCount) 个文件"
    }

    private func scanProgress(discovered: Int, processed: Int) -> Double? {
        guard discovered > 0 else { return nil }
        return min(Double(processed) / Double(discovered), 1)
    }

    private func scanProgressText(
        discovered: Int,
        processed: Int,
        loaded: Int
    ) -> String {
        guard discovered > 0 else { return "正在查找支持的音频文件…" }
        return "已处理 \(processed) / \(discovered) 个候选文件，其中 \(loaded) 个有效。"
    }
}

private struct MessageBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(message)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyLibraryState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressLibraryState: View {
    let title: String
    let message: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct CurrentGroupSelectionToggle: NSViewRepresentable {
    let state: CurrentGroupSelectionState
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "全选",
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        button.allowsMixedState = true
        button.toolTip = "选择或取消选择当前分组中的全部文件"
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        switch state {
        case .none:
            button.state = .off
        case .mixed:
            button.state = .mixed
        case .all:
            button.state = .on
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CurrentGroupSelectionToggle

        init(parent: CurrentGroupSelectionToggle) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSButton) {
            parent.onChange(parent.state != .all)
        }
    }
}
