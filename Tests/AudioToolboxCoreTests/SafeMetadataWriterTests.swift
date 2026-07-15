import Darwin
import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("SafeMetadataWriterTests")
struct SafeMetadataWriterTests {
    @Test
    func successfulSwapPreservesMetadataModeXattrAndUsesOnlyTemporaryURL() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: original.path
        )
        let xattrName = "com.audio-toolbox.safe-writer-test"
        let xattrValue = Data("保留扩展属性".utf8)
        try setExtendedAttribute(xattrValue, named: xattrName, at: original)
        let service = FakeSafeMetadataService()
        let writer = makeTestWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: "新专辑")
        )

        #expect(result.status == .succeeded)
        #expect(result.message == nil)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try directory.temporaryWorkFiles().isEmpty)
        let savedText = try String(contentsOf: original, encoding: .utf8)
        #expect(savedText.contains("title=原始标题"))
        #expect(savedText.contains("artist=新作者"))
        #expect(savedText.contains("album=新专辑"))
        #expect(savedText.contains("duration=123"))
        #expect(savedText.contains("custom=必须保留"))
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o640)
        #expect(try extendedAttribute(named: xattrName, at: original) == xattrValue)

        let writeURLs = await service.recordedWriteURLs()
        let readURLs = await service.recordedReadURLs()
        #expect(writeURLs.count == 1)
        #expect(readURLs == writeURLs)
        #expect(writeURLs.first != original)
        #expect(writeURLs.first?.deletingLastPathComponent() == original.deletingLastPathComponent())
        #expect(writeURLs.first?.lastPathComponent.hasPrefix(".audio-toolbox-") == true)
        #expect(writeURLs.first?.pathExtension == original.pathExtension)
        #expect(writeURLs.first.map { AudioFileCandidate.shouldSkip($0, values: URLResourceValues()) } == true)
    }

    @Test
    func copyExclusiveCollisionRetriesWithoutDeletingExistingFile() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let collision = directory.url.appendingPathComponent(".audio-toolbox-collision.mp3")
        let collisionBytes = Data("existing collision".utf8)
        try collisionBytes.write(to: collision)
        let identifiers = LockedIdentifiers(["collision", "fresh"])
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileOperations: testFileOperations(),
            commitGate: { true },
            temporaryIdentifierProvider: { identifiers.next() }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(try Data(contentsOf: collision) == collisionBytes)
        #expect(try directory.temporaryWorkFiles().map(\.lastPathComponent) == [collision.lastPathComponent])
        #expect(await service.recordedWriteURLs().first?.lastPathComponent == ".audio-toolbox-fresh.mp3")
    }


    @Test
    func temporaryPathReplacedAfterCopyIsRejectedBeforeMetadataWrite() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let competitorBytes = Data("competitor before write".utf8)
        let live = testFileOperations()
        let operations = live.overriding(copyExclusive: { source, destination in
            let ownedState = try live.copyExclusive(source, destination)
            try competitorBytes.write(to: destination, options: .atomic)
            return ownedState
        })
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { "prewrite-race" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("工作副本身份发生变化") == true)
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try Data(contentsOf: original) == originalBytes)
        let competitor = directory.url.appendingPathComponent(".audio-toolbox-prewrite-race.mp3")
        #expect(try Data(contentsOf: competitor) == competitorBytes)
    }

    @Test
    func metadataServiceReplacingWorkingInodeIsRejectedWithoutDeletingReplacement() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(mode: .replaceWorkingFileInode)
        let writer = makeTestWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("工作副本身份发生变化") == true)
        #expect(result.message?.contains("未删除") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        let remaining = try directory.temporaryWorkFiles()
        #expect(remaining.count == 1)
        #expect(try String(contentsOf: remaining[0], encoding: .utf8).contains("atomic replacement"))
    }

    @Test
    func sameSizeOriginalChangeWithRestoredMtimeIsRejectedByDigest() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        var changedBytes = originalBytes
        changedBytes[changedBytes.startIndex] ^= 0x01
        let originalMtime = try #require(
            FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date
        )
        let live = testFileOperations()
        let initialState = try live.nodeState(original)
        let operations = live.overriding(nodeState: { url in
            if sameFileSystemPath(url, original) {
                return initialState
            }
            return try live.nodeState(url)
        })
        let service = FakeSafeMetadataService(
            mode: .mutateOriginal(original, changedBytes, originalMtime)
        )
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { UUID().uuidString }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("内容已发生变化") == true)
        #expect(try Data(contentsOf: original) == changedBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func finalCommitGateCancellationDoesNotSwap() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileOperations: testFileOperations(),
            commitGate: { false },
            temporaryIdentifierProvider: { UUID().uuidString }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .notProcessed)
        #expect(result.message?.contains("取消") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }


    @Test
    func coordinatedTemporaryURLIsUsedForCancellationCleanup() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(
            coordinateReplacing: { original, temporary, accessor in
                let moved = temporary.deletingLastPathComponent()
                    .appendingPathComponent(".audio-toolbox-coordinated.mp3")
                try FileManager.default.moveItem(at: temporary, to: moved)
                try accessor(original, moved)
            }
        )
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { false },
            temporaryIdentifierProvider: { "before-coordination" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .notProcessed)
        #expect(result.message?.contains("取消") == true)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func swapFailureLeavesOriginalUntouchedAndCleansOwnedTemporaryFile() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(swap: { _, _ in
            throw FakeWriterError.swapFailed
        })
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { UUID().uuidString }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("原子提交") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func successfulSwapWithOldCopyCleanupFailureReturnsSuccessWarningAndPreservesRecoveryFile() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(unlink: { _ in
            throw SafeMetadataFileSystemError(operation: .unlink, code: EACCES)
        })
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { "cleanup-failure" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(result.message?.contains("恢复副本") == true)
        #expect(result.message?.contains("未能清理") == true)
        #expect(result.message?.contains("没有删除权限") == true)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
        let recovery = directory.url.appendingPathComponent(".audio-toolbox-cleanup-failure.mp3")
        #expect(try Data(contentsOf: recovery) == originalBytes)
    }

    @Test
    func competingReplacementOfTemporaryPathIsNotDeletedOrCommitted() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let competitorBytes = Data("competitor owns this path".utf8)
        let service = FakeSafeMetadataService(mode: .replaceWorkingPathAfterRead(competitorBytes))
        let writer = makeTestWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("工作副本身份发生变化") == true)
        #expect(result.message?.contains("未删除") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        let remaining = try directory.temporaryWorkFiles()
        #expect(remaining.count == 1)
        #expect(try Data(contentsOf: remaining[0]) == competitorBytes)
    }

    @Test
    func metadataWriteAndVerificationFailuresLeaveOriginalUntouchedAndCleanOwnedTemporaryFile() async throws {
        for mode in [FakeSafeMetadataService.Mode.writeFails, .verificationMismatch] {
            let directory = try TemporaryAudioDirectory()
            defer { directory.remove() }
            let original = try directory.createAudioFile()
            let originalBytes = try Data(contentsOf: original)
            let writer = makeTestWriter(metadataService: FakeSafeMetadataService(mode: mode))

            let result = await writer.apply(
                to: original,
                patch: MetadataPatch(artist: "新作者", album: "新专辑")
            )

            #expect(result.status == .failed)
            #expect(try Data(contentsOf: original) == originalBytes)
            #expect(try directory.temporaryWorkFiles().isEmpty)
        }
    }

    @Test
    func cancellationDuringWriteCleansOnlyOwnedTemporaryFile() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(mode: .waitForCancellation)
        let writer = makeTestWriter(metadataService: service)
        let task = Task {
            await writer.apply(
                to: original,
                patch: MetadataPatch(artist: "新作者", album: nil)
            )
        }

        await service.waitUntilWriteStarts()
        task.cancel()
        let result = await task.value

        #expect(result.status == .notProcessed)
        #expect(result.message?.contains("取消") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func symlinkAndHardLinkedFilesAreRejectedConservatively() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let symlink = directory.url.appendingPathComponent("symlink.mp3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let hardLink = directory.url.appendingPathComponent("hardlink.mp3")
        try FileManager.default.linkItem(at: original, to: hardLink)
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService())

        let symlinkResult = await writer.apply(
            to: symlink,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )
        let hardLinkResult = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(symlinkResult.status == .failed)
        #expect(symlinkResult.message?.contains("符号链接") == true)
        #expect(hardLinkResult.status == .failed)
        #expect(hardLinkResult.message?.contains("硬链接") == true)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }


    @Test
    func cancellationAfterSwapStartsStillReturnsSucceeded() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(swap: { original, temporary in
            withUnsafeCurrentTask { task in task?.cancel() }
            try live.swap(original, temporary)
        })
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { UUID().uuidString }
        )
        let task = Task {
            await writer.apply(
                to: original,
                patch: MetadataPatch(artist: "新作者", album: nil)
            )
        }

        let result = await task.value

        #expect(result.status == .succeeded)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func postSwapIdentityMismatchReturnsSuccessWarningWithoutDeletingUnknownPath() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let competitorBytes = Data("post-swap competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(swap: { original, temporary in
            try live.swap(original, temporary)
            try competitorBytes.write(to: temporary, options: .atomic)
        })
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { "identity-warning" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(result.message?.contains("恢复副本") == true)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
        let unknown = directory.url.appendingPathComponent(".audio-toolbox-identity-warning.mp3")
        #expect(try Data(contentsOf: unknown) == competitorBytes)
    }

    @Test
    func preflightRejectsMissingDirectoryUnreadableUnwritableAndUnsupportedFiles() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let patch = MetadataPatch(artist: "新作者", album: nil)
        let missing = directory.url.appendingPathComponent("missing.mp3")
        let folder = directory.url.appendingPathComponent("folder.mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let unreadable = directory.url.appendingPathComponent("unreadable.mp3")
        let unwritable = directory.url.appendingPathComponent("unwritable.mp3")
        try Data("unreadable".utf8).write(to: unreadable)
        try Data("unwritable".utf8).write(to: unwritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: unreadable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: unwritable.path)
        let supported = try directory.createAudioFile()

        let normalWriter = makeTestWriter(metadataService: FakeSafeMetadataService())
        let missingResult = await normalWriter.apply(to: missing, patch: patch)
        let folderResult = await normalWriter.apply(to: folder, patch: patch)
        let unreadableResult = await normalWriter.apply(to: unreadable, patch: patch)
        let unwritableResult = await normalWriter.apply(to: unwritable, patch: patch)
        let unsupportedWriter = makeTestWriter(
            metadataService: FakeSafeMetadataService(writable: false)
        )
        let unsupportedResult = await unsupportedWriter.apply(to: supported, patch: patch)

        #expect(missingResult.message?.contains("不存在") == true)
        #expect(folderResult.message?.contains("普通文件") == true)
        #expect(unreadableResult.message?.contains("不可读") == true)
        #expect(unwritableResult.message?.contains("不可写") == true)
        #expect(unsupportedResult.message?.contains("不支持") == true)
        #expect([missingResult, folderResult, unreadableResult, unwritableResult, unsupportedResult]
            .allSatisfy { $0.status == .failed })
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func copyNoSpaceErrorUsesStableChineseMessage() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(copyExclusive: { _, _ in
            throw SafeMetadataFileSystemError(operation: .copy, code: ENOSPC)
        })
        let writer = SafeMetadataWriter(
            metadataService: FakeSafeMetadataService(),
            fileOperations: operations,
            commitGate: { true },
            temporaryIdentifierProvider: { UUID().uuidString }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message == "无法创建安全工作副本：磁盘空间不足")
        #expect(!result.message!.contains("space"))
    }
}

private actor FakeSafeMetadataService: MetadataService {
    enum Mode: Sendable {
        case normal
        case writeFails
        case verificationMismatch
        case waitForCancellation
        case replaceWorkingFileInode
        case mutateOriginal(URL, Data, Date)
        case replaceWorkingPathAfterRead(Data)
    }

    private let mode: Mode
    private let writable: Bool
    private var writeURLs: [URL] = []
    private var readURLs: [URL] = []
    private var writeStarted = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode = .normal, writable: Bool = true) {
        self.mode = mode
        self.writable = writable
    }

    func read(url: URL) async throws -> AudioMetadata {
        readURLs.append(url)
        let fields = try Self.readFields(url)
        let metadata = AudioMetadata(
            title: fields["title"],
            artists: [mode.isVerificationMismatch ? "验证不匹配" : fields["artist"]].compactMap { $0 },
            albums: fields["album"].map { [$0] } ?? [],
            duration: fields["duration"].flatMap(TimeInterval.init)
        )
        if case let .replaceWorkingPathAfterRead(bytes) = mode {
            try bytes.write(to: url, options: .atomic)
        }
        return metadata
    }

    func canWrite(url: URL) async -> Bool {
        writable
    }

    func write(url: URL, patch: MetadataPatch) async throws {
        writeURLs.append(url)
        writeStarted = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        waiters.forEach { $0.resume() }

        switch mode {
        case .writeFails:
            throw MetadataServiceError.saveFailed("fake write failure")
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
        case .normal, .verificationMismatch, .replaceWorkingFileInode,
             .mutateOriginal, .replaceWorkingPathAfterRead:
            break
        }

        var fields = try Self.readFields(url)
        if let artist = patch.artist { fields["artist"] = artist }
        if let album = patch.album { fields["album"] = album }
        let bytes = Self.encodedFields(fields)
        if case .replaceWorkingFileInode = mode {
            try Data("atomic replacement\n".utf8).write(to: url, options: .atomic)
            return
        }
        try writeInPlace(bytes, to: url)
        if case let .mutateOriginal(original, changedBytes, mtime) = mode {
            try writeInPlace(changedBytes, to: original)
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: original.path
            )
        }
    }

    func recordedWriteURLs() -> [URL] { writeURLs }
    func recordedReadURLs() -> [URL] { readURLs }

    func waitUntilWriteStarts() async {
        if writeStarted { return }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    private static func readFields(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
    }

    private static func encodedFields(_ fields: [String: String]) -> Data {
        let preferredOrder = ["title", "artist", "album", "duration", "custom"]
        let orderedKeys = preferredOrder.filter { fields[$0] != nil }
            + fields.keys.filter { !preferredOrder.contains($0) }.sorted()
        let text = orderedKeys.map { "\($0)=\(fields[$0]!)" }.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }
}

private extension FakeSafeMetadataService.Mode {
    var isVerificationMismatch: Bool {
        if case .verificationMismatch = self { return true }
        return false
    }
}

private struct TemporaryAudioDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createAudioFile() throws -> URL {
        let file = url.appendingPathComponent("song.mp3")
        let contents = """
        title=原始标题
        artist=原作者
        album=原专辑
        duration=123
        custom=必须保留

        """
        try Data(contents.utf8).write(to: file)
        return file
    }

    func temporaryWorkFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".audio-toolbox-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class LockedIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String]

    init(_ identifiers: [String]) {
        self.identifiers = identifiers
    }

    func next() -> String {
        lock.withLock {
            identifiers.isEmpty ? UUID().uuidString : identifiers.removeFirst()
        }
    }
}

private enum FakeWriterError: Error {
    case swapFailed
}

private func testFileOperations() -> SafeMetadataFileOperations {
    SafeMetadataFileOperations.live().overriding(
        coordinateReplacing: { original, temporary, accessor in
            try accessor(original, temporary)
        }
    )
}

private func makeTestWriter(
    metadataService: any MetadataService
) -> SafeMetadataWriter {
    SafeMetadataWriter(
        metadataService: metadataService,
        fileOperations: testFileOperations(),
        commitGate: { !Task.isCancelled },
        temporaryIdentifierProvider: { UUID().uuidString }
    )
}

private func writeInPlace(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func sameFileSystemPath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
        == rhs.standardizedFileURL.resolvingSymlinksInPath().path
}

private func setExtendedAttribute(_ data: Data, named name: String, at url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
}

private func extendedAttribute(named name: String, at url: URL) throws -> Data {
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    var data = Data(count: size)
    let readCount = data.withUnsafeMutableBytes { bytes in
        getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
    }
    guard readCount == size else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    return data
}
