import Foundation

/// A reference to a wallpaper already installed on this Mac.
///
/// Focus Studio deliberately stores only the path. The system-owned image is
/// never copied into the app bundle or a project directory.
struct SystemWallpaper: Identifiable, Hashable, Sendable {
    let url: URL
    let displayName: String

    var id: String { url.path }
    var path: String { url.path }
}

enum SystemWallpaperCatalog {
    static let searchDirectories = [
        URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
        URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true),
    ]

    /// Enumerating the nested system wallpaper folders can be comparatively
    /// expensive, so the editor reuses one immutable snapshot per app launch.
    static let installed = wallpapers()

    /// Enumerates readable image files without decoding or copying them.
    /// Nested directories are supported because recent macOS releases group
    /// dynamic wallpapers into subfolders.
    static func wallpapers(fileManager: FileManager = .default) -> [SystemWallpaper] {
        let supportedExtensions = Set(["heic", "heif", "jpg", "jpeg", "png"])
        var canonicalPaths = Set<String>()
        var results: [SystemWallpaper] = []

        for directory in searchDirectories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let candidate as URL in enumerator {
                guard supportedExtensions.contains(candidate.pathExtension.lowercased()),
                      fileManager.isReadableFile(atPath: candidate.path) else { continue }

                let canonicalPath = candidate
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                guard canonicalPaths.insert(canonicalPath).inserted else { continue }

                results.append(SystemWallpaper(
                    url: candidate.standardizedFileURL,
                    displayName: safeDisplayName(for: candidate)
                ))
            }
        }

        return results.sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder == .orderedSame {
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }
    }

    private static func safeDisplayName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let separated = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let withoutControls = String(separated.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let collapsed = withoutControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallback = collapsed.isEmpty ? "System Wallpaper" : collapsed
        return String(fallback.prefix(80))
    }
}
