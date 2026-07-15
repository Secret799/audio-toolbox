import SwiftUI
import AudioToolboxCore
import AudioToolboxUI

@main
struct AudioToolboxApp: App {
    @StateObject private var libraryViewModel: LibraryViewModel

    init() {
        let metadataService = TagLibMetadataService()
        let scanner = DirectoryScanner(metadataService: metadataService)
        let writer = SafeMetadataWriter(metadataService: metadataService)
        let batchEditor = BatchEditor(writer: writer)
        let bookmarkStore = SecurityScopedDirectoryStore()
        _libraryViewModel = StateObject(
            wrappedValue: LibraryViewModel(
                scanner: scanner,
                batchEditor: batchEditor,
                bookmarkStore: bookmarkStore
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(viewModel: libraryViewModel)
                .task {
                    await libraryViewModel.restoreLastDirectoryIfNeeded()
                }
        }
        .defaultSize(width: 1180, height: 760)
    }
}
