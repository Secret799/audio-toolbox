import AppKit
import SwiftUI
import AudioToolboxCore

struct ArtistComposerSyncEditingView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                TextField("搜索作者或作曲者", text: $viewModel.artistComposerSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索作者或作曲者")

                Picker("统一依据", selection: $viewModel.artistComposerAuthority) {
                    Text("以作者为准").tag(ArtistComposerAuthority.artist)
                    Text("以作曲者为准").tag(ArtistComposerAuthority.composer)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button {
                    viewModel.applyArtistComposerAuthorityToAll()
                } label: {
                    Label("应用到全部", systemImage: "checkmark.rectangle.stack")
                }
                .disabled(viewModel.artistComposerSyncRows.isEmpty)
            }

            syncTable

            HStack {
                Label(
                    "将处理 \(viewModel.artistComposerSyncGroupCount) 组、\(viewModel.artistComposerSyncFileCount) 个文件",
                    systemImage: "checkmark.circle"
                )
                .monospacedDigit()
                Spacer()
                if !viewModel.canPreviewArtistComposerSync {
                    Text("请填写至少一个统一值")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(20)
    }

    private var syncTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("原作者")
                    .frame(width: 190, alignment: .leading)
                Text("原作曲者")
                    .frame(width: 190, alignment: .leading)
                Text("文件")
                    .frame(width: 100, alignment: .leading)
                Text("统一值")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            if viewModel.filteredArtistComposerSyncRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.line.dotted.person")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(viewModel.artistComposerSyncRows.isEmpty
                        ? "作者与作曲者均已一致"
                        : "没有匹配的组合")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredArtistComposerSyncRows) { row in
                            syncRow(row)
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

    private func syncRow(_ row: ArtistComposerSyncRow) -> some View {
        HStack(spacing: 12) {
            metadataCell(row.artistDisplayName, label: "作者")
                .frame(width: 190, alignment: .leading)
            metadataCell(row.composerDisplayName, label: "作曲者")
                .frame(width: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("可编辑 \(row.editableCount)")
                if row.unavailableCount > 0 {
                    Text("跳过 \(row.unavailableCount)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 100, alignment: .leading)

            TextField("不处理", text: draftBinding(for: row.id))
                .textFieldStyle(.roundedBorder)
                .disabled(row.editableCount == 0)
                .accessibilityLabel(
                    "将作者 \(row.artistDisplayName) 和作曲者 \(row.composerDisplayName) 统一为"
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metadataCell(_ value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                copyToPasteboard(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制原\(label)")
            .accessibilityLabel("复制原\(label) \(value)")
        }
    }

    private func draftBinding(for identity: ArtistComposerIdentity) -> Binding<String> {
        Binding(
            get: { viewModel.artistComposerDrafts[identity] ?? "" },
            set: { viewModel.setArtistComposerDraft($0, for: identity) }
        )
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct ArtistComposerSyncPreviewView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            warning
            previewTable
            Text(
                "将处理 \(viewModel.artistComposerSyncGroupCount) 组、"
                    + "\(viewModel.artistComposerSyncFileCount) 个可编辑文件。"
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
            Text("只修改作者和作曲者，不修改专辑、标题、文件名或文件位置。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle(
                "我了解此操作不会保留永久备份",
                isOn: $viewModel.artistComposerAcknowledgedNoBackup
            )
            .toggleStyle(.checkbox)
            .accessibilityLabel("确认作者和作曲者同步无永久备份")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private var previewTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("原作者")
                    .frame(width: 180, alignment: .leading)
                Text("原作曲者")
                    .frame(width: 180, alignment: .leading)
                Image(systemName: "arrow.right")
                    .frame(width: 22)
                Text("统一值")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("文件")
                    .frame(width: 130, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.artistComposerSyncPreviews) { preview in
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
    }

    private func previewRow(_ preview: ArtistComposerSyncPreview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(preview.artistDisplayName)
                .frame(width: 180, alignment: .leading)
            Text(preview.composerDisplayName)
                .frame(width: 180, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(preview.unifiedValue)
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
            .frame(width: 130, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
