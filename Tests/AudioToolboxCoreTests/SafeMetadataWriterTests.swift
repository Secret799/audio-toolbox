import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("SafeMetadataWriterTests")
struct SafeMetadataWriterTests {
    @Test
    func failedMetadataWriteLeavesOriginalBytesUntouchedAndCleansTemporaryCopy() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(mode: .writeFails)
        let writer = SafeMetadataWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.url == original)
        #expect(result.status == .failed)
        #expect(result.message?.contains("写入") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
        let writeURLs = await service.recordedWriteURLs()
        #expect(writeURLs.count == 1)
        #expect(writeURLs.first != original)
        #expect(writeURLs.first?.deletingLastPathComponent() == original.deletingLastPathComponent())
        #expect(writeURLs.first?.lastPathComponent.hasPrefix(".audio-toolbox-") == true)
        #expect(writeURLs.first?.pathExtension == original.pathExtension)
    }

    @Test
    func verificationFailureLeavesOriginalBytesUntouchedAndCleansTemporaryCopy() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(mode: .verificationMismatch)
        let writer = SafeMetadataWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: "新专辑")
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("验证") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func copyFailureDoesNotWriteOrChangeOriginal() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService()
        let operations = SafeMetadataFileOperations(
            copyItem: { _, destination in
                try Data("partial copy".utf8).write(to: destination)
                throw FakeWriterError.copyFailed
            },
            replaceItem: { _, _ in Issue.record("replaceItem 不应被调用"); return nil }
        )
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileManager: .default,
            fileOperations: operations,
            temporaryIdentifierProvider: { "copy-failure" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("副本") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func replaceFailureLeavesOriginalAvailableAndCleansTemporaryCopy() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService()
        let operationFileManager = FileManager()
        let operations = SafeMetadataFileOperations(
            copyItem: { source, destination in
                try operationFileManager.copyItem(at: source, to: destination)
            },
            replaceItem: { _, _ in throw FakeWriterError.replaceFailed }
        )
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileManager: FileManager(),
            fileOperations: operations,
            temporaryIdentifierProvider: { "replace-failure" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: "新专辑")
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("替换") == true)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func successfulWriteVerifiesPatchSafelyReplacesOriginalAndPreservesOtherFields() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(metadataService: service)
        let patch = MetadataPatch(artist: "新作者", album: "新专辑")

        let result = await writer.apply(to: original, patch: patch)

        #expect(result.url == original)
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

        let writeURLs = await service.recordedWriteURLs()
        let readURLs = await service.recordedReadURLs()
        #expect(writeURLs.count == 1)
        #expect(readURLs == writeURLs)
        #expect(writeURLs.first != original)
        #expect(writeURLs.first.map(AudioFileCandidate.format(for:)) == .mp3)
        #expect(writeURLs.first.map { AudioFileCandidate.shouldSkip($0, values: URLResourceValues()) } == true)
    }

    @Test
    func existingCollidingTemporaryFileIsNeverDeletedAndNextNameIsUsed() async throws {
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
            fileManager: .default,
            fileOperations: .live(fileManager: .default),
            temporaryIdentifierProvider: { identifiers.next() }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(try Data(contentsOf: collision) == collisionBytes)
        let remainingTemporaryFiles = try directory.temporaryWorkFiles()
        #expect(remainingTemporaryFiles.map(\.lastPathComponent) == [collision.lastPathComponent])
        let writeURLs = await service.recordedWriteURLs()
        #expect(writeURLs.first?.lastPathComponent == ".audio-toolbox-fresh.mp3")
    }


    @Test
    func successfulReplacementPreservesOriginalPermissions() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: original.path
        )
        let writer = SafeMetadataWriter(metadataService: FakeSafeMetadataService())

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value

        #expect(result.status == .succeeded)
        #expect(permissions == 0o640)
    }

    @Test
    func exhaustingTemporaryNameCollisionsFailsWithoutDeletingExistingFile() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let collision = directory.url.appendingPathComponent(".audio-toolbox-collision.mp3")
        let collisionBytes = Data("existing collision".utf8)
        try collisionBytes.write(to: collision)
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(
            metadataService: service,
            fileManager: .default,
            fileOperations: .live(fileManager: .default),
            temporaryIdentifierProvider: { "collision" }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("临时文件名") == true)
        #expect(try Data(contentsOf: collision) == collisionBytes)
        #expect(await service.recordedWriteURLs().isEmpty)
    }

    @Test
    func preflightRejectsUnsupportedWriteWithoutCreatingTemporaryCopy() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(canWrite: false)
        let writer = SafeMetadataWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("不支持") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
        #expect(await service.recordedWriteURLs().isEmpty)
    }


    @Test
    func preflightRejectsUnreadableAndUnwritableFiles() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let unreadable = directory.url.appendingPathComponent("unreadable.mp3")
        let unwritable = directory.url.appendingPathComponent("unwritable.mp3")
        try Data("unreadable".utf8).write(to: unreadable)
        try Data("unwritable".utf8).write(to: unwritable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o200],
            ofItemAtPath: unreadable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: unwritable.path
        )
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(metadataService: service)

        let unreadableResult = await writer.apply(
            to: unreadable,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )
        let unwritableResult = await writer.apply(
            to: unwritable,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(unreadableResult.status == .failed)
        #expect(unreadableResult.message?.contains("不可读") == true)
        #expect(unwritableResult.status == .failed)
        #expect(unwritableResult.message?.contains("不可写") == true)
        #expect(await service.recordedWriteURLs().isEmpty)
    }

    @Test
    func missingAndNonRegularFilesFailPreflight() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let service = FakeSafeMetadataService()
        let writer = SafeMetadataWriter(metadataService: service)
        let missing = directory.url.appendingPathComponent("missing.mp3")
        let subdirectory = directory.url.appendingPathComponent("folder.mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)

        let missingResult = await writer.apply(
            to: missing,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )
        let directoryResult = await writer.apply(
            to: subdirectory,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(missingResult.status == .failed)
        #expect(missingResult.message?.contains("不存在") == true)
        #expect(directoryResult.status == .failed)
        #expect(directoryResult.message?.contains("普通文件") == true)
        #expect(await service.recordedWriteURLs().isEmpty)
    }


    @Test
    func concurrentOriginalChangeIsNotOverwrittenDuringReplacement() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let concurrentBytes = Data("concurrent external change".utf8)
        let service = FakeSafeMetadataService(
            mode: .mutateOriginalDuringWrite(original, concurrentBytes)
        )
        let writer = SafeMetadataWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("发生变化") == true)
        #expect(try Data(contentsOf: original) == concurrentBytes)
        #expect(try directory.temporaryWorkFiles().isEmpty)
    }

    @Test
    func cancellationDuringWriteCleansTemporaryCopyAndDoesNotReplaceOriginal() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(mode: .waitForCancellation)
        let writer = SafeMetadataWriter(metadataService: service)
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
}

private actor FakeSafeMetadataService: MetadataService {
    enum Mode: Sendable {
        case normal
        case writeFails
        case verificationMismatch
        case waitForCancellation
        case mutateOriginalDuringWrite(URL, Data)
    }

    private let mode: Mode
    private let writable: Bool
    private var writeURLs: [URL] = []
    private var readURLs: [URL] = []
    private var writeStarted = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode = .normal, canWrite: Bool = true) {
        self.mode = mode
        self.writable = canWrite
    }

    func read(url: URL) async throws -> AudioMetadata {
        readURLs.append(url)
        let fields = try Self.readFields(url)
        let artist: String?
        if case .verificationMismatch = mode {
            artist = "验证不匹配"
        } else {
            artist = fields["artist"]
        }
        return AudioMetadata(
            title: fields["title"],
            artists: artist.map { [$0] } ?? [],
            albums: fields["album"].map { [$0] } ?? [],
            duration: fields["duration"].flatMap(TimeInterval.init)
        )
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
        case .normal, .verificationMismatch, .mutateOriginalDuringWrite:
            break
        }

        var fields = try Self.readFields(url)
        if let artist = patch.artist { fields["artist"] = artist }
        if let album = patch.album { fields["album"] = album }
        try Self.writeFields(fields, to: url)
        if case let .mutateOriginalDuringWrite(original, bytes) = mode {
            try bytes.write(to: original)
        }
    }

    func recordedWriteURLs() -> [URL] {
        writeURLs
    }

    func recordedReadURLs() -> [URL] {
        readURLs
    }

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

    private static func writeFields(_ fields: [String: String], to url: URL) throws {
        let preferredOrder = ["title", "artist", "album", "duration", "custom"]
        let orderedKeys = preferredOrder.filter { fields[$0] != nil }
            + fields.keys.filter { !preferredOrder.contains($0) }.sorted()
        let text = orderedKeys.map { "\($0)=\(fields[$0]!)" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
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
    case copyFailed
    case replaceFailed
}
