import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct VideoCacheStats {
  let cachedBytes: Int64
  let contentLength: Int64
  let cachedPercent: Int

  static let empty = VideoCacheStats(cachedBytes: 0, contentLength: -1, cachedPercent: 0)
}

final class VideoStreamCache {
  static let shared = VideoStreamCache()

  fileprivate struct CacheMetadata: Codable {
    let originalURL: String
    let mimeType: String?
    let contentLength: Int64
    let isComplete: Bool
    let lastAccessTimestamp: TimeInterval
  }

  struct CacheRecord {
    let key: String
    let originalURL: URL
    let dataURL: URL
    let metadataURL: URL
  }

  private let fileManager = FileManager.default
  private let queue = DispatchQueue(label: "com.nyjs.nativeplayer.VideoStreamCache")
  private let cacheDirectory: URL
  private let maxCacheSizeBytes: Int64 = 768 * 1024 * 1024
  private let customScheme = "mediaplayer-stream-cache"

  private init() {
    let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDirectory = root.appendingPathComponent("streaming-video-cache", isDirectory: true)
    if !fileManager.fileExists(atPath: cacheDirectory.path) {
      try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
  }

  static func isRemoteURL(_ url: URL?) -> Bool {
    guard let scheme = url?.scheme?.lowercased() else {
      return false
    }
    return scheme == "http" || scheme == "https"
  }

  static func stableKey(for value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func prepareAsset(for remoteURL: URL) -> (asset: AVAsset, loader: VideoStreamResourceLoader?) {
    let record = cacheRecord(for: remoteURL)
    touch(record: record)

    if let metadata = metadata(for: record),
       metadata.isComplete,
       fileManager.fileExists(atPath: record.dataURL.path) {
      return (AVURLAsset(url: record.dataURL), nil)
    }

    guard supportsProgressiveCaching(for: remoteURL) else {
      return (AVURLAsset(url: remoteURL), nil)
    }

    let cachedURL = rewrittenURL(for: remoteURL)
    let asset = AVURLAsset(url: cachedURL)
    let loader = VideoStreamResourceLoader(remoteURL: remoteURL, record: record, owner: self)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    return (asset, loader)
  }

  func cacheStats(for remoteURL: URL) -> VideoCacheStats {
    let record = cacheRecord(for: remoteURL)
    let metadata = metadata(for: record)
    let cachedBytes = fileSize(at: record.dataURL)
    let contentLength = metadata?.contentLength ?? -1
    let cachedPercent: Int
    if let metadata, metadata.isComplete, cachedBytes > 0 {
      cachedPercent = 100
    } else if contentLength > 0 {
      cachedPercent = min(100, max(0, Int((cachedBytes * 100) / contentLength)))
    } else {
      cachedPercent = 0
    }

    return VideoCacheStats(
      cachedBytes: cachedBytes,
      contentLength: contentLength,
      cachedPercent: cachedPercent
    )
  }

  func cacheRecord(for remoteURL: URL) -> CacheRecord {
    let key = Self.stableKey(for: remoteURL.absoluteString)
    let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension

    let oldDataURL = cacheDirectory.appendingPathComponent("\(key).video")
    let newDataURL = cacheDirectory.appendingPathComponent("\(key).\(ext)")

    if fileManager.fileExists(atPath: oldDataURL.path) && !fileManager.fileExists(atPath: newDataURL.path) {
      try? fileManager.moveItem(at: oldDataURL, to: newDataURL)
    }

    return CacheRecord(
      key: key,
      originalURL: remoteURL,
      dataURL: newDataURL,
      metadataURL: cacheDirectory.appendingPathComponent("\(key).json")
    )
  }

  fileprivate func persistMetadata(
    for record: CacheRecord,
    mimeType: String?,
    contentLength: Int64,
    isComplete: Bool
  ) {
    queue.async {
      let metadata = CacheMetadata(
        originalURL: record.originalURL.absoluteString,
        mimeType: mimeType,
        contentLength: contentLength,
        isComplete: isComplete,
        lastAccessTimestamp: Date().timeIntervalSince1970
      )

      guard let data = try? JSONEncoder().encode(metadata) else {
        return
      }

      try? data.write(to: record.metadataURL, options: .atomic)
      self.cleanupIfNeeded()
    }
  }

  fileprivate func metadata(for record: CacheRecord) -> CacheMetadata? {
    guard let data = try? Data(contentsOf: record.metadataURL) else {
      return nil
    }
    return try? JSONDecoder().decode(CacheMetadata.self, from: data)
  }

  func touch(record: CacheRecord) {
    queue.async {
      let now = Date()
      try? self.fileManager.setAttributes([.modificationDate: now], ofItemAtPath: record.dataURL.path)
      try? self.fileManager.setAttributes([.modificationDate: now], ofItemAtPath: record.metadataURL.path)
    }
  }

  func contentTypeIdentifier(for mimeType: String?) -> String? {
    guard let mimeType, !mimeType.isEmpty else {
      return nil
    }
    return UTType(mimeType: mimeType)?.identifier
  }

  private func rewrittenURL(for remoteURL: URL) -> URL {
    var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
    components?.scheme = customScheme
    return components?.url ?? remoteURL
  }

  private func supportsProgressiveCaching(for url: URL) -> Bool {
    guard Self.isRemoteURL(url) else {
      return false
    }

    let path = url.path.lowercased()
    return !path.hasSuffix(".m3u8")
  }

  private func fileSize(at url: URL) -> Int64 {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let size = values.fileSize else {
      return 0
    }
    return Int64(size)
  }

  private func cleanupIfNeeded() {
    let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard let contents = try? fileManager.contentsOfDirectory(
      at: cacheDirectory,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let dataFiles = contents.filter { $0.pathExtension != "json" && !$0.lastPathComponent.hasPrefix(".") }
    var totalSize = dataFiles.reduce(Int64(0)) { partial, url in
      partial + fileSize(at: url)
    }

    guard totalSize > maxCacheSizeBytes else {
      return
    }

    let sorted = dataFiles.sorted {
      let left = (try? $0.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
      let right = (try? $1.resourceValues(forKeys: resourceKeys).contentModificationDate) ?? .distantPast
      return left < right
    }

    for fileURL in sorted where totalSize > maxCacheSizeBytes {
      let size = fileSize(at: fileURL)
      let metadataURL = cacheDirectory.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent).appendingPathExtension("json")
      try? fileManager.removeItem(at: fileURL)
      try? fileManager.removeItem(at: metadataURL)
      totalSize -= size
    }
  }
}

final class VideoStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
  let queue = DispatchQueue(label: "com.nyjs.nativeplayer.VideoStreamResourceLoader")

  private let remoteURL: URL
  private let record: VideoStreamCache.CacheRecord
  private let owner: VideoStreamCache
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  private var dataTask: URLSessionDataTask?
  private var pendingRequests: [AVAssetResourceLoadingRequest] = []
  private var mimeType: String?
  private var contentLength: Int64 = -1
  private var downloadedBytes: Int64 = 0
  private var isDownloadComplete = false
  private var lastPersistedBytes: Int64 = 0
  private var writeHandle: FileHandle?

  init(remoteURL: URL, record: VideoStreamCache.CacheRecord, owner: VideoStreamCache) {
    self.remoteURL = remoteURL
    self.record = record
    self.owner = owner
    super.init()

    downloadedBytes = existingFileSize()
    if let metadata = owner.metadata(for: record) {
      mimeType = metadata.mimeType
      contentLength = metadata.contentLength
      isDownloadComplete = metadata.isComplete && downloadedBytes > 0
    }
  }

  deinit {
    queue.sync {
      dataTask?.cancel()
      try? writeHandle?.close()
      session.invalidateAndCancel()
    }
  }

  var cacheStats: VideoCacheStats {
    let percent: Int
    if isDownloadComplete, downloadedBytes > 0 {
      percent = 100
    } else if contentLength > 0 {
      percent = min(100, max(0, Int((downloadedBytes * 100) / contentLength)))
    } else {
      percent = 0
    }

    return VideoCacheStats(
      cachedBytes: downloadedBytes,
      contentLength: contentLength,
      cachedPercent: percent
    )
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    queue.async {
      self.pendingRequests.append(loadingRequest)
      self.startDataTaskIfNeeded()
      self.processPendingRequests()
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    queue.async {
      self.pendingRequests.removeAll { $0 === loadingRequest }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    queue.async {
      if let httpResponse = response as? HTTPURLResponse,
         self.downloadedBytes > 0,
         httpResponse.statusCode != 206 {
        self.resetCacheFile()
      }

      self.mimeType = response.mimeType

      if let httpResponse = response as? HTTPURLResponse,
         let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
         let totalLength = Self.totalLength(fromContentRange: contentRange) {
        self.contentLength = totalLength
      } else if response.expectedContentLength > 0 {
        self.contentLength = max(self.contentLength, self.downloadedBytes + response.expectedContentLength)
      }

      self.persistMetadataIfNeeded(force: true)
      self.processPendingRequests()
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async {
      self.append(data: data)
      self.processPendingRequests()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    queue.async {
      self.dataTask = nil
      if error == nil {
        if self.contentLength <= 0 {
          self.contentLength = self.downloadedBytes
        }
        self.isDownloadComplete = self.contentLength <= 0 || self.downloadedBytes >= self.contentLength
      }

      self.persistMetadataIfNeeded(force: true)

      if let error {
        self.pendingRequests.forEach { $0.finishLoading(with: error) }
        self.pendingRequests.removeAll()
      } else {
        self.processPendingRequests()
      }

      try? self.writeHandle?.close()
      self.writeHandle = nil
    }
  }

  private func startDataTaskIfNeeded() {
    guard !isDownloadComplete, dataTask == nil else {
      return
    }

    prepareWriteHandleIfNeeded()

    var request = URLRequest(url: remoteURL)
    if downloadedBytes > 0 {
      request.setValue("bytes=\(downloadedBytes)-", forHTTPHeaderField: "Range")
    }

    let task = session.dataTask(with: request)
    dataTask = task
    task.resume()
  }

  private func prepareWriteHandleIfNeeded() {
    if !FileManager.default.fileExists(atPath: record.dataURL.path) {
      FileManager.default.createFile(atPath: record.dataURL.path, contents: nil)
    }

    if writeHandle == nil {
      writeHandle = try? FileHandle(forWritingTo: record.dataURL)
      try? writeHandle?.seekToEnd()
    }
  }

  private func resetCacheFile() {
    try? writeHandle?.close()
    writeHandle = nil
    try? Data().write(to: record.dataURL, options: .atomic)
    downloadedBytes = 0
    isDownloadComplete = false
    prepareWriteHandleIfNeeded()
  }

  private func append(data: Data) {
    prepareWriteHandleIfNeeded()
    try? writeHandle?.seekToEnd()
    try? writeHandle?.write(contentsOf: data)
    downloadedBytes += Int64(data.count)
    persistMetadataIfNeeded(force: downloadedBytes - lastPersistedBytes >= 512 * 1024)
  }

  private func processPendingRequests() {
    pendingRequests = pendingRequests.filter { loadingRequest in
      fillInContentInformationRequest(loadingRequest.contentInformationRequest)
      let fulfilled = respond(to: loadingRequest.dataRequest)
      if fulfilled {
        loadingRequest.finishLoading()
      }
      return !fulfilled
    }
  }

  private func fillInContentInformationRequest(_ request: AVAssetResourceLoadingContentInformationRequest?) {
    guard let request else {
      return
    }

    request.isByteRangeAccessSupported = true
    if contentLength > 0 {
      request.contentLength = contentLength
    }
    request.contentType = owner.contentTypeIdentifier(for: mimeType)
  }

  private func respond(to request: AVAssetResourceLoadingDataRequest?) -> Bool {
    guard let request else {
      return true
    }

    let requestedOffset = request.requestedOffset
    let currentOffset = request.currentOffset == 0 ? requestedOffset : request.currentOffset
    let bytesAvailable = downloadedBytes - currentOffset

    guard bytesAvailable > 0 else {
      return isDownloadComplete && downloadedBytes > requestedOffset
    }

    let unreadBytes = Int64(request.requestedLength) - (currentOffset - requestedOffset)
    let bytesToRespond = Int(min(bytesAvailable, unreadBytes))

    guard bytesToRespond > 0, let data = readData(offset: currentOffset, length: bytesToRespond) else {
      return false
    }

    request.respond(with: data)

    let endOffset = currentOffset + Int64(data.count)
    let requestedEnd = requestedOffset + Int64(request.requestedLength)
    return endOffset >= requestedEnd || (isDownloadComplete && endOffset >= downloadedBytes)
  }

  private func readData(offset: Int64, length: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: record.dataURL) else {
      return nil
    }

    defer {
      try? handle.close()
    }

    try? handle.seek(toOffset: UInt64(offset))
    return try? handle.read(upToCount: length)
  }

  private func persistMetadataIfNeeded(force: Bool) {
    guard force || downloadedBytes != lastPersistedBytes else {
      return
    }
    lastPersistedBytes = downloadedBytes
    owner.persistMetadata(
      for: record,
      mimeType: mimeType,
      contentLength: contentLength,
      isComplete: isDownloadComplete
    )
  }

  private func existingFileSize() -> Int64 {
    guard let values = try? record.dataURL.resourceValues(forKeys: [.fileSizeKey]),
          let size = values.fileSize else {
      return 0
    }
    return Int64(size)
  }

  private static func totalLength(fromContentRange header: String) -> Int64? {
    guard let slashIndex = header.lastIndex(of: "/") else {
      return nil
    }
    let totalPart = header[header.index(after: slashIndex)...]
    return Int64(totalPart)
  }
}
