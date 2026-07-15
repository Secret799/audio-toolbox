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
            && digest == expected.digest
    }
}

enum SafeMetadataFileSystemOperation: Sendable {
    case mkdir
    case copy
    case stat
    case digest
    case coordinate
    case swap
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
}

final class SafeMetadataWorkspace: @unchecked Sendable {
    let parentDirectoryURL: URL
    let directoryURL: URL
    let fileURL: URL
    let directoryName: String
    let fileName: String
    let parentDirectoryFD: Int32
    let directoryFD: Int32
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
        directoryIdentity: SafeMetadataFileIdentity
    ) {
        self.parentDirectoryURL = parentDirectoryURL
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.directoryName = directoryName
        self.fileName = fileName
        self.parentDirectoryFD = parentDirectoryFD
        self.directoryFD = directoryFD
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
            removeWorkspaceFileIfOwned: { workspace, expectedIdentity in
                removeWorkspaceFileIfOwnedForTesting(
                    workspace,
                    expectedIdentity: expectedIdentity,
                    beforeRename: {}
                )
            },
            removeWorkspaceDirectoryIfOwned: removeWorkspaceDirectoryIfOwned
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
        let digest = try digest(descriptor: descriptor, cancellationFlag: cancellationFlag)
        let descriptorAfter = try stateForDescriptor(descriptor, operation: .digest)
        let pathAfter = try nodeState(url: url)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter == pathAfter
        else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        return SafeMetadataFileSnapshot(nodeState: pathAfter, digest: digest)
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
        let digest = try digest(descriptor: descriptor, cancellationFlag: cancellationFlag)
        let descriptorAfter = try stateForDescriptor(descriptor, operation: .digest)
        let pathAfter = try workspaceFileState(workspace)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter == pathAfter
        else {
            throw SafeMetadataFileSystemError(operation: .digest, code: ESTALE)
        }
        return SafeMetadataFileSnapshot(nodeState: pathAfter, digest: digest)
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

    static func removeWorkspaceFileIfOwnedForTesting(
        _ workspace: SafeMetadataWorkspace,
        expectedIdentity: SafeMetadataFileIdentity,
        beforeRename: () -> Void
    ) -> SafeMetadataConditionalRemoval {
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

        beforeRename()

        let cleanupName = ".cleanup-\(UUID().uuidString)"
        let renameResult = workspace.fileName.withCString { fileName in
            cleanupName.withCString { cleanupName in
                renameatx_np(
                    workspace.directoryFD,
                    fileName,
                    workspace.directoryFD,
                    cleanupName,
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

        let cleanupURL = workspace.directoryURL.appendingPathComponent(cleanupName)
        var cleanupStatus = stat()
        let statusResult = cleanupName.withCString { name in
            fstatat(
                workspace.directoryFD,
                name,
                &cleanupStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0 else {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: cleanupURL
            )
        }
        guard SafeMetadataFileNodeState(cleanupStatus).identity == expectedIdentity else {
            return .identityMismatch(preservedURL: cleanupURL)
        }

        let unlinkResult = cleanupName.withCString { name in
            unlinkat(workspace.directoryFD, name, 0)
        }
        guard unlinkResult == 0 else {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: cleanupURL
            )
        }
        return .removed
    }

    private static func removeWorkspaceDirectoryIfOwned(
        workspace: SafeMetadataWorkspace
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

        var status = stat()
        let stateResult = workspace.directoryName.withCString { name in
            fstatat(
                workspace.parentDirectoryFD,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if stateResult != 0 {
            if errno == ENOENT { return .missing }
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: workspace.directoryURL
            )
        }
        guard SafeMetadataFileNodeState(status).identity == workspace.directoryIdentity else {
            return .identityMismatch(preservedURL: workspace.directoryURL)
        }

        let removeResult = workspace.directoryName.withCString { name in
            unlinkat(workspace.parentDirectoryFD, name, AT_REMOVEDIR)
        }
        guard removeResult == 0 else {
            return .failed(
                SafeMetadataFileSystemError(operation: .unlink, code: errno),
                preservedURL: workspace.directoryURL
            )
        }
        return .removed
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
            hasher.update(data: Data(buffer[0..<count]))
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
    }
}
