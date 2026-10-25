import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps the photos, videos and the alarm track the person added.
/// Everything is copied into the app's own folder and never leaves the phone.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()

    @Published private(set) var photos: [URL] = []
    @Published private(set) var videos: [URL] = []
    @Published private(set) var trackURL: URL?
    @Published private(set) var trackName: String?
    @Published private(set) var isImporting = false

    private let fm = FileManager.default
    private let photosDir: URL
    private let videosDir: URL
    private let trackDir: URL

    private init() {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("Media", isDirectory: true)
        photosDir = root.appendingPathComponent("Photos", isDirectory: true)
        videosDir = root.appendingPathComponent("Videos", isDirectory: true)
        trackDir = root.appendingPathComponent("Track", isDirectory: true)
        for dir in [photosDir, videosDir, trackDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
    }

    func reload() {
        photos = files(in: photosDir)
        videos = files(in: videosDir)
        trackURL = files(in: trackDir).first
        trackName = trackURL == nil ? nil : UserDefaults.standard.string(forKey: Keys.trackName)
    }

    private func files(in dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func stamp() -> String {
        String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    }

    // MARK: Photos

    func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let url = photosDir.appendingPathComponent("\(stamp())-\(index).jpg")
            let jpeg = await Task.detached(priority: .userInitiated) {
                ImageLoader.jpegData(from: data, maxPixel: 2200)
            }.value
            if let jpeg { try? jpeg.write(to: url, options: .atomic) }
        }
        isImporting = false
        reload()
    }

    func deletePhoto(_ url: URL) {
        try? fm.removeItem(at: url)
        reload()
    }

    // MARK: Videos

    func importVideos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        for (index, item) in items.enumerated() {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { continue }
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension.lowercased()
            let destination = videosDir.appendingPathComponent("\(stamp())-\(index).\(ext)")
            try? fm.moveItem(at: movie.url, to: destination)
        }
        isImporting = false
        reload()
    }

    func deleteVideo(_ url: URL) {
        try? fm.removeItem(at: url)
        reload()
    }

    // MARK: Track

    func importTrack(from source: URL) async throws {
        isImporting = true
        defer { isImporting = false }

        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }

        for old in files(in: trackDir) { try? fm.removeItem(at: old) }
        let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension.lowercased()
        let destination = trackDir.appendingPathComponent("track-\(stamp()).\(ext)")
        try fm.copyItem(at: source, to: destination)

        // Make sure the file really is playable audio.
        _ = try AVAudioPlayer(contentsOf: destination)

        UserDefaults.standard.set(source.deletingPathExtension().lastPathComponent, forKey: Keys.trackName)

        let clip = await Task.detached(priority: .userInitiated) {
            SoundFactory.makeNotificationClip(from: destination)
        }.value
        if let clip {
            UserDefaults.standard.set(clip, forKey: Keys.notificationSound)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.notificationSound)
        }
        reload()
    }
}

/// Lets PhotosPicker hand over a video as a file instead of loading it into memory.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Memory-friendly image loading (downsampled, orientation applied).
enum ImageLoader {
    static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func jpegData(from data: Data, maxPixel: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = thumbnail(from: source, maxPixel: maxPixel) else { return nil }
        return image.jpegData(compressionQuality: 0.88)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func load(_ url: URL?, maxPixel: CGFloat) async -> UIImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageLoader.downsample(url, maxPixel: maxPixel)
        }.value
    }

    static func videoThumbnail(_ url: URL) async -> (UIImage?, Double) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        return (image.map { UIImage(cgImage: $0) }, duration)
    }
}

enum Keys {
    static let trackName = "trackName"
    static let notificationSound = "notificationSound"
}
