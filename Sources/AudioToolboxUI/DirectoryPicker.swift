import AppKit
import Foundation

public struct DirectoryPicker {
    public init() {}

    @MainActor
    public func pickDirectory(
        prompt: String = "选择目录",
        message: String = "选择包含音频文件的目录"
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
