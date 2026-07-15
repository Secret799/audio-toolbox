import Darwin
import Foundation
import Testing
@testable import AudioToolboxCore

@Suite("SafeMetadataWriterTests")
struct SafeMetadataWriterTests {
    @Test
    func successfulCommitUsesPrivateWorkDirectoryAndPreservesModeXattrAndMetadata() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
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
        #expect(try directory.workDirectories().isEmpty)
        let savedText = try String(contentsOf: original, encoding: .utf8)
        #expect(savedText.contains("title=原始标题"))
        #expect(savedText.contains("artist=新作者"))
        #expect(savedText.contains("album=新专辑"))
        #expect(savedText.contains("custom=必须保留"))
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o640)
        #expect(try extendedAttribute(named: xattrName, at: original) == xattrValue)

        let writeURL = try #require(await service.recordedWriteURLs().first)
        #expect(writeURL.lastPathComponent == "working.mp3")
        #expect(writeURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".audio-toolbox-"))
        #expect(writeURL.deletingLastPathComponent().lastPathComponent.hasSuffix(".work"))
        #expect(writeURL.deletingLastPathComponent().deletingLastPathComponent()
            == original.deletingLastPathComponent())
        #expect(AudioFileCandidate.shouldSkip(writeURL, values: URLResourceValues()))
        #expect(await service.recordedReadURLs() == [writeURL])
        #expect(await service.recordedWorkDirectoryPermissions() == 0o700)
    }

    @Test
    func scannedTargetPathReplacementIsRejectedBeforeCopyOrMetadataWrite() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let replacement = directory.url.appendingPathComponent("replacement.mp3")
        let replacementBytes = Data("title=替换文件\nartist=替换作者\nalbum=替换专辑\n".utf8)
        try replacementBytes.write(to: replacement)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)
        let service = FakeSafeMetadataService()
        let copyCount = LockedCounter()
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { source, workspace, flag in
            _ = copyCount.incrementAndGet()
            return try live.copyIntoWorkspace(source, workspace, flag)
        })
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "不应写入", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message == "文件已变化，请重新扫描确认")
        #expect(copyCount.value == 0)
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try Data(contentsOf: original) == replacementBytes)
    }

    @Test
    func scannedTargetSameInodeFingerprintChangeIsRejectedBeforeCopyOrMetadataWrite() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let changedBytes = Data("title=同 inode 已变化\nartist=原作者\nalbum=原专辑\nextra=changed\n".utf8)
        try writeInPlace(changedBytes, to: original)
        let changedFingerprint = try StableFileIdentityResolver.fingerprint(for: original)
        #expect(changedFingerprint.fileIdentity == target.fileIdentity)
        #expect(
            changedFingerprint.fileSize != target.fileSize
                || changedFingerprint.modificationDate != target.modificationDate
        )
        let service = FakeSafeMetadataService()
        let copyCount = LockedCounter()
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { source, workspace, flag in
            _ = copyCount.incrementAndGet()
            return try live.copyIntoWorkspace(source, workspace, flag)
        })
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "不应写入", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message == "文件已变化，请重新扫描确认")
        #expect(copyCount.value == 0)
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try Data(contentsOf: original) == changedBytes)
    }

    @Test
    func unchangedScannedTargetCommitsSuccessfully() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService())

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
    }

    @Test
    func durableCommitSyncsWorkAndDirectoriesInRequiredOrder() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let calls = LockedStrings()
        let live = testFileOperations()
        let operations = live.overriding(
            swap: { originalURL, workURL in
                calls.append("swap")
                try live.swap(originalURL, workURL)
            },
            syncWorkspaceFile: { workspace, identity in
                calls.append("work-file")
                try live.syncWorkspaceFile(workspace, identity)
            },
            syncWorkspaceDirectory: { workspace in
                calls.append("workspace-dir")
                try live.syncWorkspaceDirectory(workspace)
            },
            syncURLFile: { url, identity in
                calls.append("original-file")
                try live.syncURLFile(url, identity)
            },
            syncParentDirectory: { workspace in
                calls.append("parent-dir")
                try live.syncParentDirectory(workspace)
            }
        )
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(calls.values == [
            "work-file", "workspace-dir", "swap", "original-file", "parent-dir"
        ])
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func preSwapSyncFailureDoesNotCommit() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let originalBytes = try Data(contentsOf: original)
        let swapCount = LockedCounter()
        let live = testFileOperations()
        let operations = live.overriding(
            swap: { originalURL, workURL in
                _ = swapCount.incrementAndGet()
                try live.swap(originalURL, workURL)
            },
            syncWorkspaceFile: { _, _ in
                throw SafeMetadataFileSystemError(operation: .sync, code: EIO)
            }
        )
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("耐久同步") == true)
        #expect(swapCount.value == 0)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func postSwapSyncFailureRollsBackAndSyncsRollbackBeforeCleanup() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let originalBytes = try Data(contentsOf: original)
        let calls = LockedStrings()
        let syncOriginalCount = LockedCounter()
        let live = testFileOperations()
        let operations = live.overriding(
            swap: { originalURL, workURL in
                calls.append("swap")
                try live.swap(originalURL, workURL)
            },
            syncWorkspaceFile: { workspace, identity in
                calls.append("work-file")
                try live.syncWorkspaceFile(workspace, identity)
            },
            syncWorkspaceDirectory: { workspace in
                calls.append("workspace-dir")
                try live.syncWorkspaceDirectory(workspace)
            },
            syncURLFile: { url, identity in
                calls.append("original-file")
                if syncOriginalCount.incrementAndGet() == 1 {
                    throw SafeMetadataFileSystemError(operation: .sync, code: EIO)
                }
                try live.syncURLFile(url, identity)
            },
            syncParentDirectory: { workspace in
                calls.append("parent-dir")
                try live.syncParentDirectory(workspace)
            }
        )
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("已安全回滚") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(calls.values == [
            "work-file", "workspace-dir", "swap", "original-file",
            "swap", "original-file", "work-file", "workspace-dir", "parent-dir"
        ])
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func postSwapSyncAndRollbackSyncFailureIsUncertainAndPreservesRecovery() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let target = try batchTarget(for: original)
        let originalBytes = try Data(contentsOf: original)
        let swapCount = LockedCounter()
        let live = testFileOperations()
        let operations = live.overriding(
            swap: { originalURL, workURL in
                _ = swapCount.incrementAndGet()
                try live.swap(originalURL, workURL)
            },
            syncURLFile: { _, _ in
                throw SafeMetadataFileSystemError(operation: .sync, code: EIO)
            }
        )
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: target,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("提交状态不确定") == true)
        #expect(swapCount.value == 2)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.firstWorkFile() != nil)
    }

    @Test
    func privateWorkspaceDirectoryCollisionRetriesWithoutDeletingExistingDirectory() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let collision = directory.url.appendingPathComponent(".audio-toolbox-collision.work", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        let marker = collision.appendingPathComponent("marker")
        let markerBytes = Data("existing private directory".utf8)
        try markerBytes.write(to: marker)
        let identifiers = LockedIdentifiers(["collision", "fresh"])
        let service = FakeSafeMetadataService()
        let writer = makeTestWriter(
            metadataService: service,
            temporaryIdentifierProvider: { identifiers.next() }
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(try Data(contentsOf: marker) == markerBytes)
        #expect(try directory.workDirectories().map(\.lastPathComponent)
            == [collision.lastPathComponent])
        let writeURL = try #require(await service.recordedWriteURLs().first)
        #expect(writeURL.deletingLastPathComponent().lastPathComponent == ".audio-toolbox-fresh.work")
    }

    @Test
    func workingPathReplacedBeforeWriteIsRejectedWithoutTouchingCompetitor() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let competitorBytes = Data("competitor before write".utf8)
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { source, workspace, flag in
            let owned = try live.copyIntoWorkspace(source, workspace, flag)
            try competitorBytes.write(to: workspace.fileURL, options: .atomic)
            return owned
        })
        let service = FakeSafeMetadataService()
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("保守保留") == true)
        #expect(await service.recordedWriteURLs().isEmpty)
        let workFile = try #require(findFile(named: "working.mp3", under: directory.url))
        #expect(try Data(contentsOf: workFile) == competitorBytes)
    }

    @Test
    func metadataServiceReplacingWorkingInodeIsRejectedAndReplacementIsPreserved() async throws {
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
        #expect(try Data(contentsOf: original) == originalBytes)
        let workFile = try #require(try directory.firstWorkFile())
        #expect(try String(contentsOf: workFile, encoding: .utf8).contains("atomic replacement"))
    }

    @Test
    func verifiedWorkingFileCorruptedInPlaceAfterReadIsNeverCommitted() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let service = FakeSafeMetadataService(
            mode: .corruptWorkingAfterRead(Data("corrupted after verified read".utf8))
        )
        let writer = makeTestWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("已验证工作副本") == true)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func sameSizeOriginalChangeWithMaskedStatIsRejectedByDigest() async throws {
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
        let flag = try SafeMetadataCancellationFlag()
        let initial = try live.snapshotURL(original, flag)
        let operations = live.overriding(snapshotURL: { url, cancellationFlag in
            let actual = try live.snapshotURL(url, cancellationFlag)
            if sameFileSystemPath(url, original) {
                return SafeMetadataFileSnapshot(
                    nodeState: initial.nodeState,
                    digest: actual.digest,
                    fileSystemMetadata: actual.fileSystemMetadata
                )
            }
            return actual
        })
        let service = FakeSafeMetadataService(
            mode: .mutateOriginal(original, changedBytes, originalMtime)
        )
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message == "文件已变化，请重新扫描确认")
        #expect(try Data(contentsOf: original) == changedBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func originalChangedAfterFinalValidationIsRolledBackWithoutLosingConcurrentBytes() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let concurrentBytes = Data("concurrent bytes after final validation".utf8)
        let live = testFileOperations()
        let swapCount = LockedCounter()
        let operations = live.overriding(swap: { originalURL, workURL in
            let count = swapCount.incrementAndGet()
            if count == 1 {
                try writeInPlace(concurrentBytes, to: originalURL)
            }
            try live.swap(originalURL, workURL)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("已安全回滚") == true)
        #expect(swapCount.value == 2)
        #expect(try Data(contentsOf: original) == concurrentBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func postSwapMissingOriginalReturnsUncertainAndPreservesRecovery() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(swap: { originalURL, workURL in
            try live.swap(originalURL, workURL)
            try removePath(originalURL)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("提交状态不确定") == true)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let recovery = try #require(try directory.firstWorkFile())
        #expect(try Data(contentsOf: recovery) == originalBytes)
    }

    @Test
    func postSwapReplacedOriginalReturnsUncertainAndPreservesBothPaths() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let competitorBytes = Data("post-swap original competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(swap: { originalURL, workURL in
            try live.swap(originalURL, workURL)
            try competitorBytes.write(to: originalURL, options: .atomic)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("提交状态不确定") == true)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try directory.firstWorkFile() != nil)
    }

    @Test
    func postSwapMissingRecoveryReturnsUncertainEvenWhenOriginalLooksEdited() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(swap: { originalURL, workURL in
            try live.swap(originalURL, workURL)
            try removePath(workURL)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("提交状态不确定") == true)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
    }

    @Test
    func coordinatorTailErrorAfterConfirmedCommitReturnsSucceededWarning() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(coordinateReplacing: { original, work, accessor in
            try accessor(original, work)
            throw FakeWriterError.coordinatorTailFailed
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .succeeded)
        #expect(result.message?.contains("协调收尾") == true)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func coordinatorTailErrorAfterRollbackStillReturnsFailedRolledBack() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let concurrentBytes = Data("rollback with coordinator tail".utf8)
        let live = testFileOperations()
        let swapCount = LockedCounter()
        let operations = live.overriding(
            coordinateReplacing: { original, work, accessor in
                try accessor(original, work)
                throw FakeWriterError.coordinatorTailFailed
            },
            swap: { originalURL, workURL in
                if swapCount.incrementAndGet() == 1 {
                    try writeInPlace(concurrentBytes, to: originalURL)
                }
                try live.swap(originalURL, workURL)
            }
        )
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("已安全回滚") == true)
        #expect(result.message?.contains("协调收尾") == true)
        #expect(try Data(contentsOf: original) == concurrentBytes)
    }

    @Test
    func finalCommitGateCancellationDoesNotSwapAndRemovesWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(),
            commitGate: { false }
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .notProcessed)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func cancellationAfterCommitGateIsBestEffortAndSuccessfulSwapWins() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(swap: { originalURL, workURL in
            withUnsafeCurrentTask { task in task?.cancel() }
            try live.swap(originalURL, workURL)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await Task {
            await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))
        }.value

        #expect(result.status == .succeeded)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("artist=新作者"))
    }

    @Test
    func oldOriginalCleanupPermissionFailureReturnsSucceededWarningAndRecoveryPath() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(removeWorkspaceFileIfOwned: { workspace, _ in
            .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: EACCES),
                preservedURL: workspace.fileURL
            )
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .succeeded)
        #expect(result.message?.contains("恢复文件路径") == true)
        #expect(result.message?.contains("没有删除权限") == true)
        let recovery = try #require(try directory.firstWorkFile())
        #expect(try Data(contentsOf: recovery) == originalBytes)
    }

    @Test
    func cleanupCompetitorReplacementIsConservativelyPreserved() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let competitorBytes = Data("cleanup competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(removeWorkspaceFileIfOwned: { workspace, expected in
            SafeMetadataFileOperations.removeWorkspaceFileIfOwnedForTesting(
                workspace,
                expectedIdentity: expected,
                afterQuarantineValidation: { quarantineURL in
                    try? competitorBytes.write(to: quarantineURL, options: .atomic)
                }
            )
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .writeFails),
            operations: operations
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("保守保留") == true)
        let workFile = try #require(try directory.firstWorkFile())
        #expect(try Data(contentsOf: workFile) == competitorBytes)
    }

    @Test
    func outerWorkspacePathReplacementDoesNotDeleteCompetitorDirectory() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let markerBytes = Data("directory competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(removeWorkspaceDirectoryIfOwned: { workspace in
            let moved = workspace.directoryURL.deletingLastPathComponent()
                .appendingPathComponent(".audio-toolbox-owned-moved.work", isDirectory: true)
            try? FileManager.default.moveItem(at: workspace.directoryURL, to: moved)
            try? FileManager.default.createDirectory(at: workspace.directoryURL, withIntermediateDirectories: false)
            try? markerBytes.write(to: workspace.directoryURL.appendingPathComponent("marker"))
            return live.removeWorkspaceDirectoryIfOwned(workspace)
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .writeFails),
            operations: operations
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("目录路径身份已变化") == true)
        #expect(try Data(contentsOf: directory.url
            .appendingPathComponent(resultWorkspaceName(from: result.message))
            .appendingPathComponent("marker")) == markerBytes)
    }

    @Test
    func cancellingSlowInitialSnapshotReturnsWithinBoundWithoutSwap() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(snapshotURL: { url, flag in
            while !flag.isCancelled {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw CancellationError()
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        let elapsed = started.duration(to: clock.now)

        #expect(result.status == .notProcessed)
        #expect(elapsed < .milliseconds(500))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
        _ = live
    }

    @Test
    func cancellingSlowCopyReturnsWithinBoundAndRemovesPrivateWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let copyStarted = AsyncSignal()
        let operations = live.overriding(copyIntoWorkspace: { _, _, flag in
            copyStarted.signal()
            while !flag.isCancelled {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw CancellationError()
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)
        let clock = ContinuousClock()
        let task = Task {
            await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))
        }

        await copyStarted.wait()
        let startedCancel = clock.now
        task.cancel()
        let result = await task.value
        let elapsed = startedCancel.duration(to: clock.now)

        #expect(result.status == .notProcessed)
        #expect(elapsed < .milliseconds(500))
        #expect(try directory.workDirectories().isEmpty)
    }


    @Test
    func cancellingCommitPhaseDigestExitsBeforeSwapWithinBound() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let snapshotCount = LockedCounter()
        let commitDigestStarted = AsyncSignal()
        let operations = live.overriding(snapshotURL: { url, flag in
            if sameFileSystemPath(url, original), snapshotCount.incrementAndGet() >= 2 {
                commitDigestStarted.signal()
                while !flag.isCancelled {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw CancellationError()
            }
            return try live.snapshotURL(url, flag)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)
        let task = Task {
            await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))
        }

        await commitDigestStarted.wait()
        let clock = ContinuousClock()
        let startedCancel = clock.now
        task.cancel()
        let result = await task.value
        let elapsed = startedCancel.duration(to: clock.now)

        #expect(result.status == .notProcessed)
        #expect(elapsed < .milliseconds(500))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func nonWritableOriginalFailsWithoutChangingOrRemovingOriginal() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let operations = testFileOperations().overriding(isWritable: { _ in false })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(),
            operations: operations
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func workingFileCreationFailureLeavesOriginalUntouchedAndCleansWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { _, _, _ in
            throw SafeMetadataFileSystemError(operation: .copy, code: EACCES)
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(),
            operations: operations
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func metadataSaveFailureLeavesOriginalUntouchedAndCleansWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .writeFails)
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: "新专辑")
        )

        #expect(result.status == .failed)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func metadataVerificationFailureLeavesOriginalUntouchedAndCleansWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .verificationMismatch)
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: "新专辑")
        )

        #expect(result.status == .failed)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func atomicReplaceFailureLeavesOriginalUntouchedAndCleansWorkspace() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        let live = testFileOperations()
        let operations = live.overriding(swap: { _, _ in
            throw SafeMetadataFileSystemError(operation: .swap, code: EIO)
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(),
            operations: operations
        )

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func legacyTemporaryFileIsIgnoredAndPreserved() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let legacyTemporaryFile = directory.url.appendingPathComponent(
            ".audio-toolbox-legacy.tmp"
        )
        let legacyBytes = Data("legacy recovery data".utf8)
        try legacyBytes.write(to: legacyTemporaryFile)
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService())

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: legacyTemporaryFile.path))
        #expect(try Data(contentsOf: legacyTemporaryFile) == legacyBytes)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func symlinkHardLinkAndUnsupportedFilesAreRejected() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let symlink = directory.url.appendingPathComponent("symlink.mp3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let hardLink = directory.url.appendingPathComponent("hardlink.mp3")
        try FileManager.default.linkItem(at: original, to: hardLink)
        let patch = MetadataPatch(artist: "新作者", album: nil)

        let normalWriter = makeTestWriter(metadataService: FakeSafeMetadataService())
        let symlinkResult = await normalWriter.apply(to: symlink, patch: patch)
        let hardLinkResult = await normalWriter.apply(to: original, patch: patch)
        try FileManager.default.removeItem(at: hardLink)
        let unsupportedWriter = makeTestWriter(metadataService: FakeSafeMetadataService(writable: false))
        let unsupportedResult = await unsupportedWriter.apply(to: original, patch: patch)

        #expect(symlinkResult.message?.contains("符号链接") == true)
        #expect(hardLinkResult.message?.contains("硬链接") == true)
        #expect(unsupportedResult.message?.contains("不支持") == true)
    }


    @Test
    func liveCopyfileBridgeHonorsCancellationFlagBeforeCopy() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let operations = testFileOperations()
        let workspace = try operations.createWorkspace(original, "bridge-cancel")
        let flag = try SafeMetadataCancellationFlag()
        flag.cancel()

        do {
            _ = try operations.copyIntoWorkspace(original, workspace, flag)
            Issue.record("取消后的 copyfile 不应成功")
        } catch let error as SafeMetadataFileSystemError {
            #expect(error.code == ECANCELED)
        }

        let directoryRemoval = operations.removeWorkspaceDirectoryIfOwned(workspace)
        workspace.closeDescriptors()
        if case .removed = directoryRemoval {
            // expected
        } else {
            Issue.record("取消前未创建 working 文件，私有目录应可直接删除")
        }
        #expect(try directory.workDirectories().isEmpty)
    }


    @Test
    func metadataServiceRemovingPreservedXattrAndModeIsRejected() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
        let xattrName = "com.audio-toolbox.preserved-test"
        let xattrValue = Data("preserved metadata".utf8)
        try setExtendedAttribute(xattrValue, named: xattrName, at: original)
        let service = FakeSafeMetadataService(
            mode: .removeWorkingMetadata(xattrName, 0o600)
        )
        let writer = makeTestWriter(metadataService: service)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("文件系统属性") == true)
        #expect(try extendedAttribute(named: xattrName, at: original) == xattrValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o640)
    }

    @Test
    func finalWindowOriginalXattrChangeTriggersRollbackAndPreservesConcurrentMetadata() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let xattrName = "com.audio-toolbox.concurrent-xattr"
        let initialValue = Data("initial".utf8)
        let concurrentValue = Data("concurrent".utf8)
        try setExtendedAttribute(initialValue, named: xattrName, at: original)
        let live = testFileOperations()
        let swaps = LockedCounter()
        let operations = live.overriding(swap: { originalURL, workURL in
            if swaps.incrementAndGet() == 1 {
                try setExtendedAttribute(concurrentValue, named: xattrName, at: originalURL)
            }
            try live.swap(originalURL, workURL)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("已安全回滚") == true)
        #expect(swaps.value == 2)
        #expect(try extendedAttribute(named: xattrName, at: original) == concurrentValue)
    }

    @Test
    func fileQuarantineReplacementAfterFirstValidationIsNeverDeleted() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let competitorBytes = Data("quarantine file competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(removeWorkspaceFileIfOwned: { workspace, expected in
            SafeMetadataFileOperations.removeWorkspaceFileIfOwnedForTesting(
                workspace,
                expectedIdentity: expected,
                afterQuarantineValidation: { quarantineURL in
                    try? competitorBytes.write(to: quarantineURL, options: .atomic)
                }
            )
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .writeFails),
            operations: operations
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("保守保留") == true)
        let preserved = try #require(try directory.firstWorkFile())
        #expect(try Data(contentsOf: preserved) == competitorBytes)
    }

    @Test
    func directoryQuarantineReplacementAfterFirstValidationIsNeverDeleted() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let markerBytes = Data("quarantine directory competitor".utf8)
        let live = testFileOperations()
        let operations = live.overriding(removeWorkspaceDirectoryIfOwned: { workspace in
            SafeMetadataFileOperations.removeWorkspaceDirectoryIfOwnedForTesting(
                workspace,
                afterQuarantineValidation: { quarantineURL in
                    let moved = quarantineURL.deletingLastPathComponent()
                        .appendingPathComponent(".audio-toolbox-owned-quarantine-moved.work")
                    try? FileManager.default.moveItem(at: quarantineURL, to: moved)
                    try? FileManager.default.createDirectory(
                        at: quarantineURL,
                        withIntermediateDirectories: false
                    )
                    try? markerBytes.write(to: quarantineURL.appendingPathComponent("marker"))
                }
            )
        })
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(mode: .writeFails),
            operations: operations
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .failed)
        #expect(result.message?.contains("保守保留") == true)
        let marker = try #require(findFile(named: "marker", under: directory.url))
        #expect(try Data(contentsOf: marker) == markerBytes)
    }

    @Test
    func successfulCommitUsesSixCoordinationDigestsAndFourAfterGate() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let budget = LockedIOBudget()
        let operations = live.overriding(
            snapshotURL: { url, flag in
                budget.recordDigestIfCoordinating()
                return try live.snapshotURL(url, flag)
            },
            snapshotWorkspace: { workspace, flag in
                budget.recordDigestIfCoordinating()
                return try live.snapshotWorkspace(workspace, flag)
            },
            coordinateReplacing: { original, work, accessor in
                budget.setCoordinating(true)
                defer { budget.setCoordinating(false) }
                try accessor(original, work)
            }
        )
        let writer = makeTestWriter(
            metadataService: FakeSafeMetadataService(),
            operations: operations,
            commitGate: {
                budget.markGatePassed()
                return true
            }
        )

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

        #expect(result.status == .succeeded)
        #expect(budget.coordinationDigests == 6)
        #expect(budget.postGateDigests == 4)
    }

    @Test
    func realInFlightCopyCancellationReturnsOwnedPartialFileForCleanup() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createLargeFile(megabytes: 32)
        let operations = testFileOperations()
        let workspace = try operations.createWorkspace(original, "inflight-copy-cancel")
        let flag = try SafeMetadataCancellationFlag()
        flag.setCopyCallbackDelayForTesting(microseconds: 50_000)
        let copyTask = Task.detached(priority: .utility) {
            try operations.copyIntoWorkspace(original, workspace, flag)
        }

        try await waitUntilFileExists(workspace.fileURL)
        flag.cancel()
        let ownedIdentity: SafeMetadataFileIdentity?
        do {
            _ = try await copyTask.value
            Issue.record("in-flight copy 取消后不应成功")
            ownedIdentity = nil
        } catch let error as SafeMetadataFileSystemError {
            #expect(error.code == ECANCELED)
            ownedIdentity = error.ownedNodeState?.identity
        }

        let identity = try #require(ownedIdentity)
        let removal = operations.removeWorkspaceFileIfOwned(workspace, identity)
        if case .removed = removal {
            // expected
        } else {
            Issue.record("部分副本应可按 owned inode 清理")
        }
        let directoryRemoval = operations.removeWorkspaceDirectoryIfOwned(workspace)
        workspace.closeDescriptors()
        if case .removed = directoryRemoval {
            // expected
        } else {
            Issue.record("清理部分副本后私有目录应可删除")
        }
    }

    @Test
    func dirfdCopyContinuesIntoOwnedDirectoryAfterWorkspacePathReplacement() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createLargeFile(megabytes: 2)
        let operations = testFileOperations()
        let workspace = try operations.createWorkspace(original, "dirfd-anchor")
        let movedOwnedDirectory = directory.url.appendingPathComponent(
            ".audio-toolbox-dirfd-owned-moved.work",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: workspace.directoryURL, to: movedOwnedDirectory)
        try FileManager.default.createDirectory(
            at: workspace.directoryURL,
            withIntermediateDirectories: false
        )
        let competitorMarker = workspace.directoryURL.appendingPathComponent("competitor")
        try Data("competitor".utf8).write(to: competitorMarker)
        let flag = try SafeMetadataCancellationFlag()

        let copied = try operations.copyIntoWorkspace(original, workspace, flag)

        #expect(copied.isRegularFile)
        #expect(FileManager.default.fileExists(
            atPath: movedOwnedDirectory.appendingPathComponent("working.mp3").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: workspace.directoryURL.appendingPathComponent("working.mp3").path
        ))
        #expect(try Data(contentsOf: competitorMarker) == Data("competitor".utf8))
        workspace.closeDescriptors()
    }

    @Test
    func copyThatDropsXattrAndChangesModeIsRejectedBeforeMetadataWrite() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let originalBytes = try Data(contentsOf: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
        let xattrName = "com.audio-toolbox.copy-baseline"
        let xattrValue = Data("copy baseline metadata".utf8)
        try setExtendedAttribute(xattrValue, named: xattrName, at: original)
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { source, workspace, flag in
            let copied = try live.copyIntoWorkspace(source, workspace, flag)
            guard removexattr(workspace.fileURL.path, xattrName, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno)!)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: workspace.fileURL.path
            )
            return copied
        })
        let service = FakeSafeMetadataService()
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message?.contains("复制后的文件属性或内容不完整") == true)
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try extendedAttribute(named: xattrName, at: original) == xattrValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o640)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test(arguments: [UInt16(S_ISUID), UInt16(S_ISGID)])
    func privilegedSourceModeIsRejectedBeforeWorkspaceCreation(privilegedBit: UInt16) async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(snapshotURL: { url, flag in
            let snapshot = try live.snapshotURL(url, flag)
            return SafeMetadataFileSnapshot(
                nodeState: replacingNodeState(
                    snapshot.nodeState,
                    mode: snapshot.nodeState.mode | privilegedBit
                ),
                digest: snapshot.digest,
                fileSystemMetadata: snapshot.fileSystemMetadata
            )
        })
        let service = FakeSafeMetadataService()
        let writer = makeTestWriter(metadataService: service, operations: operations)

        let result = await writer.apply(
            to: original,
            patch: MetadataPatch(artist: "新作者", album: nil)
        )

        #expect(result.status == .failed)
        #expect(result.message == "文件包含 setuid/setgid 特权位，已拒绝编辑")
        #expect(await service.recordedWriteURLs().isEmpty)
        #expect(try directory.workDirectories().isEmpty)
    }

    @Test
    func copiedInputEquivalenceChecksEveryRequiredFieldAndIgnoresNewIdentityAndCtime() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let operations = testFileOperations()
        let flag = try SafeMetadataCancellationFlag()
        let initial = try operations.snapshotURL(original, flag)
        let copiedState = replacingNodeState(
            initial.nodeState,
            device: initial.nodeState.device + 1,
            inode: initial.nodeState.inode + 1,
            statusChangeSeconds: initial.nodeState.statusChangeSeconds + 1,
            statusChangeNanoseconds: initial.nodeState.statusChangeNanoseconds + 1
        )
        let copied = SafeMetadataFileSnapshot(
            nodeState: copiedState,
            digest: initial.digest,
            fileSystemMetadata: initial.fileSystemMetadata
        )

        #expect(copied.isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, size: copiedState.size + 1),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(
                copiedState,
                modificationSeconds: copiedState.modificationSeconds + 1
            ),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(
                copiedState,
                modificationNanoseconds: copiedState.modificationNanoseconds + 1
            ),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, mode: copiedState.mode ^ 0o020),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, ownerID: copiedState.ownerID + 1),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, groupID: copiedState.groupID + 1),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, flags: copiedState.flags ^ 0x1),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: copiedState,
            digest: Data(repeating: 0xFF, count: copied.digest.count),
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: copiedState,
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata + Data([0x01])
        ).isEquivalentTransactionInput(to: initial))
        #expect(!SafeMetadataFileSnapshot(
            nodeState: replacingNodeState(copiedState, linkCount: 2),
            digest: copied.digest,
            fileSystemMetadata: copied.fileSystemMetadata
        ).isEquivalentTransactionInput(to: initial))
    }

    @Test
    func copyNoSpaceErrorUsesStableChineseMessage() async throws {
        let directory = try TemporaryAudioDirectory()
        defer { directory.remove() }
        let original = try directory.createAudioFile()
        let live = testFileOperations()
        let operations = live.overriding(copyIntoWorkspace: { _, _, _ in
            throw SafeMetadataFileSystemError(operation: .copy, code: ENOSPC)
        })
        let writer = makeTestWriter(metadataService: FakeSafeMetadataService(), operations: operations)

        let result = await writer.apply(to: original, patch: MetadataPatch(artist: "新作者", album: nil))

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
        case replaceWorkingFileInode
        case mutateOriginal(URL, Data, Date)
        case corruptWorkingAfterRead(Data)
        case removeWorkingMetadata(String, UInt16)
    }

    private let mode: Mode
    private let writable: Bool
    private var writeURLs: [URL] = []
    private var readURLs: [URL] = []
    private var workDirectoryPermissions: UInt16?

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
        if case let .corruptWorkingAfterRead(bytes) = mode {
            try writeInPlace(bytes, to: url)
        }
        return metadata
    }

    func canWrite(url: URL) async -> Bool { writable }

    func write(url: URL, patch: MetadataPatch) async throws {
        writeURLs.append(url)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        workDirectoryPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        if case .writeFails = mode {
            throw MetadataServiceError.saveFailed("fake write failure")
        }

        var fields = try Self.readFields(url)
        if let artist = patch.artist { fields["artist"] = artist }
        if let album = patch.album { fields["album"] = album }
        if case .replaceWorkingFileInode = mode {
            try Data("atomic replacement\n".utf8).write(to: url, options: .atomic)
            return
        }
        try writeInPlace(Self.encodedFields(fields), to: url)
        if case let .removeWorkingMetadata(xattrName, mode) = mode {
            _ = removexattr(url.path, xattrName, 0)
            try FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: url.path
            )
        }
        if case let .mutateOriginal(original, changedBytes, mtime) = mode {
            try writeInPlace(changedBytes, to: original)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: original.path)
        }
    }

    func recordedWriteURLs() -> [URL] { writeURLs }
    func recordedReadURLs() -> [URL] { readURLs }
    func recordedWorkDirectoryPermissions() -> UInt16? { workDirectoryPermissions }

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

    func createLargeFile(megabytes: Int) throws -> URL {
        let file = url.appendingPathComponent("large.mp3")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x5A, count: 1024 * 1024)
        for _ in 0..<megabytes {
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
        return file
    }

    func workDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix(".audio-toolbox-")
                    && $0.lastPathComponent.hasSuffix(".work")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func firstWorkFile() throws -> URL? {
        for workDirectory in try workDirectories() {
            let entries = try FileManager.default.contentsOfDirectory(
                at: workDirectory,
                includingPropertiesForKeys: nil
            )
            if let first = entries.first { return first }
        }
        return nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class LockedIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String]

    init(_ identifiers: [String]) { self.identifiers = identifiers }

    func next() -> String {
        lock.withLock {
            identifiers.isEmpty ? UUID().uuidString : identifiers.removeFirst()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func incrementAndGet() -> Int {
        lock.withLock {
            storedValue += 1
            return storedValue
        }
    }

    var value: Int { lock.withLock { storedValue } }
}

private final class LockedIOBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinating = false
    private var gatePassed = false
    private var storedCoordinationDigests = 0
    private var storedPostGateDigests = 0

    func setCoordinating(_ value: Bool) {
        lock.withLock { coordinating = value }
    }

    func markGatePassed() {
        lock.withLock { gatePassed = true }
    }

    func recordDigestIfCoordinating() {
        lock.withLock {
            guard coordinating else { return }
            storedCoordinationDigests += 1
            if gatePassed { storedPostGateDigests += 1 }
        }
    }

    var coordinationDigests: Int { lock.withLock { storedCoordinationDigests } }
    var postGateDigests: Int { lock.withLock { storedPostGateDigests } }
}

private final class AsyncSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var signaled = false

    func signal() {
        condition.withLock {
            signaled = true
            condition.broadcast()
        }
    }

    func wait() async {
        await Task.detached(priority: .utility) {
            self.condition.withLock {
                while !self.signaled { self.condition.wait() }
            }
        }.value
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func append(_ value: String) {
        lock.withLock { storedValues.append(value) }
    }
}

private func batchTarget(for url: URL) throws -> BatchEditTarget {
    let fingerprint = try StableFileIdentityResolver.fingerprint(for: url)
    return BatchEditTarget(
        url: url,
        fileIdentity: fingerprint.fileIdentity,
        fileSize: fingerprint.fileSize,
        modificationDate: fingerprint.modificationDate
    )
}

private enum FakeWriterError: Error {
    case coordinatorTailFailed
    case timeout
}

private func testFileOperations() -> SafeMetadataFileOperations {
    SafeMetadataFileOperations.live().overriding(
        coordinateReplacing: { original, work, accessor in
            try accessor(original, work)
        }
    )
}

private func makeTestWriter(
    metadataService: any MetadataService,
    operations: SafeMetadataFileOperations = testFileOperations(),
    commitGate: @escaping @Sendable () -> Bool = { true },
    temporaryIdentifierProvider: @escaping @Sendable () -> String = { UUID().uuidString }
) -> SafeMetadataWriter {
    SafeMetadataWriter(
        metadataService: metadataService,
        fileOperations: operations,
        commitGate: commitGate,
        temporaryIdentifierProvider: temporaryIdentifierProvider
    )
}

private func writeInPlace(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func removePath(_ url: URL) throws {
    guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
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

private func resultWorkspaceName(from message: String?) -> String {
    guard let message,
          let range = message.range(of: ".audio-toolbox-")
    else { return "missing" }
    let suffix = message[range.lowerBound...]
    return String(suffix.split(separator: "/").first ?? "missing")
}

private func replacingNodeState(
    _ state: SafeMetadataFileNodeState,
    device: UInt64? = nil,
    inode: UInt64? = nil,
    size: Int64? = nil,
    modificationSeconds: Int64? = nil,
    modificationNanoseconds: Int64? = nil,
    statusChangeSeconds: Int64? = nil,
    statusChangeNanoseconds: Int64? = nil,
    linkCount: UInt64? = nil,
    mode: UInt16? = nil,
    ownerID: UInt32? = nil,
    groupID: UInt32? = nil,
    flags: UInt32? = nil
) -> SafeMetadataFileNodeState {
    SafeMetadataFileNodeState(
        device: device ?? state.device,
        inode: inode ?? state.inode,
        size: size ?? state.size,
        modificationSeconds: modificationSeconds ?? state.modificationSeconds,
        modificationNanoseconds: modificationNanoseconds ?? state.modificationNanoseconds,
        statusChangeSeconds: statusChangeSeconds ?? state.statusChangeSeconds,
        statusChangeNanoseconds: statusChangeNanoseconds ?? state.statusChangeNanoseconds,
        linkCount: linkCount ?? state.linkCount,
        mode: mode ?? state.mode,
        ownerID: ownerID ?? state.ownerID,
        groupID: groupID ?? state.groupID,
        flags: flags ?? state.flags
    )
}

private func waitUntilFileExists(_ url: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw FakeWriterError.timeout
}

private func findFile(named name: String, under root: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return nil }
    for case let url as URL in enumerator where url.lastPathComponent == name {
        return url
    }
    return nil
}
