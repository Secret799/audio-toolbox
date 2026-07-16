import SwiftUI
import AudioToolboxCore

public struct TrackTableView: View {
    @ObservedObject private var viewModel: LibraryViewModel

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Table(
            viewModel.filteredTracks,
            sortOrder: $viewModel.titleSortOrder
        ) {
            TableColumn("选择") { track in
                Toggle(
                    "选择 \(displayTitle(for: track))",
                    isOn: selectionBinding(for: track)
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!track.isEditable || viewModel.isLibraryInteractionLocked)
                .accessibilityLabel("选择 \(displayTitle(for: track))")
            }
            .width(min: 42, ideal: 48, max: 56)

            TableColumn(
                "标题 / 文件名",
                sortUsing: AudioTrackTitleComparator()
            ) { track in
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(for: track))
                        .lineLimit(1)
                    Text(track.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(track.url.path)
                .accessibilityElement(children: .combine)
            }
            .width(min: 180, ideal: 250)

            TableColumn("作者") { track in
                Text(displayArtists(for: track))
                    .lineLimit(1)
                    .help(displayArtists(for: track))
            }
            .width(min: 110, ideal: 150)

            TableColumn("专辑") { track in
                Text(displayAlbums(for: track))
                    .lineLimit(1)
                    .help(displayAlbums(for: track))
            }
            .width(min: 110, ideal: 160)

            TableColumn("格式") { track in
                Text(track.format.rawValue.uppercased())
                    .monospaced()
            }
            .width(min: 58, ideal: 66, max: 76)

            TableColumn("时长") { track in
                Text(Self.formatDuration(track.metadata.duration))
                    .monospacedDigit()
            }
            .width(min: 62, ideal: 72, max: 86)

            TableColumn("大小") { track in
                Text(Self.formatFileSize(track.fileSize))
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 86, max: 104)

            TableColumn("状态") { track in
                VStack(alignment: .leading, spacing: 3) {
                    TrackStatusView(track: track)
                    if let duplicateStatus = viewModel.suspectedDuplicateStatusText(
                        for: track.id
                    ) {
                        Label(duplicateStatus, systemImage: "doc.on.doc.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help(duplicateStatus)
                            .accessibilityLabel(duplicateStatus)
                    }
                }
            }
            .width(min: 120, ideal: 190, max: 250)
        }
        .accessibilityLabel("当前分组文件表格")
    }

    private func selectionBinding(for track: AudioTrack) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedTrackIDs.contains(track.id) },
            set: { isSelected in
                let wasSelected = viewModel.selectedTrackIDs.contains(track.id)
                if isSelected != wasSelected {
                    viewModel.toggleSelection(track.id)
                }
            }
        )
    }

    private func displayTitle(for track: AudioTrack) -> String {
        normalized(track.metadata.title) ?? "未命名"
    }

    private func displayArtists(for track: AudioTrack) -> String {
        let values = track.metadata.artists.compactMap(normalized)
        return values.isEmpty ? "未知作者" : values.joined(separator: " / ")
    }

    private func displayAlbums(for track: AudioTrack) -> String {
        let values = track.metadata.albums.compactMap(normalized)
        return values.isEmpty ? "未知专辑" : values.joined(separator: " / ")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct TrackStatusView: View {
    let track: AudioTrack

    var body: some View {
        Label(presentation.title, systemImage: presentation.systemImage)
            .foregroundStyle(presentation.color)
            .lineLimit(1)
            .help(presentation.detail)
            .accessibilityLabel("状态：\(presentation.title)")
    }

    private var presentation: TrackStatusPresentation {
        if let issue = track.issue {
            switch issue {
            case let .unreadable(message):
                return TrackStatusPresentation(
                    title: "不可读取",
                    detail: message,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .red
                )
            case let .notWritable(message):
                return TrackStatusPresentation(
                    title: "不可写入",
                    detail: message,
                    systemImage: "lock.fill",
                    color: .orange
                )
            case let .unsupportedTag(message):
                return TrackStatusPresentation(
                    title: "不支持写入",
                    detail: message,
                    systemImage: "nosign",
                    color: .orange
                )
            }
        }

        if track.isWritable {
            return TrackStatusPresentation(
                title: "可编辑",
                detail: "文件可读取并支持写入标签",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }

        return TrackStatusPresentation(
            title: "只读",
            detail: "文件当前不可写入",
            systemImage: "lock.fill",
            color: .orange
        )
    }
}

private struct TrackStatusPresentation {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
}
