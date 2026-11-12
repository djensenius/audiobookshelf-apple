import Foundation
import UniformTypeIdentifiers

#if os(iOS)
    import Photos
    import UIKit
#else
    import AppKit
#endif

/// The app's add-only access to the photo library.
enum PhotoAddAccess: Sendable, Equatable {
    case notDetermined
    case authorized
    /// Limited access; adding is still allowed.
    case limited
    case denied
    /// Blocked by Screen Time or a device profile; the user may not be able to change it.
    case restricted
}

/// The seam over Photos, so the permission handling is tested without touching the library.
protocol PhotoLibraryAdding: Sendable {
    /// The add-only status, without asking.
    func addAccess() -> PhotoAddAccess
    /// Asks for add-only access; called only while the status is undetermined.
    func requestAddAccess() async -> PhotoAddAccess
    /// Adds a PNG to the library as a new photo.
    func addPNG(_ png: Data) async throws
}

/// What saving to Photos ended with.
enum PhotoSaveOutcome: Sendable, Equatable {
    case saved
    case denied
    case restricted
    case failed

    /// What to tell the user: a confirmation, or why nothing was saved.
    var messageKey: String {
        switch self {
        case .saved: "MessageYearInReviewSavedToPhotos"
        case .denied: "MessageYearInReviewPhotosDenied"
        case .restricted: "MessageYearInReviewPhotosRestricted"
        case .failed: "MessageYearInReviewPhotosSaveFailed"
        }
    }

    /// Whether the alert offers to open Settings, where photo access is changed.
    var offersSettings: Bool { self == .denied || self == .restricted }

    /// Whether to show this outcome of saving the image rendered for `key` now that the
    /// selection is `current`. A save can finish after the year, variant or layout changed;
    /// its confirmation or alert would then describe an image that is no longer shown. A
    /// refresh of the same selection still shows it.
    func isShown(savedFrom key: YearInReviewRenderKey, current: YearInReviewRenderKey) -> Bool {
        key.isSameSelection(as: current)
    }
}

/// Saves the shared image to Photos with add-only access, asking for it the first time.
struct YearInReviewPhotoSaver: Sendable {
    let library: any PhotoLibraryAdding

    func save(png: Data) async -> PhotoSaveOutcome {
        var access = library.addAccess()
        if access == .notDetermined {
            access = await library.requestAddAccess()
        }
        switch access {
        case .authorized, .limited:
            do {
                try await library.addPNG(png)
                return .saved
            } catch {
                return .failed
            }
        case .restricted:
            return .restricted
        case .denied, .notDetermined:
            // Undetermined after asking means the prompt was dismissed without an answer.
            return .denied
        }
    }
}

#if os(iOS)
    /// The real photo library, asking for add-only access
    /// (`NSPhotoLibraryAddUsageDescription`).
    struct SystemPhotoLibrary: PhotoLibraryAdding {
        func addAccess() -> PhotoAddAccess {
            Self.access(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        }

        func requestAddAccess() async -> PhotoAddAccess {
            Self.access(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        }

        func addPNG(_ png: Data) async throws {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }
        }

        private static func access(_ status: PHAuthorizationStatus) -> PhotoAddAccess {
            switch status {
            case .authorized: .authorized
            case .limited: .limited
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        }
    }
#endif

/// Copies the shared image to the clipboard as a PNG.
enum YearInReviewClipboard {
    #if os(iOS)
        static func copy(png: Data, to pasteboard: UIPasteboard = .general) {
            pasteboard.setData(png, forPasteboardType: UTType.png.identifier)
        }
    #else
        static func copy(png: Data, to pasteboard: NSPasteboard = .general) {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
    #endif
}
