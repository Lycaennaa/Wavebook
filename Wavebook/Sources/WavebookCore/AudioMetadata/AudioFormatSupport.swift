import AVFoundation
import Foundation

/// Shared support for recognizing and normalizing audio formats.
public enum AudioFormatSupport {
    /// Extensions required by the first metadata format version.
    public static let requiredV1Extensions: Set<String> = ["mp3", "flac", "opus"]
    /// Extensions eligible for native audio format probing.
    public static let nativeCandidateExtensions: Set<String> = [
        "mp3", "flac", "opus", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf"
    ]

    /// Returns a lowercase extension for a file URL.
    public static func normalizedExtension(for url: URL) -> String {
        url.pathExtension.lowercased()
    }

    /// Returns whether a URL has a natively supported audio extension.
    public static func shouldScan(_ url: URL) -> Bool {
        nativeCandidateExtensions.contains(normalizedExtension(for: url))
    }

    /// Returns whether an extension requires runtime format probing.
    public static func requiresRuntimeProbe(_ fileExtension: String) -> Bool {
        requiredV1Extensions.contains(fileExtension.lowercased())
    }
}
