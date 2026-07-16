import CryptoKit
import CSafeFileBridge
import Darwin
import Foundation

struct SafeMetadataFileNodeState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let linkCount: UInt64
    let mode: UInt16
    let ownerID: UInt32
    let groupID: UInt32
    let flags: UInt32

    var identity: SafeMetadataFileIdentity {
        SafeMetadataFileIdentity(device: device, inode: inode)
    }

    var isRegularFile: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFREG)
    }

    var isDirectory: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFDIR)
    }

    var isSymbolicLink: Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFLNK)
    }
}

struct SafeMetadataFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SafeMetadataFileSnapshot: Equatable, Sendable {
    let nodeState: SafeMetadataFileNodeState
    let digest: Data
    let fileSystemMetadata: Data

    func isEquivalentTransactionInput(to source: Self) -> Bool {
        nodeState.size == source.nodeState.size
            && nodeState.modificationSeconds == source.nodeState.modificationSeconds
            && nodeState.modificationNanoseconds == source.nodeState.modificationNanoseconds
            && nodeState.mode == source.nodeState.mode
            && nodeState.ownerID == source.nodeState.ownerID
            && nodeState.groupID == source.nodeState.groupID
            && nodeState.flags == source.nodeState.flags
            && nodeState.linkCount == 1
            && digest == source.digest
            && fileSystemMetadata.isEquivalentCopyMetadata(
                to: source.fileSystemMetadata
            )
    }

    func preservesFileSystemMetadata(of expected: Self) -> Bool {
        nodeState.mode == expected.nodeState.mode
            && nodeState.ownerID == expected.nodeState.ownerID
            && nodeState.groupID == expected.nodeState.groupID
            && nodeState.flags == expected.nodeState.flags
            && fileSystemMetadata == expected.fileSystemMetadata
    }

    // renameatx_np(RENAME_SWAP) legitimately advances ctime for both inodes.
    // Post-swap comparisons retain every other stat field plus SHA-256.
    func matchesAfterRename(_ expected: Self) -> Bool {
        nodeState.device == expected.nodeState.device
            && nodeState.inode == expected.nodeState.inode
            && nodeState.size == expected.nodeState.size
            && nodeState.modificationSeconds == expected.nodeState.modificationSeconds
            && nodeState.modificationNanoseconds == expected.nodeState.modificationNanoseconds
            && nodeState.linkCount == expected.nodeState.linkCount
            && nodeState.mode == expected.nodeState.mode
            && nodeState.ownerID == expected.nodeState.ownerID
            && nodeState.groupID == expected.nodeState.groupID
            && nodeState.flags == expected.nodeState.flags
            && digest == expected.digest
            && fileSystemMetadata == expected.fileSystemMetadata
    }
}

enum SafeMetadataFileSystemOperation: Sendable {
    case mkdir
    case copy
    case stat
    case digest
    case coordinate
    case swap
    case sync
    case unlink
    case close
}

struct SafeMetadataWorkspaceSetupError: Error, Sendable {
    let underlying: SafeMetadataFileSystemError
    let preservedURL: URL
}

struct SafeMetadataFileSystemError: Error, Sendable {
    let operation: SafeMetadataFileSystemOperation
    let code: Int32
    let ownedNodeState: SafeMetadataFileNodeState?

    init(
        operation: SafeMetadataFileSystemOperation,
        code: Int32,
        ownedNodeState: SafeMetadataFileNodeState? = nil
    ) {
        self.operation = operation
        self.code = code
        self.ownedNodeState = ownedNodeState
    }
}

private extension Data {
    func isEquivalentCopyMetadata(to source: Data) -> Bool {
        if self == source { return true }
        guard let copiedMetadata = SafeMetadataFileSystemMetadata(self),
              let sourceMetadata = SafeMetadataFileSystemMetadata(source),
              copiedMetadata.acl == sourceMetadata.acl,
              copiedMetadata.extendedAttributes.keys
                == sourceMetadata.extendedAttributes.keys else {
            return false
        }

        for (name, sourceValue) in sourceMetadata.extendedAttributes {
            guard let copiedValue = copiedMetadata.extendedAttributes[name] else {
                return false
            }
            if name == "com.apple.quarantine" {
                guard copiedValue.isPermittedQuarantineCopy(of: sourceValue) else {
                    return false
                }
            } else if copiedValue != sourceValue {
                return false
            }
        }
        return true
    }

    func isPermittedQuarantineCopy(of source: Data) -> Bool {
        if self == source { return true }
        guard let copiedText = String(data: self, encoding: .utf8),
              let sourceText = String(data: source, encoding: .utf8) else {
            return false
        }
        let copiedFields = copiedText.split(
            separator: ";",
            omittingEmptySubsequences: false
        )
        let sourceFields = sourceText.split(
            separator: ";",
            omittingEmptySubsequences: false
        )
        guard copiedFields.count == sourceFields.count,
              copiedFields.count >= 3,
              copiedFields[0].isPermittedQuarantineFlagCopy(of: sourceFields[0]),
              copiedFields.dropFirst(2).elementsEqual(sourceFields.dropFirst(2)),
              copiedFields[1].count == 8,
              sourceFields[1].count == 8,
              copiedFields[1].allSatisfy(\.isHexDigit),
              sourceFields[1].allSatisfy(\.isHexDigit) else {
            return false
        }
        return true
    }
}

private extension Substring {
    func isPermittedQuarantineFlagCopy(of source: Substring) -> Bool {
        guard count == 4,
              source.count == 4,
              let copiedFlags = UInt16(self, radix: 16),
              let sourceFlags = UInt16(source, radix: 16) else {
            return false
        }
        let sandboxManagedFlag: UInt16 = 0x0200
        return copiedFlags == sourceFlags
            || copiedFlags == sourceFlags | sandboxManagedFlag
    }
}

private struct SafeMetadataFileSystemMetadata {
    let acl: Data
    let extendedAttributes: [String: Data]

    init?(_ data: Data) {
        var reader = SafeMetadataBlobReader(data: data)
        guard let acl = reader.readLengthPrefixedData(),
              let attributeCount = reader.readUInt64(),
              attributeCount <= UInt64(reader.remainingCount / 16),
              attributeCount <= UInt64(Int.max) else {
            return nil
        }

        var attributes: [String: Data] = [:]
        attributes.reserveCapacity(Int(attributeCount))
        for _ in 0..<Int(attributeCount) {
            guard let nameData = reader.readLengthPrefixedData(),
                  let name = String(data: nameData, encoding: .utf8),
                  attributes[name] == nil,
                  let value = reader.readLengthPrefixedData() else {
                return nil
            }
            attributes[name] = value
        }
        guard reader.isAtEnd else { return nil }
        self.acl = acl
        extendedAttributes = attributes
    }
}

private struct SafeMetadataBlobReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }
    var remainingCount: Int { data.count - offset }

    mutating func readUInt64() -> UInt64? {
        guard offset <= data.count - MemoryLayout<UInt64>.size else { return nil }
        var value: UInt64 = 0
        for byteOffset in 0..<MemoryLayout<UInt64>.size {
            value |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        offset += MemoryLayout<UInt64>.size
        return value
    }

    mutating func readLengthPrefixedData() -> Data? {
        guard let encodedLength = readUInt64(),
              encodedLength <= UInt64(Int.max) else {
            return nil
        }
        let length = Int(encodedLength)
        guard length <= data.count - offset else { return nil }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }
}

final class SafeMetadataCancellationFlag: @unchecked Sendable {
    private let rawFlag: OpaquePointer

    init() throws {
        guard let rawFlag = ATSFCancellationFlagCreate() else {
            throw SafeMetadataFileSystemError(operation: .copy, code: ENOMEM)
        }
        self.rawFlag = rawFlag
    }

    deinit {
        ATSFCancellationFlagRelease(rawFlag)
    }

    func cancel() {
        ATSFCancellationFlagCancel(rawFlag)
    }

    var isCancelled: Bool {
        ATSFCancellationFlagIsCancelled(rawFlag)
    }

    var rawValue: OpaquePointer {
        rawFlag
    }

    func setCopyCallbackDelayForTesting(microseconds: UInt32) {
        ATSFCancellationFlagSetCallbackDelayForTesting(rawFlag, microseconds)
    }

    func setQuarantineSynchronizationErrorForTesting(_ errorCode: Int32) {
        ATSFCancellationFlagSetQuarantineSynchronizationErrorForTesting(
            rawFlag,
            errorCode
        )
    }
}

final class SafeMetadataWorkspace: @unchecked Sendable {
    let parentDirectoryURL: URL
    let directoryURL: URL
    let fileURL: URL
    let directoryName: String
    let fileName: String
    let parentDirectoryFD: Int32
    let directoryFD: Int32
    let parentDirectoryIdentity: SafeMetadataFileIdentity
    let directoryIdentity: SafeMetadataFileIdentity

    private let closeLock = NSLock()
    private var isClosed = false

    init(
        parentDirectoryURL: URL,
        directoryURL: URL,
        fileURL: URL,
        directoryName: String,
        fileName: String,
        parentDirectoryFD: Int32,
        directoryFD: Int32,
        parentDirectoryIdentity: SafeMetadataFileIdentity,
        directoryIdentity: SafeMetadataFileIdentity
    ) {
        self.parentDirectoryURL = parentDirectoryURL
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.directoryName = directoryName
        self.fileName = fileName
        self.parentDirectoryFD = parentDirectoryFD
        self.directoryFD = directoryFD
        self.parentDirectoryIdentity = parentDirectoryIdentity
        self.directoryIdentity = directoryIdentity
    }

    deinit {
        closeDescriptors()
    }

    func closeDescriptors() {
        closeLock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(directoryFD)
            Darwin.close(parentDirectoryFD)
        }
    }
}

enum SafeMetadataConditionalRemoval: Sendable {
    case removed
    case missing
    case identityMismatch(preservedURL: URL)
    case failed(SafeMetadataFileSystemError, preservedURL: URL?)
}

// Immutable closures are invoked from detached utility tasks or the synchronous commit section.
struct SafeMetadataFileOperations: @unchecked Sendable {
    let createWorkspace: (URL, String) throws -> SafeMetadataWorkspace
    let copyIntoWorkspace: (
        URL,
        SafeMetadataWorkspace,
        SafeMetadataCancellationFlag
    ) throws -> SafeMetadataFileNodeState
    let snapshotURL: (URL, SafeMetadataCancellationFlag) throws -> SafeMetadataFileSnapshot
    let snapshotWorkspace: (
        SafeMetadataWorkspace,
        SafeMetadataCancellationFlag
    ) throws -> SafeMetadataFileSnapshot
    let validateWorkspacePath: (
        SafeMetadataWorkspace,
        SafeMetadataFileIdentity
    ) throws -> Void
    let isReadable: (URL) -> Bool
    let isWritable: (URL) -> Bool
    let coordinateReplacing: (
        URL,
        URL,
        (URL, URL) throws -> Void
    ) throws -> Void
    let swap: (URL, URL) throws -> Void
    let syncWorkspaceFile: (
        SafeMetadataWorkspace,
        SafeMetadataFileIdentity
    ) throws -> Void
    let syncWorkspaceDirectory: (SafeMetadataWorkspace) throws -> Void
    let syncURLFile: (URL, SafeMetadataFileIdentity) throws -> Void
    let syncParentDirectory: (SafeMetadataWorkspace) throws -> Void
    let removeWorkspaceFileIfOwned: (
        SafeMetadataWorkspace,
        SafeMetadataFileIdentity
    ) -> SafeMetadataConditionalRemoval
    let removeWorkspaceDirectoryIfOwned: (
        SafeMetadataWorkspace
    ) -> SafeMetadataConditionalRemoval

    static func live(fileManager _: FileManager = .default) -> Self {
        Self(
            createWorkspace: createWorkspace,
            copyIntoWorkspace: copyIntoWorkspace,
            snapshotURL: snapshotURL,
            snapshotWorkspace: snapshotWorkspace,
            validateWorkspacePath: validateWorkspacePath,
            isReadable: { url in
                url.path.withCString { access($0, R_OK) == 0 }
            },
            isWritable: { url in
                url.path.withCString { access($0, W_OK) == 0 }
            },
            coordinateReplacing: coordinateReplacing,
            swap: swap,
            syncWorkspaceFile: syncWorkspaceFile,
            syncWorkspaceDirectory: syncWorkspaceDirectory,
            syncURLFile: syncURLFile,
            syncParentDirectory: syncParentDirectory,
            removeWorkspaceFileIfOwned: { workspace, expectedIdentity in
                removeWorkspaceFileIfOwnedForTesting(
                    workspace,
                    expectedIdentity: expectedIdentity,
                    afterQuarantineValidation: { _ in }
                )
            },
            removeWorkspaceDirectoryIfOwned: { workspace in
                removeWorkspaceDirectoryIfOwnedForTesting(
                    workspace,
                    afterQuarantineValidation: { _ in }
                )
            }
        )
    }

    func overriding(
        createWorkspace: ((URL, String) throws -> SafeMetadataWorkspace)? = nil,
        copyIntoWorkspace: ((URL, SafeMetadataWorkspace, SafeMetadataCancellationFlag) throws -> SafeMetadataFileNodeState)? = nil,
        snapshotURL: ((URL, SafeMetadataCancellationFlag) throws -> SafeMetadataFileSnapshot)? = nil,
        snapshotWorkspace: ((SafeMetadataWorkspace, SafeMetadataCancellationFlag) throws -> SafeMetadataFileSnapshot)? = nil,
        validateWorkspacePath: ((SafeMetadataWorkspace, SafeMetadataFileIdentity) throws -> Void)? = nil,
        isReadable: ((URL) -> Bool)? = nil,
        isWritable: ((URL) -> Bool)? = nil,
        coordinateReplacing: ((URL, URL, (URL, URL) throws -> Void) throws -> Void)? = nil,
        swap: ((URL, URL) throws -> Void)? = nil,
        syncWorkspaceFile: ((SafeMetadataWorkspace, SafeMetadataFileIdentity) throws -> Void)? = nil,
        syncWorkspaceDirectory: ((SafeMetadataWorkspace) throws -> Void)? = nil,
        syncURLFile: ((URL, SafeMetadataFileIdentity) throws -> Void)? = nil,
        syncParentDirectory: ((SafeMetadataWorkspace) throws -> Void)? = nil,
        removeWorkspaceFileIfOwned: ((SafeMetadataWorkspace, SafeMetadataFileIdentity) -> SafeMetadataConditionalRemoval)? = nil,
        removeWorkspaceDirectoryIfOwned: ((SafeMetadataWorkspace) -> SafeMetadataConditionalRemoval)? = nil
    ) -> Self {
        Self(
            createWorkspace: createWorkspace ?? self.createWorkspace,
            copyIntoWorkspace: copyIntoWorkspace ?? self.copyIntoWorkspace,
            snapshotURL: snapshotURL ?? self.snapshotURL,
            snapshotWorkspace: snapshotWorkspace ?? self.snapshotWorkspace,
            validateWorkspacePath: validateWorkspacePath ?? self.validateWorkspacePath,
            isReadable: isReadable ?? self.isReadable,
            isWritable: isWritable ?? self.isWritable,
            coordinateReplacing: coordinateReplacing ?? self.coordinateReplacing,
            swap: swap ?? self.swap,
            syncWorkspaceFile: syncWorkspaceFile ?? self.syncWorkspaceFile,
            syncWorkspaceDirectory: syncWorkspaceDirectory ?? self.syncWorkspaceDirectory,
            syncURLFile: syncURLFile ?? self.syncURLFile,
            syncParentDirectory: syncParentDirectory ?? self.syncParentDirectory,
            removeWorkspaceFileIfOwned: removeWorkspaceFileIfOwned ?? self.removeWorkspaceFileIfOwned,
            removeWorkspaceDirectoryIfOwned: removeWorkspaceDirectoryIfOwned ?? self.removeWorkspaceDirectoryIfOwned
        )
    }

    private static func createWorkspace(
        originalURL: URL,
        identifier: String
    ) throws -> SafeMetadataWorkspace {
        let parentURL = originalURL.deletingLastPathComponent()
        let parentFD = parentURL.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentFD >= 0 else {
            throw SafeMetadataFileSystemError(operation: .mkdir, code: errno)
        }
        let parentState: SafeMetadataFileNodeState
        do {
            parentState = try stateForDescriptor(parentFD, operation: .mkdir)
        } catch {
            Darwin.close(parentFD)
            throw error
        }

        let directoryName = ".audio-toolbox-\(identifier).work"
        let mkdirResult = directoryName.withCString { name in
            mkdirat(parentFD, name, 0o700)
        }
        guard mkdirResult == 0 else {
            let code = errno
            Darwin.close(parentFD)
            throw SafeMetadataFileSystemError(operation: .mkdir, code: code)
        }

        let directoryFD = directoryName.withCString { name in
            openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        let directoryURL = parentURL.appendingPathComponent(directoryName, isDirectory: true)
        guard directoryFD >= 0 else {
            let code = errno
            Darwin.close(parentFD)
            throw SafeMetadataWorkspaceSetupError(
                underlying: SafeMetadataFileSystemError(operation: .mkdir, code: code),
                preservedURL: directoryURL
            )
        }

        guard fchmod(directoryFD, 0o700) == 0 else {
            let code = errno
            Darwin.close(directoryFD)
            Darwin.close(parentFD)
            throw SafeMetadataWorkspaceSetupError(
                underlying: SafeMetadataFileSystemError(operation: .mkdir, code: code),
                preservedURL: directoryURL
            )
        }

        let directoryState: SafeMetadataFileNodeState
        do {
            directoryState = try stateForDescriptor(directoryFD, operation: .mkdir)
        } catch let error as SafeMetadataFileSystemError {
            Darwin.close(directoryFD)
            Darwin.close(parentFD)
            throw SafeMetadataWorkspaceSetupError(
                underlying: error,
                preservedURL: directoryURL
            )
        }
        guard directoryState.isDirectory else {
            Darwin.close(directoryFD)
            Darwin.close(parentFD)
            throw SafeMetadataWorkspaceSetupError(
                underlying: SafeMetadataFileSystemError(operation: .mkdir, code: ENOTDIR),
                preservedURL: directoryURL
            )
        }

        let fileName = originalURL.pathExtension.isEmpty
            ? "working"
            : "working.\(originalURL.pathExtension)"
        return SafeMetadataWorkspace(
            parentDirectoryURL: parentURL,
            directoryURL: directoryURL,
            fileURL: directoryURL.appendingPathComponent(fileName),
            directoryName: directoryName,
            fileName: fileName,
            parentDirectoryFD: parentFD,
            directoryFD: directoryFD,
            parentDirectoryIdentity: parentState.identity,
            directoryIdentity: directoryState.identity
        )
    }

    private static func copyIntoWorkspace(
        source: URL,
        workspace: SafeMetadataWorkspace,
        cancellationFlag: SafeMetadataCancellationFlag
    ) throws -> SafeMetadataFileNodeState {
        let copyResult = source.path.withCString { sourcePath in
            workspace.fileName.withCString { fileName in
                ATSFCopyFileToDirectory(
                    sourcePath,
                    workspace.directoryFD,
                    fileName,
                    cancellationFlag.rawValue
                )
            }
        }
        defer {
            if copyResult.destination_fd >= 0 {
                Darwin.close(copyResult.destination_fd)
            }
        }

        let ownedState: SafeMetadataFileNodeState?
        if copyResult.destination_fd >= 0 {
            ownedState = try? stateForDescriptor(
                copyResult.destination_fd,
                operation: .copy
            )
        } else {
            ownedState = nil
        }

        guard copyResult.status == 0 else {
            throw SafeMetadataFileSystemError(
                operation: .copy,
                code: copyResult.error_code,
                ownedNodeState: ownedState
            )
        }
        guard let ownedState else {
            throw SafeMetadataFileSystemError(operation: .copy, code: EIO)
        }
        return ownedState
    }

    private static func snapshotURL(
        url: URL,
        cancellationFlag: SafeMetadataCancellationFlag
    ) throws -> SafeMetadataFileSnapshot {
        try checkCancellation(cancellationFlag)
        let pathBefore = try nodeState(url: url)
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SafeMetadataFileSystemError(operation: .digest, code: errno)
        }
        defer { Darwin.close(descriptor) }

        let descriptorBefore = try stateForDescriptor(descriptor, operation: .digest)
        guard descriptorBefore == pathBefore else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        let metadata = try fileSystemMetadata(
            descriptor: descriptor,
            cancellationFlag: cancellationFlag
        )
        let digest = try digest(descriptor: descriptor, cancellationFlag: cancellationFlag)
        let descriptorAfter = try stateForDescriptor(descriptor, operation: .digest)
        let pathAfter = try nodeState(url: url)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter == pathAfter
        else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        return SafeMetadataFileSnapshot(
            nodeState: pathAfter,
            digest: digest,
            fileSystemMetadata: metadata
        )
    }

    private static func snapshotWorkspace(
        workspace: SafeMetadataWorkspace,
        cancellationFlag: SafeMetadataCancellationFlag
    ) throws -> SafeMetadataFileSnapshot {
        try checkCancellation(cancellationFlag)
        let pathBefore = try workspaceFileState(workspace)
        let descriptor = workspace.fileName.withCString { fileName in
            openat(
                workspace.directoryFD,
                fileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SafeMetadataFileSystemError(operation: .digest, code: errno)
        }
        defer { Darwin.close(descriptor) }

        let descriptorBefore = try stateForDescriptor(descriptor, operation: .digest)
        guard descriptorBefore == pathBefore else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        let metadata = try fileSystemMetadata(
            descriptor: descriptor,
            cancellationFlag: cancellationFlag
        )
        let digest = try digest(descriptor: descriptor, cancellationFlag: cancellationFlag)
        let descriptorAfter = try stateForDescriptor(descriptor, operation: .digest)
        let pathAfter = try workspaceFileState(workspace)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter == pathAfter
        else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        return SafeMetadataFileSnapshot(
            nodeState: pathAfter,
            digest: digest,
            fileSystemMetadata: metadata
        )
    }

    private static func validateWorkspacePath(
        workspace: SafeMetadataWorkspace,
        expectedFileIdentity: SafeMetadataFileIdentity
    ) throws {
        let openDirectory = try stateForDescriptor(
            workspace.directoryFD,
            operation: .stat
        )
        guard openDirectory.identity == workspace.directoryIdentity else {
            throw SafeMetadataFileSystemError(operation: .stat, code: ESTALE)
        }

        var pathStatus = stat()
        let directoryResult = workspace.directoryName.withCString { name in
            fstatat(
                workspace.parentDirectoryFD,
                name,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard directoryResult == 0 else {
            throw SafeMetadataFileSystemError(operation: .stat, code: errno)
        }
        guard SafeMetadataFileNodeState(pathStatus).identity == workspace.directoryIdentity else {
            throw SafeMetadataFileSystemError(operation: .stat, code: ESTALE)
        }

        let fileState = try workspaceFileState(workspace)
        guard fileState.identity == expectedFileIdentity else {
            throw SafeMetadataFileSystemError(operation: .stat, code: ESTALE)
        }
    }

    private static func coordinateReplacing(
        original: URL,
        temporary: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorError: Error?
        var didEnterAccessor = false

        coordinator.coordinate(
            writingItemAt: original,
            options: .forReplacing,
            writingItemAt: temporary,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedOriginal, coordinatedTemporary in
            didEnterAccessor = true
            do {
                try accessor(coordinatedOriginal, coordinatedTemporary)
            } catch {
                accessorError = error
            }
        }

        if let accessorError { throw accessorError }
        guard coordinationError == nil, didEnterAccessor else {
            throw SafeMetadataFileSystemError(operation: .coordinate, code: EIO)
        }
    }

    private static func swap(original: URL, temporary: URL) throws {
        let result = original.path.withCString { originalPath in
            temporary.path.withCString { temporaryPath in
                renameatx_np(
                    AT_FDCWD,
                    originalPath,
                    AT_FDCWD,
                    temporaryPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .swap, code: errno)
        }
    }

    private static func syncWorkspaceFile(
        workspace: SafeMetadataWorkspace,
        expectedIdentity: SafeMetadataFileIdentity
    ) throws {
        try validateWorkspacePath(
            workspace: workspace,
            expectedFileIdentity: expectedIdentity
        )
        let descriptor = workspace.fileName.withCString { fileName in
            openat(
                workspace.directoryFD,
                fileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SafeMetadataFileSystemError(operation: .sync, code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard try stateForDescriptor(descriptor, operation: .sync).identity == expectedIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
        try fullSync(descriptor)
        guard try stateForDescriptor(descriptor, operation: .sync).identity == expectedIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
    }

    private static func syncWorkspaceDirectory(
        workspace: SafeMetadataWorkspace
    ) throws {
        guard try stateForDescriptor(
            workspace.directoryFD,
            operation: .sync
        ).identity == workspace.directoryIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
        try fullSync(workspace.directoryFD)
    }

    private static func syncURLFile(
        url: URL,
        expectedIdentity: SafeMetadataFileIdentity
    ) throws {
        guard try nodeState(url: url).identity == expectedIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SafeMetadataFileSystemError(operation: .sync, code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard try stateForDescriptor(descriptor, operation: .sync).identity == expectedIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
        try fullSync(descriptor)
        guard try nodeState(url: url).identity == expectedIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
    }

    private static func syncParentDirectory(
        workspace: SafeMetadataWorkspace
    ) throws {
        guard try stateForDescriptor(
            workspace.parentDirectoryFD,
            operation: .sync
        ).identity == workspace.parentDirectoryIdentity else {
            throw SafeMetadataFileSystemError(operation: .sync, code: ESTALE)
        }
        try fullSync(workspace.parentDirectoryFD)
    }

    private static func fullSync(_ descriptor: Int32) throws {
        let code = ATSFFullSyncFD(descriptor)
        guard code == 0 else {
            throw SafeMetadataFileSystemError(operation: .sync, code: code)
        }
    }

    static func removeWorkspaceFileIfOwnedForTesting(
        _ workspace: SafeMetadataWorkspace,
        expectedIdentity: SafeMetadataFileIdentity,
        afterQuarantineValidation: (URL) -> Void
    ) -> SafeMetadataConditionalRemoval {
        // The 0700 directory and random quarantine name are the boundary
        // against ordinary same-UID competitors. If either identity check
        // fails, the quarantine object is retained rather than deleted.
        do {
            let directoryState = try stateForDescriptor(
                workspace.directoryFD,
                operation: .unlink
            )
            guard directoryState.identity == workspace.directoryIdentity else {
                return .identityMismatch(preservedURL: workspace.directoryURL)
            }
        } catch let error as SafeMetadataFileSystemError {
            return .failed(error, preservedURL: workspace.directoryURL)
        } catch {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: EIO),
                preservedURL: workspace.directoryURL
            )
        }

        let state: SafeMetadataFileNodeState
        do {
            state = try workspaceFileState(workspace)
        } catch let error as SafeMetadataFileSystemError where error.code == ENOENT {
            return .missing
        } catch let error as SafeMetadataFileSystemError {
            return .failed(error, preservedURL: workspace.fileURL)
        } catch {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: EIO),
                preservedURL: workspace.fileURL
            )
        }
        guard state.identity == expectedIdentity else {
            return .identityMismatch(preservedURL: workspace.fileURL)
        }

        let quarantineName = ".quarantine-file-\(UUID().uuidString)"
        let renameResult = workspace.fileName.withCString { fileName in
            quarantineName.withCString { quarantineName in
                renameatx_np(
                    workspace.directoryFD,
                    fileName,
                    workspace.directoryFD,
                    quarantineName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if errno == ENOENT { return .missing }
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: workspace.fileURL
            )
        }

        let quarantineURL = workspace.directoryURL.appendingPathComponent(quarantineName)
        guard quarantineEntryIdentity(
            directoryFD: workspace.directoryFD,
            name: quarantineName
        ) == expectedIdentity else {
            return .identityMismatch(preservedURL: quarantineURL)
        }

        afterQuarantineValidation(quarantineURL)

        guard quarantineEntryIdentity(
            directoryFD: workspace.directoryFD,
            name: quarantineName
        ) == expectedIdentity else {
            return .identityMismatch(preservedURL: quarantineURL)
        }

        let unlinkResult = quarantineName.withCString { name in
            unlinkat(workspace.directoryFD, name, 0)
        }
        guard unlinkResult == 0 else {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: quarantineURL
            )
        }
        return .removed
    }

    static func removeWorkspaceDirectoryIfOwnedForTesting(
        _ workspace: SafeMetadataWorkspace,
        afterQuarantineValidation: (URL) -> Void
    ) -> SafeMetadataConditionalRemoval {
        do {
            let openState = try stateForDescriptor(
                workspace.directoryFD,
                operation: .unlink
            )
            guard openState.identity == workspace.directoryIdentity else {
                return .identityMismatch(preservedURL: workspace.directoryURL)
            }
        } catch let error as SafeMetadataFileSystemError {
            return .failed(error, preservedURL: workspace.directoryURL)
        } catch {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: EIO),
                preservedURL: workspace.directoryURL
            )
        }

        guard quarantineEntryIdentity(
            directoryFD: workspace.parentDirectoryFD,
            name: workspace.directoryName
        ) == workspace.directoryIdentity else {
            return .identityMismatch(preservedURL: workspace.directoryURL)
        }

        let quarantineName = ".quarantine-directory-\(UUID().uuidString).work"
        let renameResult = workspace.directoryName.withCString { directoryName in
            quarantineName.withCString { quarantineName in
                renameatx_np(
                    workspace.parentDirectoryFD,
                    directoryName,
                    workspace.parentDirectoryFD,
                    quarantineName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if errno == ENOENT { return .missing }
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: workspace.directoryURL
            )
        }

        let quarantineURL = workspace.parentDirectoryURL.appendingPathComponent(
            quarantineName,
            isDirectory: true
        )
        guard quarantineEntryIdentity(
            directoryFD: workspace.parentDirectoryFD,
            name: quarantineName
        ) == workspace.directoryIdentity else {
            return .identityMismatch(preservedURL: quarantineURL)
        }

        afterQuarantineValidation(quarantineURL)

        guard quarantineEntryIdentity(
            directoryFD: workspace.parentDirectoryFD,
            name: quarantineName
        ) == workspace.directoryIdentity else {
            return .identityMismatch(preservedURL: quarantineURL)
        }

        let removeResult = quarantineName.withCString { name in
            unlinkat(workspace.parentDirectoryFD, name, AT_REMOVEDIR)
        }
        guard removeResult == 0 else {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: quarantineURL
            )
        }
        return .removed
    }

    private static func quarantineEntryIdentity(
        directoryFD: Int32,
        name: String
    ) -> SafeMetadataFileIdentity? {
        var status = stat()
        let result = name.withCString { name in
            fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return nil }
        return SafeMetadataFileNodeState(status).identity
    }

    private static func workspaceFileState(
        _ workspace: SafeMetadataWorkspace
    ) throws -> SafeMetadataFileNodeState {
        var status = stat()
        let result = workspace.fileName.withCString { fileName in
            fstatat(
                workspace.directoryFD,
                fileName,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .stat, code: errno)
        }
        return SafeMetadataFileNodeState(status)
    }

    private static func nodeState(url: URL) throws -> SafeMetadataFileNodeState {
        var status = stat()
        let result = url.path.withCString { path in
            lstat(path, &status)
        }
        guard result == 0 else {
            throw SafeMetadataFileSystemError(operation: .stat, code: errno)
        }
        return SafeMetadataFileNodeState(status)
    }

    private static func stateForDescriptor(
        _ descriptor: Int32,
        operation: SafeMetadataFileSystemOperation
    ) throws -> SafeMetadataFileNodeState {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw SafeMetadataFileSystemError(operation: operation, code: errno)
        }
        return SafeMetadataFileNodeState(status)
    }

    private static func fileSystemMetadata(
        descriptor: Int32,
        cancellationFlag: SafeMetadataCancellationFlag
    ) throws -> Data {
        try checkCancellation(cancellationFlag)
        var blob = ATSFMetadataSnapshotForFD(descriptor)
        defer { ATSFMetadataBlobRelease(&blob) }
        guard blob.status == 0 else {
            throw SafeMetadataFileSystemError(
                operation: .stat,
                code: blob.error_code
            )
        }
        try checkCancellation(cancellationFlag)
        guard blob.size > 0 else { return Data() }
        guard let bytes = blob.bytes else {
            throw SafeMetadataFileSystemError(operation: .stat, code: EIO)
        }
        return Data(bytes: bytes, count: blob.size)
    }

    private static func digest(
        descriptor: Int32,
        cancellationFlag: SafeMetadataCancellationFlag
    ) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw SafeMetadataFileSystemError(operation: .digest, code: errno)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try checkCancellation(cancellationFlag)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SafeMetadataFileSystemError(operation: .digest, code: errno)
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        start: bytes.baseAddress,
                        count: count
                    )
                )
            }
        }
        try checkCancellation(cancellationFlag)
        return Data(hasher.finalize())
    }

    private static func checkCancellation(
        _ cancellationFlag: SafeMetadataCancellationFlag
    ) throws {
        if cancellationFlag.isCancelled {
            throw CancellationError()
        }
    }
}

private extension SafeMetadataFileNodeState {
    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        size = Int64(status.st_size)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        linkCount = UInt64(status.st_nlink)
        mode = UInt16(status.st_mode)
        ownerID = UInt32(status.st_uid)
        groupID = UInt32(status.st_gid)
        flags = UInt32(status.st_flags)
    }
}
