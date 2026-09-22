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
    /// Recent macOS releases keep only `.madesktop` stubs in the public folder
    /// and put the real images in a hidden `.wallpapers` directory or in the
    /// per-user asset download folder, which is why the old two-directory
    /// search found a fraction of what is installed.
    static let searchDirectories: [URL] = {
        var directories = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true),
        ]
        if let home = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            directories.append(
                home.appendingPathComponent("Application Support/com.apple.mobileAssetDesktop", isDirectory: true)
            )
        }
        return directories
    }()

    /// Thumbnails sit beside the full-resolution files and would otherwise
    /// appear as duplicate, unusably small backgrounds.
    static let minimumFileSize = 200 * 1024

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
            // The hidden wallpaper folders have to be walked explicitly, so
            // skipsHiddenFiles cannot be used for them.
            let isHiddenRoot = directory.lastPathComponent.hasPrefix(".")
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !isHiddenRoot { options.insert(.skipsHiddenFiles) }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: options,
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let candidate as URL in enumerator {
                guard supportedExtensions.contains(candidate.pathExtension.lowercased()),
                      fileManager.isReadableFile(atPath: candidate.path) else { continue }
                if candidate.lastPathComponent.localizedCaseInsensitiveContains("thumbnail") { continue }
                let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size >= minimumFileSize else { continue }

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
