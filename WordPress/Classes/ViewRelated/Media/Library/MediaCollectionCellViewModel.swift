import UIKit

final class MediaCollectionCellViewModel {
    var onImageLoaded: ((UIImage) -> Void)?
    @Published private(set) var overlayState: CircularProgressView.State?
    @Published var badgeText: String?
    let mediaID: TaggedManagedObjectID<Media>
    var mediaType: MediaType

    private let media: Media
    private let service: MediaImageService
    private let cache: MemoryCache
    private var isVisible = false
    private var isPrefetchingNeeded = false
    private var imageTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var thumbnailObservation: NSKeyValueObservation?

    deinit {
        imageTask?.cancel()
    }

    init(media: Media,
         service: MediaImageService = .shared,
         cache: MemoryCache = .shared) {
        self.mediaID = TaggedManagedObjectID(media)
        self.media = media
        self.mediaType = media.mediaType
        self.service = service
        self.cache = cache

        statusObservation = media.observe(\.remoteStatusNumber, options: [.new]) { [weak self] media, _ in
            self?.updateOverlayState()
        }

        // No sure why but `.initial` didn't work.
        self.updateOverlayState()

        thumbnailObservation = media.observe(\.localThumbnailURL, options: [.new]) { [weak self] media, _ in
            self?.didUpdateLocalThumbnail()
        }
    }

    // MARK: - View Lifecycle

    func onAppear() {
        guard !isVisible else { return }
        isVisible = true
        fetchThumbnailIfNeeded()
    }

    func onDisappear() {
        guard isVisible else { return }
        isVisible = false
        cancelThumbnailRequestIfNeeded()
    }

    func startPrefetching() {
        guard !isPrefetchingNeeded else { return }
        isPrefetchingNeeded = true
        fetchThumbnailIfNeeded()
    }

    func cancelPrefetching() {
        guard isPrefetchingNeeded else { return }
        isPrefetchingNeeded = false
        cancelThumbnailRequestIfNeeded()
    }

    // MARK: - Thumbnail

    private func fetchThumbnailIfNeeded() {
        guard isVisible || isPrefetchingNeeded else {
            return
        }
        guard imageTask == nil else {
            return // Already loading
        }
        guard getCachedThubmnail() == nil else {
            return // Already cached  in memory
        }
        imageTask = Task { @MainActor [service, media, weak self] in
            do {
                let image = try await service.thumbnail(for: media)
                self?.didFinishLoading(with: image)
            } catch {
                self?.didFinishLoading(with: nil)
            }
        }
    }

    private func cancelThumbnailRequestIfNeeded() {
        guard !isVisible && !isPrefetchingNeeded else { return }
        imageTask?.cancel()
        imageTask = nil
    }

    private func didFinishLoading(with image: UIImage?) {
        if let image {
            cache.setImage(image, forKey: makeCacheKey(for: media))
        }
        if !Task.isCancelled {
            if let image {
                onImageLoaded?(image)
            }
            imageTask = nil
        }
    }

    /// Returns the image from the memory cache.
    func getCachedThubmnail() -> UIImage? {
        cache.getImage(forKey: makeCacheKey(for: media))
    }

    private func makeCacheKey(for media: Media) -> String {
        "thumbnail-\(media.objectID)"
    }

    // Monitors thumbnails generated by `MediaImportService`.
    private func didUpdateLocalThumbnail() {
        guard media.remoteStatus != .sync, media.localThumbnailURL != nil else { return }
        fetchThumbnailIfNeeded()
    }

    // MARK: - Status

    private func updateOverlayState() {
        switch media.remoteStatus {
        case .pushing, .processing:
            self.overlayState = .indeterminate
        case .failed:
            self.overlayState = .retry
        case .sync:
            self.overlayState = nil
        default:
            break
        }
    }
}
