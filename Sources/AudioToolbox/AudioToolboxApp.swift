import SwiftUI
import AudioToolboxUI

@main
struct AudioToolboxApp: App {
    @StateObject private var libraryViewModel = LibraryViewModel.live()

    var body: some Scene {
        WindowGroup {
            Text("Audio Toolbox")
                .environmentObject(libraryViewModel)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
