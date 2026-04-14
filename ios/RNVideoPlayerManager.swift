import AVFoundation
import CryptoKit
import Photos
import React
import UIKit
import UniformTypeIdentifiers

 struct ImportedFolderBookmarkRecord {
  let url: URL
  let bookmarkData: Data
}

@objc(RNVideoPlayer)
final class RNVideoPlayer: RCTViewManager {
  override func view() -> UIView! {
    RNVideoPlayerView()
  }

  override static func requiresMainQueueSetup() -> Bool {
    true
  }
}
