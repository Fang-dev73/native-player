import React
import Photos
import UIKit
import CryptoKit


@objc(MediaScanner)
final class MediaScanner: RCTEventEmitter, PHPhotoLibraryChangeObserver, UIDocumentPickerDelegate {
  private static let importedFolderBookmarksKey = "ios_imported_video_folder_bookmarks"
  private static let thumbnailCacheDirectoryName = "video_thumbs"
  private static let thumbnailMaximumSize = CGSize(width: 320, height: 180)
  private static let supportedVideoExtensions: Set<String> = [
    "3gp",
    "3gpp",
    "avi",
    "flv",
    "m2ts",
    "m4v",
    "mkv",
    "mov",
    "mp4",
    "mpeg",
    "mpg",
    "mts",
    "ts",
    "webm",
    "wmv",
  ]

  private var hasListeners = false
  private var activeScopedFolderURLs: [URL] = []
  private var pendingFolderPickerResolve: RCTPromiseResolveBlock?
  private var pendingFolderPickerReject: RCTPromiseRejectBlock?
  private weak var activeFolderPicker: UIDocumentPickerViewController?
  private let photoImageManager = PHCachingImageManager()

  override init() {
    super.init()
    PHPhotoLibrary.shared().register(self)
    refreshSecurityScopedAccess()
  }

  deinit {
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
    clearActiveSecurityScopedAccess()
  }

  override func startObserving() {
    hasListeners = true
  }

  override func stopObserving() {
    hasListeners = false
  }

  override func supportedEvents() -> [String]! {
    ["mediaUpdated"]
  }

  func photoLibraryDidChange(_ changeInstance: PHChange) {
    emitMediaUpdated()
  }

  override static func requiresMainQueueSetup() -> Bool {
    false
  }

  @objc
  func getVideos(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.global(qos: .userInitiated).async {
      let photoLibraryVideos = self.fetchPhotoLibraryVideos()
      let importedFolderVideos = self.fetchImportedFolderVideos()
      let mergedVideos = (photoLibraryVideos + importedFolderVideos).sorted { left, right in
        let leftDate = left["dateAdded"] as? Double ?? 0
        let rightDate = right["dateAdded"] as? Double ?? 0
        if leftDate == rightDate {
          let leftName = left["name"] as? String ?? ""
          let rightName = right["name"] as? String ?? ""
          return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
        return leftDate > rightDate
      }

      resolve(mergedVideos)
    }
  }

  @objc
  func pickVideoFolder(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async {
      guard self.pendingFolderPickerResolve == nil else {
        reject("PICKER_BUSY", "A folder picker is already open.", nil)
        return
      }

      guard let presenter = self.topViewController() else {
        reject("NO_VIEW_CONTROLLER", "Could not find a view controller to present the folder picker.", nil)
        return
      }

      let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.folder],
        asCopy: false
      )
      picker.delegate = self
      picker.allowsMultipleSelection = false

      self.pendingFolderPickerResolve = resolve
      self.pendingFolderPickerReject = reject
      self.activeFolderPicker = picker

      presenter.present(picker, animated: true)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === activeFolderPicker else {
      return
    }

    let resolve = pendingFolderPickerResolve
    clearPendingFolderPicker()
    resolve?(["cancelled": true])
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard controller === activeFolderPicker else {
      return
    }

    guard let url = urls.first else {
      let resolve = pendingFolderPickerResolve
      clearPendingFolderPicker()
      resolve?(["cancelled": true])
      return
    }

    let hasAccess = url.startAccessingSecurityScopedResource()
    var shouldReleasePickedFolderAccess = true
    defer {
      if hasAccess && shouldReleasePickedFolderAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      try saveImportedFolderBookmark(for: url)
      if hasAccess {
        appendActiveScopedFolderURL(url)
        shouldReleasePickedFolderAccess = false
      } else {
        refreshSecurityScopedAccess()
      }

      let importedVideoCount = fetchImportedVideos(in: url).count
      emitMediaUpdated()

      let rootName = displayName(for: url)
      let resolve = pendingFolderPickerResolve
      clearPendingFolderPicker()
      resolve?([
        "cancelled": false,
        "folderName": rootName,
        "folderPath": "Files/\(rootName)",
        "videoCount": importedVideoCount,
      ])
    } catch {
      let reject = pendingFolderPickerReject
      clearPendingFolderPicker()
      reject?("BOOKMARK_SAVE_FAILED", "Could not save access to the selected folder.", error)
    }
  }

  private func fetchPhotoLibraryVideos() -> [[String: Any]] {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      return []
    }

    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let allVideos = PHAsset.fetchAssets(with: .video, options: fetchOptions)

    var assetToAlbumMap = [String: String]()

    let albumsFetchOptions = PHFetchOptions()
    let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumsFetchOptions)
    let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: albumsFetchOptions)

    [userAlbums, smartAlbums].forEach { collections in
      collections.enumerateObjects { collection, _, _ in
        let assetsInCollection = PHAsset.fetchAssets(in: collection, options: nil)
        assetsInCollection.enumerateObjects { asset, _, _ in
          if asset.mediaType == .video {
            assetToAlbumMap[asset.localIdentifier] = collection.localizedTitle ?? "Unknown"
          }
        }
      }
    }

    var videoList: [[String: Any]] = []

    allVideos.enumerateObjects { asset, _, _ in
      let albumName = assetToAlbumMap[asset.localIdentifier] ?? "Recents"

      var name = asset.localIdentifier
      if let resource = PHAssetResource.assetResources(for: asset).first {
        name = resource.originalFilename
      }

      let uri = "ph://\(asset.localIdentifier)"
      let thumbnail = self.cachedThumbnailURL(for: asset)?.absoluteString ?? uri
      let video: [String: Any] = [
        "id": asset.localIdentifier,
        "name": name,
        "duration": asset.duration * 1000,
        "folder": albumName,
        "folderPath": albumName,
        "uri": uri,
        "thumbnail": thumbnail,
        "dateAdded": (asset.creationDate?.timeIntervalSince1970 ?? 0) * 1000,
      ]

      videoList.append(video)
    }

    return videoList
  }

  private func fetchImportedFolderVideos() -> [[String: Any]] {
    if activeScopedFolderURLs.isEmpty {
      refreshSecurityScopedAccess()
    }

    let scopedFolderURLs = activeScopedFolderURLs
    guard !scopedFolderURLs.isEmpty else {
      return []
    }

    return scopedFolderURLs.flatMap { fetchImportedVideos(in: $0) }
  }

  private func fetchImportedVideos(in rootURL: URL) -> [[String: Any]] {
    let resourceKeys: Set<URLResourceKey> = [
      .creationDateKey,
      .contentModificationDateKey,
      .isDirectoryKey,
      .nameKey,
    ]

    var videoList: [[String: Any]] = []

    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?

    coordinator.coordinate(readingItemAt: rootURL, options: [], error: &coordinationError) { coordinatedRootURL in
      guard let enumerator = FileManager.default.enumerator(
        at: coordinatedRootURL,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        return
      }

      let rootName = displayName(for: coordinatedRootURL)

      for case let fileURL as URL in enumerator {
        do {
          let values = try fileURL.resourceValues(forKeys: resourceKeys)
          if values.isDirectory == true {
            continue
          }

          guard isSupportedVideoFile(fileURL) else {
            continue
          }

          let relativeParentPath = relativeParentPath(for: fileURL, within: coordinatedRootURL)
          let folderPath = relativeParentPath.isEmpty
            ? "Files/\(rootName)"
            : "Files/\(rootName)/\(relativeParentPath)"
          let folderName = relativeParentPath.split(separator: "/").last.map(String.init) ?? rootName
          let dateAdded = (values.creationDate ?? values.contentModificationDate)?.timeIntervalSince1970 ?? 0
          let thumbnail = cachedThumbnailURL(forVideoAt: fileURL, modifiedAt: values.contentModificationDate)?.absoluteString
            ?? fileURL.absoluteString

          let video: [String: Any] = [
            "id": fileURL.absoluteString,
            "name": values.name ?? fileURL.lastPathComponent,
            "duration": mediaDurationMilliseconds(for: fileURL),
            "folder": folderName,
            "folderPath": folderPath,
            "uri": fileURL.absoluteString,
            "thumbnail": thumbnail,
            "dateAdded": dateAdded * 1000,
          ]

          videoList.append(video)
        } catch {
          continue
        }
      }
    }

    return videoList
  }

  private func mediaDurationMilliseconds(for url: URL) -> Double {
    let asset = AVURLAsset(url: url)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, !seconds.isNaN else {
      return 0
    }
    return seconds * 1000
  }

  private func isSupportedVideoFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return Self.supportedVideoExtensions.contains(ext)
  }

  private func relativeParentPath(for fileURL: URL, within rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path

    guard parentPath.hasPrefix(rootPath) else {
      return ""
    }

    let suffix = String(parentPath.dropFirst(rootPath.count))
    return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func displayName(for url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Imported Files" : name
  }

  private func cachedThumbnailURL(for asset: PHAsset) -> URL? {
    let cacheURL = thumbnailCacheURL(for: "photo:\(asset.localIdentifier)")
    if FileManager.default.fileExists(atPath: cacheURL.path) {
      return cacheURL
    }

    let options = PHImageRequestOptions()
    options.deliveryMode = .fastFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.isSynchronous = true

    var thumbnailImage: UIImage?
    photoImageManager.requestImage(
      for: asset,
      targetSize: Self.thumbnailMaximumSize,
      contentMode: .aspectFill,
      options: options
    ) { image, _ in
      thumbnailImage = image
    }

    guard let thumbnailImage else {
      return nil
    }

    return writeThumbnailImage(thumbnailImage, to: cacheURL) ? cacheURL : nil
  }

  private func cachedThumbnailURL(forVideoAt videoURL: URL, modifiedAt: Date?) -> URL? {
    let modifiedTimestamp = Int((modifiedAt ?? .distantPast).timeIntervalSince1970)
    let cacheURL = thumbnailCacheURL(
      for: "file:\(videoURL.standardizedFileURL.path):\(modifiedTimestamp)"
    )
    if FileManager.default.fileExists(atPath: cacheURL.path) {
      return cacheURL
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = Self.thumbnailMaximumSize

    let durationSeconds = CMTimeGetSeconds(asset.duration)
    let previewSecond: Double
    if durationSeconds.isFinite, !durationSeconds.isNaN, durationSeconds > 0.2 {
      previewSecond = min(1, max(0, durationSeconds * 0.1))
    } else {
      previewSecond = 0
    }

    let previewTime = CMTime(seconds: previewSecond, preferredTimescale: 600)
    guard let cgImage = try? generator.copyCGImage(at: previewTime, actualTime: nil) else {
      return nil
    }

    let thumbnailImage = UIImage(cgImage: cgImage)
    return writeThumbnailImage(thumbnailImage, to: cacheURL) ? cacheURL : nil
  }

  private func writeThumbnailImage(_ image: UIImage, to url: URL) -> Bool {
    guard let imageData = image.jpegData(compressionQuality: 0.82) else {
      return false
    }

    do {
      let directoryURL = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
      try imageData.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private func thumbnailCacheURL(for key: String) -> URL {
    let directoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Self.thumbnailCacheDirectoryName, isDirectory: true)
    let hashedKey = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    return directoryURL.appendingPathComponent("\(hashedKey).jpg")
  }

  private func saveImportedFolderBookmark(for url: URL) throws {
    let newBookmarkData = try url.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let newPath = url.standardizedFileURL.path

    var records = resolvedImportedFolderBookmarkRecords()
    records.removeAll { $0.url.standardizedFileURL.path == newPath }
    records.insert(
      ImportedFolderBookmarkRecord(url: url, bookmarkData: newBookmarkData),
      at: 0
    )

    UserDefaults.standard.set(records.map(\.bookmarkData), forKey: Self.importedFolderBookmarksKey)
  }

  private func resolvedImportedFolderBookmarkRecords() -> [ImportedFolderBookmarkRecord] {
    let storedBookmarks = UserDefaults.standard.object(forKey: Self.importedFolderBookmarksKey) as? [Data] ?? []
    var resolvedRecords: [ImportedFolderBookmarkRecord] = []
    var seenPaths = Set<String>()
    var didChange = false

    storedBookmarks.forEach { bookmarkData in
      do {
        var isStale = false
        let url = try URL(
          resolvingBookmarkData: bookmarkData,
          options: [],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
        let normalizedPath = url.standardizedFileURL.path

        guard seenPaths.insert(normalizedPath).inserted else {
          didChange = true
          return
        }

        let refreshedBookmarkData = isStale
          ? try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          : bookmarkData

        if isStale {
          didChange = true
        }

        resolvedRecords.append(
          ImportedFolderBookmarkRecord(
            url: url,
            bookmarkData: refreshedBookmarkData
          )
        )
      } catch {
        didChange = true
      }
    }

    if didChange {
      UserDefaults.standard.set(resolvedRecords.map(\.bookmarkData), forKey: Self.importedFolderBookmarksKey)
    }

    return resolvedRecords
  }

  private func refreshSecurityScopedAccess() {
    clearActiveSecurityScopedAccess()

    activeScopedFolderURLs = resolvedImportedFolderBookmarkRecords().compactMap { record in
      record.url.startAccessingSecurityScopedResource() ? record.url : nil
    }
  }

  private func clearActiveSecurityScopedAccess() {
    activeScopedFolderURLs.forEach { url in
      url.stopAccessingSecurityScopedResource()
    }
    activeScopedFolderURLs.removeAll()
  }

  private func appendActiveScopedFolderURL(_ url: URL) {
    let normalizedPath = url.standardizedFileURL.path
    let alreadyTracked = activeScopedFolderURLs.contains {
      $0.standardizedFileURL.path == normalizedPath
    }

    if !alreadyTracked {
      activeScopedFolderURLs.append(url)
    }
  }

  private func emitMediaUpdated() {
    DispatchQueue.main.async {
      if self.hasListeners {
        self.sendEvent(withName: "mediaUpdated", body: nil)
      }
    }
  }

  private func clearPendingFolderPicker() {
    pendingFolderPickerResolve = nil
    pendingFolderPickerReject = nil
    activeFolderPicker = nil
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let rootViewController = base ?? keyWindowRootViewController()

    if let navigationController = rootViewController as? UINavigationController {
      return topViewController(base: navigationController.visibleViewController)
    }

    if let tabBarController = rootViewController as? UITabBarController {
      return topViewController(base: tabBarController.selectedViewController)
    }

    if let presentedViewController = rootViewController?.presentedViewController {
      return topViewController(base: presentedViewController)
    }

    return rootViewController
  }

  private func keyWindowRootViewController() -> UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: \.isKeyWindow)?
      .rootViewController
  }
}