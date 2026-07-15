import Foundation

public enum AudioFileCandidate {
    public static func format(for url: URL) -> AudioFormat? {
        AudioFormat(rawValue: url.pathExtension.lowercased())
    }

    public static func shouldSkip(_ url: URL, values: URLResourceValues) -> Bool {
        values.isHidden == true
            || values.isSymbolicLink == true
            || url.lastPathComponent.hasPrefix(".audio-toolbox-")
            || url.pathComponents.contains { component in
                component.hasPrefix(".audio-toolbox-") && component.hasSuffix(".work")
            }
    }
}
