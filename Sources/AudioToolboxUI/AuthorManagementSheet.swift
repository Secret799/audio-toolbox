import SwiftUI
import AudioToolboxCore

public struct AuthorManagementSheet: View {
    @ObservedObject private var viewModel: LibraryViewModel

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch viewModel.authorManagementState {
                case .editing:
                    editingContent
                case .previewing:
                    previewContent
                case .closed, .running, .stopping, .completed:
                    EmptyView()
                }
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 680)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("作者管理")
                    .font(.title2.weight(.semibold))
                Text(isPreviewing
                    ? "第 2 步（共 2 步）：预览并确认"
                    : "第 1 步（共 2 步）：设置作者映射")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("共 \(viewModel.authorRenameRows.count) 位作者")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var editingContent: some View {
        VStack(spacing: 14) {
            HStack {
                TextField("搜索作者", text: $viewModel.authorSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索作者")
                Text("填写后只修改对应作者的可编辑文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            authorTable

            HStack {
                Label(
                    "将修改 \(viewModel.authorRenameAuthorCount) 位作者下的 \(viewModel.authorRenameFileCount) 个文件",
                    systemImage: "checkmark.circle"
                )
                    .monospacedDigit()
                Spacer()
                if !viewModel.canPreviewAuthorRenames {
                    Text("请至少填写一个与原作者不同的新作者")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(20)
    }

    private var authorTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("原作者")
                    .frame(width: 220, alignment: .leading)
                Text("文件")
                    .frame(width: 110, alignment: .leading)
                Text("新作者")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            if viewModel.filteredAuthorRenameRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("没有匹配的作者")
                        .font(.headline)
                    Text("请调整搜索内容")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredAuthorRenameRows) { row in
                            authorRow(row)
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
    }

    private func authorRow(_ row: AuthorRenameRow) -> some View {
        HStack(spacing: 12) {
            Text(row.displayName)
                .lineLimit(2)
                .frame(width: 220, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("可编辑 \(row.editableCount)")
                if row.unavailableCount > 0 {
                    Text("跳过 \(row.unavailableCount)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 110, alignment: .leading)

            TextField("保持不变", text: draftBinding(for: row.id))
                .textFieldStyle(.roundedBorder)
                .disabled(row.editableCount == 0)
                .accessibilityLabel("将\(row.displayName)修改为")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var previewContent: some View {
        VStack(spacing: 16) {
            warning

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("原作者")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("新作者")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("文件")
                        .frame(width: 150, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.bar)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.authorRenamePreviews) { preview in
                            previewRow(preview)
                            Divider()
                        }
                    }
                }
            }
            .background(.background)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            )

            Text(
                "将修改 \(viewModel.authorRenameAuthorCount) 位作者下的 "
                    + "\(viewModel.authorRenameFileCount) 个可编辑文件。"
            )
            .font(.callout.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("此操作不会创建永久备份", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("只会修改作者字段，不会修改专辑或移动文件。成功文件会立即更新到列表，无需重新扫描目录。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle(
                "我了解此操作不会保留永久备份",
                isOn: $viewModel.authorRenameAcknowledgedNoBackup
            )
            .toggleStyle(.checkbox)
            .accessibilityLabel("确认作者修改无永久备份")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private func previewRow(_ preview: AuthorRenamePreview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(preview.oldAuthor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(preview.newAuthor)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("修改 \(preview.editableCount)")
                if preview.unavailableCount > 0 {
                    Text("跳过 \(preview.unavailableCount)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") {
                viewModel.closeAuthorManagement()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if isPreviewing {
                Button("上一步") {
                    viewModel.returnToAuthorRenameEditing()
                }
                Button("执行修改") {
                    Task { await viewModel.runAuthorRenames() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canExecuteAuthorRenames)
            } else {
                Button("下一步") {
                    viewModel.showAuthorRenamePreview()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canPreviewAuthorRenames)
            }
        }
        .padding(16)
    }

    private var isPreviewing: Bool {
        if case .previewing = viewModel.authorManagementState { return true }
        return false
    }

    private func draftBinding(for author: AuthorIdentity) -> Binding<String> {
        Binding(
            get: { viewModel.authorRenameDrafts[author] ?? "" },
            set: { viewModel.setAuthorRenameDraft($0, for: author) }
        )
    }
}
