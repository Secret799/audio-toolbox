import AppKit
import Foundation

public struct DirectoryPicker {
    public init() {}

    @MainActor
    public func pickDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.message = "选择包含音频文件的目录"

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
