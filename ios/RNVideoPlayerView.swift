import AVFoundation
import AVKit
// import MediaPlayer avoided due to module name clash
import Photos
import React
import UIKit
import UniformTypeIdentifiers
import zlib

fileprivate struct IOSVideoSourceEntry {
  let uri: String
  let title: String?
}

fileprivate struct SubtitleCue {
  let start: Double
  let end: Double
  let text: String
}

fileprivate struct SubtitleSearchResult {
  let mediaTitle: String
  let releaseName: String
  let language: String
  let fileName: String
  let downloadURL: String
}

fileprivate struct SubtitleMediaMatch {
  let sdId: String
  let slug: String
  let title: String
  let subtitlesCount: Int
}

fileprivate extension IOSVideoSourceEntry {
  var stableKey: String {
    "\(uri)|\(title ?? "")"
  }
}

private enum GestureMode {
  case none
  case brightness
  case volume
  case panZoom
}

@objc(RNVideoPlayerView)
final class RNVideoPlayerView: UIView, AVPictureInPictureControllerDelegate, UIDocumentPickerDelegate, UIGestureRecognizerDelegate, AVPlayerItemLegibleOutputPushDelegate {
  @objc var source: Any? {
    didSet { applySource() }
  }

  @objc var index: Int = 0 {
    didSet { applyIndex(index) }
  }

  @objc var title: String? {
    didSet { updateDisplayedTitle() }
  }

  @objc var paused: Bool = false {
    didSet { paused ? pausePlayback(userInitiated: false) : playPlayback(userInitiated: false) }
  }

  @objc var controls: Bool = true {
    didSet { updateControlsAvailability() }
  }

  @objc var enableSubtitle: Bool = false {
    didSet { updateControlsAvailability() }
  }

  @objc var progressColor: UIColor = UIColor(red: 0, green: 0.75, blue: 0.65, alpha: 1) {
    didSet { bufferedSlider.progressTintColor = progressColor }
  }

  @objc var trackColor: UIColor = UIColor.white.withAlphaComponent(0.4) {
    didSet { bufferedSlider.trackTintColor = trackColor }
  }

  @objc var thumbColor: UIColor = UIColor(red: 0, green: 0.75, blue: 0.65, alpha: 1) {
    didSet { bufferedSlider.thumbTintColor = thumbColor }
  }

  @objc var buttonTintColor: UIColor = .white {
    didSet { refreshButtonTint() }
  }

  @objc var durationColor: UIColor = .white {
    didSet {
      currentTimeLabel.textColor = durationColor
      durationLabel.textColor = durationColor
    }
  }

  @objc var subtitleColor: UIColor = .white {
    didSet { subtitleLabel.textColor = subtitleColor }
  }

  @objc var subtitleCheckboxColor: UIColor = .white
  @objc var subtitleDescriptionColor: UIColor = .white

  @objc var resumePlaybackEnabled: Bool = true

  @objc var onLoad: RCTDirectEventBlock?
  @objc var onProgress: RCTDirectEventBlock?
  @objc var onVideoEnd: RCTDirectEventBlock?
  @objc var onBack: RCTDirectEventBlock?

  private static let subdlBaseURL = "https://subdl.com"
  private static let subtitleUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

  private let player = AVPlayer()
  private let playerSurfaceView = PlayerSurfaceView()
  private let pictureInPictureSourceView = PlayerSurfaceView()
  private let brightnessPreviewView = UIView()
  private let controlsContainer = UIView()
  private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
  private let topContent = UIView()
  private let topRootStack = UIStackView()
  private let leftHeaderStack = UIStackView()
  private let rightToolsStack = UIStackView()
  private let topToolRowOne = UIStackView()
  private let topToolRowTwo = UIStackView()
  private let topSpacerView = UIView()
  private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
  private let centerControls = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
  private let titleLabel = UILabel()
  private let currentTimeLabel = UILabel()
  private let durationLabel = UILabel()
  private let overlayLabel = PaddingLabel()
  private let subtitleLabel = PaddingLabel()
  private let zoomLabel = PaddingLabel()
  private let brightnessHud = GestureHudView(symbol: "sun.max.fill", fillColor: UIColor(red: 1.0, green: 0.84, blue: 0.31, alpha: 1))
  private let volumeHud = GestureHudView(symbol: "speaker.wave.3.fill", fillColor: UIColor(red: 0.50, green: 0.85, blue: 1.0, alpha: 1))
  private let loader = UIActivityIndicatorView(style: .large)
  private let bufferedSlider = BufferedSlider()
  private let backButton = UIButton(type: .system)
  private let subtitleButton = UIButton(type: .system)
  private let speedButton = UIButton(type: .system)
  private let screenshotButton = UIButton(type: .system)
  private let backgroundPlayButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let shuffleButton = UIButton(type: .system)
  private let lockButton = UIButton(type: .system)
  private let loopButton = UIButton(type: .system)
  private let playButton = UIButton(type: .system)
  private let rewindButton = UIButton(type: .system)
  private let forwardButton = UIButton(type: .system)
  private let unlockButton = UIButton(type: .system)
  private let hiddenVolumeView: UIView = {
    if let volumeViewClass = NSClassFromString("MPVolumeView") as? UIView.Type {
      return volumeViewClass.init(frame: .zero)
    }
    return UIView(frame: .zero)
  }()

  private var timeObserverToken: Any?
  private var playerStatusObservation: NSKeyValueObservation?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemPresentationSizeObservation: NSKeyValueObservation?
  private var itemLoadedRangesObservation: NSKeyValueObservation?
  private var itemLikelyToKeepUpObservation: NSKeyValueObservation?
  private var itemBufferEmptyObservation: NSKeyValueObservation?
  private var pictureInPicturePossibleObservation: NSKeyValueObservation?
  private var playbackEndedObserver: NSObjectProtocol?

  private var hideControlsWorkItem: DispatchWorkItem?
  private var gestureHudHideWorkItem: DispatchWorkItem?
  private var overlayWorkItem: DispatchWorkItem?
  private var clearSubtitleWorkItem: DispatchWorkItem?
  private var pictureInPictureStartRetryWorkItem: DispatchWorkItem?

  private var queueEntries: [IOSVideoSourceEntry] = []
  private var currentIndex = 0
  private var isLooping = false
  private var isShuffleEnabled = false
  private var shuffledIndexes: [Int] = []
  private var shuffledPosition = -1
  private var pendingResumePosition: Double?
  private var lastDuration: Double = 0
  private var lastPersistedPosition: Double = -1
  private var controlsVisible = true
  private var controlsLocked = false
  private var backgroundPlayEnabled = UserDefaults.standard.bool(forKey: "ios_background_play_enabled")
  private var pictureInPictureEnabled =
    (UserDefaults.standard.object(forKey: "ios_picture_in_picture_enabled") as? Bool) ?? true
  private var autoPausedForBackground = false
  private var currentPlaybackRate: Float = 1.0
  private var currentMediaURI: String?
  private var currentRemoteURL: URL?
  private var currentResourceLoader: VideoStreamResourceLoader?
  private var currentEmbeddedSubtitleOption: AVMediaSelectionOption?
  private var currentEmbeddedSubtitleGroup: AVMediaSelectionGroup?
  private var customSubtitleURL: URL?
  private var customSubtitleCues: [SubtitleCue] = []
  private var subtitleEnabled = true
  private var currentSubtitleText = ""
  private var lastEmbeddedSubtitleTimestamp = CACurrentMediaTime()
  private var pictureInPictureController: AVPictureInPictureController?
  private var lastProgressEventTimestamp = CACurrentMediaTime()
  private var currentSourceIsRemote = false
  private var isVideoVertical = false
  private var isInPictureInPictureMode = false
  private var isPictureInPicturePossible = false
  private var pendingAutoPictureInPicture = false
  private var isAppInBackground = false
  private var isAttemptingPictureInPictureStart = false
  private var shouldPauseAfterPictureInPictureStarts = false
  private var currentVideoPresentationSize: CGSize = .zero
  private var videoScale: CGFloat = 1
  private var videoTranslation: CGPoint = .zero
  private var gestureMode: GestureMode = .none
  private var gestureStartBrightness = UIScreen.main.brightness
  private var gestureStartVolume: Float = AVAudioSession.sharedInstance().outputVolume
  private var currentGestureBrightnessLevel = UIScreen.main.brightness
  private var currentGestureVolumeLevel = AVAudioSession.sharedInstance().outputVolume
  private var lastPanTranslation: CGPoint = .zero
  private var originalOrientationMask: UIInterfaceOrientationMask?
  private var originalInterfaceOrientation: UIInterfaceOrientation?
  private var appliedOrientationMask: UIInterfaceOrientationMask?
  private let controlsAutoHideDelay: TimeInterval = 6.0
  private var pictureInPictureSourceWidthConstraint: NSLayoutConstraint?
  private var pictureInPictureSourceHeightConstraint: NSLayoutConstraint?
  private var isCleaningUp = false
  private var isHandlingBackNavigation = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupPlayer()
    setupViews()
    setupGestures()
    setupNotifications()
    updateControlsAvailability()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupPlayer()
    setupViews()
    setupGestures()
    setupNotifications()
    updateControlsAvailability()
  }

  deinit {
    cleanup()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerSurfaceView.playerLayer.frame = playerSurfaceView.bounds
    pictureInPictureSourceView.playerLayer.frame = pictureInPictureSourceView.bounds
    updateSubtitleLayout()
    updatePictureInPictureSourceLayout()
    applyVideoTransform()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      configurePictureInPictureIfNeeded()
    } else if !isCleaningUp, !isHandlingBackNavigation {
      restoreOriginalOrientationIfNeeded()
      forcePhonePortrait(from: topViewController())
    }
  }

  private func setupPlayer() {
    configureAudioSession()
    playerSurfaceView.playerLayer.player = player
    playerSurfaceView.playerLayer.videoGravity = .resizeAspect
    player.automaticallyWaitsToMinimizeStalling = false
    player.allowsExternalPlayback = true
    if #available(iOS 15.0, *) {
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateBufferingUI()
        self?.dispatchProgressEvent(force: true)
      }
    }

    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
      self?.handlePeriodicTimeUpdate()
    }
  }

  private func setupViews() {
    backgroundColor = .black
    clipsToBounds = true

    hiddenVolumeView.translatesAutoresizingMaskIntoConstraints = false
    hiddenVolumeView.alpha = 0.02
    hiddenVolumeView.isUserInteractionEnabled = false
    addSubview(hiddenVolumeView)

    pictureInPictureSourceView.translatesAutoresizingMaskIntoConstraints = false
    pictureInPictureSourceView.isUserInteractionEnabled = false
    pictureInPictureSourceView.alpha = 0.001
    addSubview(pictureInPictureSourceView)

    playerSurfaceView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(playerSurfaceView)
    bringSubviewToFront(playerSurfaceView)

    brightnessPreviewView.translatesAutoresizingMaskIntoConstraints = false
    brightnessPreviewView.backgroundColor = .black
    brightnessPreviewView.alpha = 0
    brightnessPreviewView.isUserInteractionEnabled = false
    addSubview(brightnessPreviewView)

    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    subtitleLabel.lineBreakMode = .byWordWrapping
    subtitleLabel.textColor = subtitleColor
    subtitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    subtitleLabel.contentInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    subtitleLabel.layer.shadowColor = UIColor.black.cgColor
    subtitleLabel.layer.shadowOpacity = 0.85
    subtitleLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
    subtitleLabel.layer.shadowRadius = 4
    subtitleLabel.isHidden = true
    addSubview(subtitleLabel)

    overlayLabel.translatesAutoresizingMaskIntoConstraints = false
    overlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
    overlayLabel.textColor = .white
    overlayLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    overlayLabel.layer.cornerRadius = 14
    overlayLabel.layer.masksToBounds = true
    overlayLabel.isHidden = true
    addSubview(overlayLabel)

    zoomLabel.translatesAutoresizingMaskIntoConstraints = false
    zoomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
    zoomLabel.textColor = .white
    zoomLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    zoomLabel.layer.cornerRadius = 12
    zoomLabel.layer.masksToBounds = true
    zoomLabel.isHidden = true
    addSubview(zoomLabel)

    loader.translatesAutoresizingMaskIntoConstraints = false
    loader.color = .white
    addSubview(loader)

    controlsContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(controlsContainer)

    brightnessHud.translatesAutoresizingMaskIntoConstraints = false
    brightnessHud.isHidden = true
    brightnessHud.alpha = 0
    addSubview(brightnessHud)

    volumeHud.translatesAutoresizingMaskIntoConstraints = false
    volumeHud.isHidden = true
    volumeHud.alpha = 0
    addSubview(volumeHud)

    topBar.translatesAutoresizingMaskIntoConstraints = false
    topBar.layer.cornerRadius = 18
    topBar.clipsToBounds = true
    controlsContainer.addSubview(topBar)

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.layer.cornerRadius = 18
    bottomBar.clipsToBounds = true
    controlsContainer.addSubview(bottomBar)

    centerControls.translatesAutoresizingMaskIntoConstraints = false
    centerControls.layer.cornerRadius = 24
    centerControls.clipsToBounds = true
    controlsContainer.addSubview(centerControls)

    unlockButton.translatesAutoresizingMaskIntoConstraints = false
    unlockButton.tintColor = .white
    unlockButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    unlockButton.layer.cornerRadius = 28
    unlockButton.layer.borderWidth = 1.5
    unlockButton.layer.borderColor = UIColor.white.cgColor
    unlockButton.setImage(UIImage(systemName: "lock.open.fill"), for: .normal)
    unlockButton.isHidden = true
    unlockButton.addTarget(self, action: #selector(unlockControlsTapped), for: .touchUpInside)
    addSubview(unlockButton)

    topContent.translatesAutoresizingMaskIntoConstraints = false
    topBar.contentView.addSubview(topContent)

    configureButton(backButton, symbol: "chevron.left")
    backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.textColor = .white
    titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    configureButton(subtitleButton, symbol: "captions.bubble.fill")
    subtitleButton.addTarget(self, action: #selector(showSubtitleOptions), for: .touchUpInside)

    speedButton.translatesAutoresizingMaskIntoConstraints = false
    speedButton.tintColor = .white
    speedButton.titleLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    speedButton.setTitle("1x", for: .normal)
    speedButton.setTitleColor(buttonTintColor, for: .normal)
    speedButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
    speedButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
    speedButton.addTarget(self, action: #selector(showSpeedOptions), for: .touchUpInside)

    configureButton(screenshotButton, symbol: "camera.fill")
    screenshotButton.addTarget(self, action: #selector(screenshotTapped), for: .touchUpInside)

    configureButton(backgroundPlayButton, symbol: "play.square.stack.fill")
    backgroundPlayButton.addTarget(self, action: #selector(backgroundPlayTapped), for: .touchUpInside)

    configureButton(settingsButton, symbol: "pip")
    settingsButton.addTarget(self, action: #selector(showSettingsMenu), for: .touchUpInside)

    configureButton(shuffleButton, symbol: "shuffle")
    shuffleButton.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)

    configureButton(lockButton, symbol: "lock.fill")
    lockButton.addTarget(self, action: #selector(lockControlsTapped), for: .touchUpInside)

    configureButton(loopButton, symbol: "repeat")
    loopButton.addTarget(self, action: #selector(loopTapped), for: .touchUpInside)

    topRootStack.translatesAutoresizingMaskIntoConstraints = false
    topRootStack.axis = .horizontal
    topRootStack.alignment = .center
    topRootStack.spacing = 10
    topContent.addSubview(topRootStack)

    leftHeaderStack.translatesAutoresizingMaskIntoConstraints = false
    leftHeaderStack.spacing = 10
    leftHeaderStack.alignment = .center
    leftHeaderStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    leftHeaderStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    topSpacerView.translatesAutoresizingMaskIntoConstraints = false
    topSpacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    topSpacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)

    rightToolsStack.translatesAutoresizingMaskIntoConstraints = false
    rightToolsStack.spacing = 8
    rightToolsStack.alignment = .trailing
    rightToolsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    rightToolsStack.setContentHuggingPriority(.required, for: .horizontal)

    [topToolRowOne, topToolRowTwo].forEach { row in
      row.translatesAutoresizingMaskIntoConstraints = false
      row.axis = .horizontal
      row.spacing = 6
      row.alignment = .center
      row.distribution = .fill
    }

    let centerContent = UIView()
    centerContent.translatesAutoresizingMaskIntoConstraints = false
    centerControls.contentView.addSubview(centerContent)

    configureButton(rewindButton, symbol: "gobackward.10")
    rewindButton.addTarget(self, action: #selector(previousOrRewindTapped), for: .touchUpInside)

    configureButton(playButton, symbol: "play.fill", pointSize: 24)
    playButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
    playButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    playButton.layer.cornerRadius = 28

    configureButton(forwardButton, symbol: "goforward.10")
    forwardButton.addTarget(self, action: #selector(nextOrForwardTapped), for: .touchUpInside)

    let centerStack = UIStackView(arrangedSubviews: [rewindButton, playButton, forwardButton])
    centerStack.translatesAutoresizingMaskIntoConstraints = false
    centerStack.axis = .horizontal
    centerStack.alignment = .center
    centerStack.spacing = 24
    centerContent.addSubview(centerStack)

    let bottomContent = UIView()
    bottomContent.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(bottomContent)

    currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    currentTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    currentTimeLabel.textColor = durationColor
    currentTimeLabel.text = "00:00"

    durationLabel.translatesAutoresizingMaskIntoConstraints = false
    durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.textColor = durationColor
    durationLabel.text = "00:00"

    bufferedSlider.translatesAutoresizingMaskIntoConstraints = false
    bufferedSlider.progressTintColor = progressColor
    bufferedSlider.trackTintColor = trackColor
    bufferedSlider.thumbTintColor = thumbColor
    bufferedSlider.bufferTintColor = UIColor.white.withAlphaComponent(0.9)
    bufferedSlider.addTarget(self, action: #selector(sliderBegan), for: .editingDidBegin)
    bufferedSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    bufferedSlider.addTarget(self, action: #selector(sliderEnded), for: [.editingDidEnd, .touchUpInside, .touchUpOutside, .touchCancel])

    let bottomStack = UIStackView(arrangedSubviews: [currentTimeLabel, bufferedSlider, durationLabel])
    bottomStack.translatesAutoresizingMaskIntoConstraints = false
    bottomStack.axis = .horizontal
    bottomStack.alignment = .center
    bottomStack.spacing = 12
    bottomContent.addSubview(bottomStack)

    pictureInPictureSourceWidthConstraint = pictureInPictureSourceView.widthAnchor.constraint(equalToConstant: 1)
    pictureInPictureSourceHeightConstraint = pictureInPictureSourceView.heightAnchor.constraint(equalToConstant: 1)

    NSLayoutConstraint.activate([
      hiddenVolumeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
      hiddenVolumeView.topAnchor.constraint(equalTo: topAnchor, constant: -4),
      hiddenVolumeView.widthAnchor.constraint(equalToConstant: 1),
      hiddenVolumeView.heightAnchor.constraint(equalToConstant: 1),

      pictureInPictureSourceView.centerXAnchor.constraint(equalTo: centerXAnchor),
      pictureInPictureSourceView.centerYAnchor.constraint(equalTo: centerYAnchor),
      pictureInPictureSourceWidthConstraint!,
      pictureInPictureSourceHeightConstraint!,

      playerSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
      playerSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
      playerSurfaceView.topAnchor.constraint(equalTo: topAnchor),
      playerSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),

      brightnessPreviewView.leadingAnchor.constraint(equalTo: playerSurfaceView.leadingAnchor),
      brightnessPreviewView.trailingAnchor.constraint(equalTo: playerSurfaceView.trailingAnchor),
      brightnessPreviewView.topAnchor.constraint(equalTo: playerSurfaceView.topAnchor),
      brightnessPreviewView.bottomAnchor.constraint(equalTo: playerSurfaceView.bottomAnchor),

      subtitleLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
      subtitleLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
      subtitleLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -92),

      overlayLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      overlayLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      brightnessHud.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
      brightnessHud.centerYAnchor.constraint(equalTo: centerYAnchor),
      brightnessHud.widthAnchor.constraint(equalToConstant: 88),
      brightnessHud.heightAnchor.constraint(equalToConstant: 248),

      volumeHud.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
      volumeHud.centerYAnchor.constraint(equalTo: centerYAnchor),
      volumeHud.widthAnchor.constraint(equalToConstant: 88),
      volumeHud.heightAnchor.constraint(equalToConstant: 248),

      zoomLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      zoomLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),

      loader.centerXAnchor.constraint(equalTo: centerXAnchor),
      loader.centerYAnchor.constraint(equalTo: centerYAnchor),

      controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      controlsContainer.topAnchor.constraint(equalTo: topAnchor),
      controlsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      topBar.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 12),
      topBar.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12),
      topBar.topAnchor.constraint(equalTo: controlsContainer.safeAreaLayoutGuide.topAnchor, constant: 2),

      topContent.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor),
      topContent.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor),
      topContent.topAnchor.constraint(equalTo: topBar.contentView.topAnchor),
      topContent.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor),

      topRootStack.leadingAnchor.constraint(equalTo: topContent.leadingAnchor, constant: 14),
      topRootStack.trailingAnchor.constraint(equalTo: topContent.trailingAnchor, constant: -14),
      topRootStack.topAnchor.constraint(equalTo: topContent.topAnchor, constant: 6),
      topRootStack.bottomAnchor.constraint(equalTo: topContent.bottomAnchor, constant: -6),

      centerControls.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
      centerControls.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),

      centerContent.leadingAnchor.constraint(equalTo: centerControls.contentView.leadingAnchor),
      centerContent.trailingAnchor.constraint(equalTo: centerControls.contentView.trailingAnchor),
      centerContent.topAnchor.constraint(equalTo: centerControls.contentView.topAnchor),
      centerContent.bottomAnchor.constraint(equalTo: centerControls.contentView.bottomAnchor),

      centerStack.leadingAnchor.constraint(equalTo: centerContent.leadingAnchor, constant: 18),
      centerStack.trailingAnchor.constraint(equalTo: centerContent.trailingAnchor, constant: -18),
      centerStack.topAnchor.constraint(equalTo: centerContent.topAnchor, constant: 12),
      centerStack.bottomAnchor.constraint(equalTo: centerContent.bottomAnchor, constant: -12),

      playButton.widthAnchor.constraint(equalToConstant: 56),
      playButton.heightAnchor.constraint(equalToConstant: 56),

      bottomBar.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 12),
      bottomBar.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12),
      bottomBar.bottomAnchor.constraint(equalTo: controlsContainer.safeAreaLayoutGuide.bottomAnchor, constant: -12),

      bottomContent.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor),
      bottomContent.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor),
      bottomContent.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor),
      bottomContent.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor),

      bottomStack.leadingAnchor.constraint(equalTo: bottomContent.leadingAnchor, constant: 12),
      bottomStack.trailingAnchor.constraint(equalTo: bottomContent.trailingAnchor, constant: -12),
      bottomStack.topAnchor.constraint(equalTo: bottomContent.topAnchor, constant: 12),
      bottomStack.bottomAnchor.constraint(equalTo: bottomContent.bottomAnchor, constant: -12),

      currentTimeLabel.widthAnchor.constraint(equalToConstant: 44),
      durationLabel.widthAnchor.constraint(equalToConstant: 44),
      bufferedSlider.heightAnchor.constraint(equalToConstant: 28),

      unlockButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -18),
      unlockButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
      unlockButton.widthAnchor.constraint(equalToConstant: 56),
      unlockButton.heightAnchor.constraint(equalToConstant: 56),
    ])

    refreshTopBarLayout()
    refreshButtonTint()
    brightnessHud.setPercent(Int(currentGestureBrightnessLevel * 100))
    volumeHud.setPercent(Int(currentGestureVolumeLevel * 100))
    updateBrightnessPreview()
    updatePictureInPictureSourceLayout()
  }

  private func setupGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    doubleTap.numberOfTapsRequired = 2
    tap.require(toFail: doubleTap)

    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    pinch.delegate = self

    let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self

    addGestureRecognizer(tap)
    addGestureRecognizer(doubleTap)
    addGestureRecognizer(pinch)
    addGestureRecognizer(pan)
  }

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneWillDeactivate),
      name: UIScene.willDeactivateNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillTerminate),
      name: UIApplication.willTerminateNotification,
      object: nil
    )
  }

  private func cleanup() {
    guard !isCleaningUp else {
      return
    }

    isCleaningUp = true
    NotificationCenter.default.removeObserver(self)
    hideControlsWorkItem?.cancel()
    gestureHudHideWorkItem?.cancel()
    overlayWorkItem?.cancel()
    clearSubtitleWorkItem?.cancel()
    pictureInPictureStartRetryWorkItem?.cancel()
    pendingAutoPictureInPicture = false
    isAttemptingPictureInPictureStart = false
    shouldPauseAfterPictureInPictureStarts = false
    isInPictureInPictureMode = false
    isPictureInPicturePossible = false
    if let playbackEndedObserver {
      NotificationCenter.default.removeObserver(playbackEndedObserver)
      self.playbackEndedObserver = nil
    }
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
      timeObserverToken = nil
    }
    pictureInPictureController?.delegate = nil
    if pictureInPictureController?.isPictureInPictureActive == true {
      pictureInPictureController?.stopPictureInPicture()
    }
    pictureInPicturePossibleObservation = nil
    pictureInPictureController = nil
    savePlaybackState(force: true)
    player.pause()
    player.replaceCurrentItem(with: nil)
    playerSurfaceView.playerLayer.player = nil
    pictureInPictureSourceView.playerLayer.player = nil
    itemStatusObservation = nil
    itemPresentationSizeObservation = nil
    itemLoadedRangesObservation = nil
    itemLikelyToKeepUpObservation = nil
    itemBufferEmptyObservation = nil
    playerStatusObservation = nil
    timeControlStatusObservation = nil
    currentResourceLoader = nil
    restoreOriginalOrientationIfNeeded()
    forcePhonePortrait(from: topViewController())
  }

  private func configureButton(_ button: UIButton, symbol: String, pointSize: CGFloat = 18) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = buttonTintColor
    button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)), for: .normal)
    button.widthAnchor.constraint(equalToConstant: 42).isActive = true
    button.heightAnchor.constraint(equalToConstant: 42).isActive = true
  }

  private func configureTopToolStyle(_ button: UIButton, active: Bool = false) {
    button.layer.cornerRadius = isVideoVertical ? 12 : 14
    button.layer.borderWidth = 1
    button.layer.borderColor = (active ? UIColor.systemGreen.withAlphaComponent(0.55) : UIColor.white.withAlphaComponent(0.16)).cgColor
    button.backgroundColor = active ? UIColor(red: 0.06, green: 0.12, blue: 0.08, alpha: 0.45) : UIColor.black.withAlphaComponent(0.16)
    button.clipsToBounds = true
  }

  private func toolButtons(includeSubtitle: Bool = true) -> [UIButton] {
    var buttons: [UIButton] = [lockButton, loopButton, shuffleButton, backgroundPlayButton]
    if includeSubtitle, enableSubtitle {
      buttons.append(subtitleButton)
    }
    buttons.append(contentsOf: [settingsButton, screenshotButton, speedButton])
    return buttons
  }

  private func resetArrangedSubviews(of stackView: UIStackView) {
    stackView.arrangedSubviews.forEach { view in
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func refreshTopBarLayout() {
    resetArrangedSubviews(of: topRootStack)
    resetArrangedSubviews(of: leftHeaderStack)
    resetArrangedSubviews(of: rightToolsStack)
    resetArrangedSubviews(of: topToolRowOne)
    resetArrangedSubviews(of: topToolRowTwo)

    leftHeaderStack.axis = isVideoVertical ? .vertical : .horizontal
    leftHeaderStack.alignment = isVideoVertical ? .leading : .center
    leftHeaderStack.spacing = isVideoVertical ? 14 : 10

    titleLabel.font = UIFont.systemFont(ofSize: isVideoVertical ? 12 : 14, weight: .semibold)
    titleLabel.numberOfLines = isVideoVertical ? 2 : 1

    leftHeaderStack.addArrangedSubview(backButton)
    leftHeaderStack.addArrangedSubview(titleLabel)

    if isVideoVertical {
      rightToolsStack.axis = .vertical
      rightToolsStack.alignment = .trailing
      rightToolsStack.spacing = 18

      [lockButton, loopButton, shuffleButton].forEach { topToolRowOne.addArrangedSubview($0) }
      [backgroundPlayButton, subtitleButton, settingsButton, screenshotButton, speedButton]
        .filter { !($0 === subtitleButton && !enableSubtitle) }
        .forEach { topToolRowTwo.addArrangedSubview($0) }

      [topToolRowOne, topToolRowTwo].forEach { row in
        row.spacing = 14
      }

      rightToolsStack.addArrangedSubview(topToolRowOne)
      rightToolsStack.addArrangedSubview(topToolRowTwo)
      topRootStack.alignment = .top
    } else {
      rightToolsStack.axis = .horizontal
      rightToolsStack.alignment = .center
      rightToolsStack.spacing = 8
      toolButtons().forEach { rightToolsStack.addArrangedSubview($0) }
      topRootStack.alignment = .center
    }

    topRootStack.addArrangedSubview(leftHeaderStack)
    topRootStack.addArrangedSubview(topSpacerView)
    topRootStack.addArrangedSubview(rightToolsStack)
  }

  private func refreshButtonTint() {
    [
      backButton,
      subtitleButton,
      settingsButton,
      lockButton,
      loopButton,
      shuffleButton,
      backgroundPlayButton,
      screenshotButton,
      playButton,
      rewindButton,
      forwardButton,
      unlockButton,
    ].forEach {
      $0.tintColor = buttonTintColor
    }
    speedButton.tintColor = buttonTintColor
    speedButton.setTitleColor(buttonTintColor, for: .normal)

    [backButton, subtitleButton, settingsButton, lockButton, loopButton, shuffleButton, backgroundPlayButton, screenshotButton, speedButton].forEach {
      configureTopToolStyle($0)
    }

    if isLooping {
      loopButton.tintColor = .systemGreen
      configureTopToolStyle(loopButton, active: true)
    }
    if isShuffleEnabled {
      shuffleButton.tintColor = .systemGreen
      configureTopToolStyle(shuffleButton, active: true)
    }
    if backgroundPlayEnabled {
      backgroundPlayButton.tintColor = .systemGreen
      configureTopToolStyle(backgroundPlayButton, active: true)
    }
    if pictureInPictureEnabled, AVPictureInPictureController.isPictureInPictureSupported() {
      settingsButton.tintColor = .systemGreen
      configureTopToolStyle(settingsButton, active: true)
    }

    currentTimeLabel.textColor = durationColor
    durationLabel.textColor = durationColor
    updateSubtitleSelectionUI()
  }

  private func owningViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        return controller
      }
      responder = current.next
    }
    return nil
  }

  private func cancelPictureInPictureStartRetry() {
    pictureInPictureStartRetryWorkItem?.cancel()
    pictureInPictureStartRetryWorkItem = nil
  }

  private func updatePictureInPictureAvailability(_ isPossible: Bool) {
    isPictureInPicturePossible = isPossible

    guard isPossible,
          pendingAutoPictureInPicture,
          !isAttemptingPictureInPictureStart,
          !isCleaningUp,
          !isHandlingBackNavigation else {
      return
    }

    _ = startPictureInPictureIfPossible(automatic: true)
  }

  private func schedulePictureInPictureStartRetry(automatic: Bool, remainingAttempts: Int) {
    guard remainingAttempts > 0, !isCleaningUp, !isHandlingBackNavigation else {
      if shouldPauseAfterPictureInPictureStarts {
        shouldPauseAfterPictureInPictureStarts = false
        pausePlayback(userInitiated: false)
      }
      pendingAutoPictureInPicture = false
      return
    }

    cancelPictureInPictureStartRetry()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.pictureInPictureStartRetryWorkItem = nil
      _ = self.startPictureInPictureIfPossible(automatic: automatic, remainingAttempts: remainingAttempts)
    }

    pictureInPictureStartRetryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
  }

  private func preparePlaybackForPictureInPictureStartIfNeeded() {
    let wasPaused = player.timeControlStatus != .playing || paused
    guard wasPaused else {
      return
    }

    shouldPauseAfterPictureInPictureStarts = true
    let primingRate = currentPlaybackRate > 0 ? currentPlaybackRate : 1.0
    player.playImmediately(atRate: primingRate)
  }

  private func updateControlsAvailability() {
    controlsContainer.isHidden = !controls || controlsLocked
    topBar.isHidden = !controls
    bottomBar.isHidden = !controls
    centerControls.isHidden = !controls
    subtitleButton.isHidden = !controls || !enableSubtitle
    refreshTopBarLayout()
    updateSubtitleLayout()
  }

  private func configurePictureInPictureIfNeeded() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      updatePictureInPictureAvailability(false)
      return
    }

    configureAudioSession()

    if pictureInPictureController == nil {
      if let controller = AVPictureInPictureController(playerLayer: playerSurfaceView.playerLayer) {
        controller.delegate = self
        controller.requiresLinearPlayback = false
        pictureInPictureController = controller
        pictureInPicturePossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
          DispatchQueue.main.async {
            self?.updatePictureInPictureAvailability(controller.isPictureInPicturePossible)
          }
        }
      }
    }

    if #available(iOS 14.2, *) {
      pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = pictureInPictureEnabled
    }
  }

  private func updatePictureInPictureSourceLayout() {
    let presentationSize = currentVideoPresentationSize
    let hasPresentationSize = presentationSize.width > 0 && presentationSize.height > 0
    let aspectRatio = hasPresentationSize ? presentationSize.width / presentationSize.height : (16.0 / 9.0)
    let availableSize = bounds.size

    guard availableSize.width > 0, availableSize.height > 0 else {
      pictureInPictureSourceWidthConstraint?.constant = 1
      pictureInPictureSourceHeightConstraint?.constant = 1
      return
    }

    let fittedRect = AVMakeRect(
      aspectRatio: CGSize(width: max(aspectRatio, 0.1), height: 1),
      insideRect: CGRect(origin: .zero, size: availableSize)
    )

    pictureInPictureSourceWidthConstraint?.constant = max(1, fittedRect.width)
    pictureInPictureSourceHeightConstraint?.constant = max(1, fittedRect.height)
  }

  private func updateSubtitleLayout() {
    let safeRect = bounds.inset(by: safeAreaInsets)
    let hasPresentationSize = currentVideoPresentationSize.width > 0 && currentVideoPresentationSize.height > 0
    let videoRect =
      hasPresentationSize
        ? AVMakeRect(aspectRatio: currentVideoPresentationSize, insideRect: safeRect)
        : safeRect

    let bandWidth = min(videoRect.width, max(60, videoRect.width - 32))
    let bottomPadding: CGFloat = controls && controlsVisible && !controlsLocked ? 92 : 24
    let maxLabelHeight: CGFloat = 88

    subtitleLabel.transform = .identity
    subtitleLabel.preferredMaxLayoutWidth = max(
      0,
      bandWidth - subtitleLabel.contentInsets.left - subtitleLabel.contentInsets.right
    )

    let fittedSize = subtitleLabel.sizeThatFits(CGSize(width: bandWidth, height: maxLabelHeight))
    let labelHeight = min(maxLabelHeight, max(44, fittedSize.height))
    let targetY = max(videoRect.minY + 12, videoRect.maxY - bottomPadding - labelHeight)

    subtitleLabel.frame = CGRect(
      x: videoRect.midX - bandWidth * 0.5,
      y: targetY,
      width: bandWidth,
      height: labelHeight
    )
  }

  private func canStartPictureInPictureAutomatically() -> Bool {
    guard pictureInPictureEnabled, !isCleaningUp, !isHandlingBackNavigation else {
      return false
    }

    configurePictureInPictureIfNeeded()

    guard let controller = pictureInPictureController else {
      return false
    }

    if controller.isPictureInPictureActive || isInPictureInPictureMode {
      return true
    }

    guard currentMediaURI?.isEmpty == false,
          player.currentItem != nil,
          player.currentItem?.status == .readyToPlay,
          window != nil else {
      return false
    }

    return controller.isPictureInPicturePossible || isPictureInPicturePossible
  }

  @discardableResult
  private func startPictureInPictureIfPossible(automatic: Bool, remainingAttempts: Int = 8) -> Bool {
    guard pictureInPictureEnabled,
          !isCleaningUp,
          !isHandlingBackNavigation else {
      cancelPictureInPictureStartRetry()
      pendingAutoPictureInPicture = false
      return false
    }

    configurePictureInPictureIfNeeded()

    guard currentMediaURI?.isEmpty == false,
          player.currentItem != nil,
          player.currentItem?.status == .readyToPlay,
          window != nil,
          let controller = pictureInPictureController else {
      cancelPictureInPictureStartRetry()
      pendingAutoPictureInPicture = false
      return false
    }

    if controller.isPictureInPictureActive || isInPictureInPictureMode {
      cancelPictureInPictureStartRetry()
      isAttemptingPictureInPictureStart = false
      pendingAutoPictureInPicture = false
      return true
    }

    if isAttemptingPictureInPictureStart {
      pendingAutoPictureInPicture = pendingAutoPictureInPicture || automatic
      return false
    }

    preparePlaybackForPictureInPictureStartIfNeeded()

    if !(controller.isPictureInPicturePossible || isPictureInPicturePossible) {
      pendingAutoPictureInPicture = automatic
      schedulePictureInPictureStartRetry(automatic: automatic, remainingAttempts: remainingAttempts - 1)
      if !automatic, remainingAttempts <= 1 {
        showOverlay("PiP unavailable right now")
      }
      return false
    }

    cancelPictureInPictureStartRetry()
    configureAudioSession()
    isAttemptingPictureInPictureStart = true
    pendingAutoPictureInPicture = automatic
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      guard !self.isCleaningUp, !self.isHandlingBackNavigation else {
        self.isAttemptingPictureInPictureStart = false
        self.pendingAutoPictureInPicture = false
        return
      }
      controller.startPictureInPicture()
    }
    return true
  }

  private func resolvedPresentationSize(for item: AVPlayerItem) -> CGSize {
    let size = item.presentationSize
    if size.width > 0, size.height > 0 {
      return size
    }

    guard let track = item.asset.tracks(withMediaType: .video).first else {
      return .zero
    }

    return track.naturalSize.applying(track.preferredTransform)
  }

  private func updateVideoPresentation(for item: AVPlayerItem) {
    let resolvedSize = resolvedPresentationSize(for: item)
    let width = abs(resolvedSize.width)
    let height = abs(resolvedSize.height)
    guard width > 0, height > 0 else {
      return
    }

    let wasVertical = isVideoVertical
    currentVideoPresentationSize = CGSize(width: width, height: height)
    isVideoVertical = height > width
    if wasVertical != isVideoVertical {
      refreshTopBarLayout()
      refreshButtonTint()
      setNeedsLayout()
      layoutIfNeeded()
    }

    updatePictureInPictureSourceLayout()
    applyVideoOrientation(videoWidth: width, videoHeight: height)
  }

  private func applyVideoOrientation(videoWidth: CGFloat, videoHeight: CGFloat) {
    guard let controller = owningViewController() ?? topViewController() else {
      return
    }

    if originalOrientationMask == nil {
      originalOrientationMask = controller.supportedInterfaceOrientations
      if UIDevice.current.userInterfaceIdiom == .phone {
        originalInterfaceOrientation = .portrait
      } else {
        originalInterfaceOrientation = controller.view.window?.windowScene?.interfaceOrientation
      }
    }

    let targetMask: UIInterfaceOrientationMask = videoHeight > videoWidth ? .portrait : .landscape
    guard appliedOrientationMask != targetMask else {
      return
    }

    let preferredOrientation: UIInterfaceOrientation =
      targetMask == .portrait
        ? .portrait
        : (controller.view.window?.windowScene?.interfaceOrientation.isLandscape == true ? controller.view.window?.windowScene?.interfaceOrientation ?? .landscapeRight : .landscapeRight)

    lockOrientation(targetMask, rotateTo: preferredOrientation, from: controller)
    appliedOrientationMask = targetMask
  }

  private func preferredRestoreOrientation(for mask: UIInterfaceOrientationMask) -> UIInterfaceOrientation? {
    if UIDevice.current.userInterfaceIdiom == .phone, mask.contains(.portrait) {
      return .portrait
    }

    return originalInterfaceOrientation.flatMap { mask.contains($0) ? $0 : nil }
  }

  private func restoreOriginalOrientationIfNeeded(from controller: UIViewController? = nil) {
    guard let originalOrientationMask else {
      return
    }

    let targetController = controller ?? owningViewController() ?? topViewController()
    let preferredOrientation = preferredRestoreOrientation(for: originalOrientationMask) ?? .portrait

    lockOrientation(originalOrientationMask, rotateTo: preferredOrientation, from: targetController)
    if UIDevice.current.userInterfaceIdiom == .phone, originalOrientationMask.contains(.portrait) {
      forcePhonePortrait(from: targetController)
    }
    self.originalOrientationMask = nil
    originalInterfaceOrientation = nil
    appliedOrientationMask = nil
  }

  private func completeBackNavigation(restoringFrom controller: UIViewController?) {
    restoreOriginalOrientationIfNeeded(from: controller)

    forcePhonePortrait(from: controller)

    isHandlingBackNavigation = false
  }

  private func lockOrientation(_ mask: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientation, from controller: UIViewController?) {
    if #available(iOS 16.0, *) {
      let windowScene = (controller?.view.window?.windowScene ?? UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
      windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
      controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      UIDevice.current.setValue(rotateTo.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  private func forcePhonePortrait(from controller: UIViewController?) {
    lockOrientation(.portrait, rotateTo: .portrait, from: controller)
  }

  private func applySource() {
    let parsed = parseSourceEntries(from: source)
    let targetIndex = parsed.isEmpty ? 0 : max(0, min(index, parsed.count - 1))

    if parsed.map(\.stableKey) == queueEntries.map(\.stableKey),
      currentIndex == targetIndex,
      queueEntries.indices.contains(targetIndex),
      currentMediaURI == queueEntries[targetIndex].uri {
      updateDisplayedTitle()
      return
    }

    queueEntries = parsed
    shuffledIndexes.removeAll()
    shuffledPosition = -1

    guard !queueEntries.isEmpty else {
      currentIndex = 0
      currentMediaURI = nil
      currentVideoPresentationSize = .zero
      updateDisplayedTitle()
      updatePictureInPictureSourceLayout()
      restoreOriginalOrientationIfNeeded()
      return
    }

    currentIndex = targetIndex
    playCurrent()
  }

  private func applyIndex(_ value: Int) {
    guard !queueEntries.isEmpty else {
      currentIndex = max(0, value)
      return
    }

    let resolvedIndex = max(0, min(value, queueEntries.count - 1))
    if resolvedIndex == currentIndex,
      queueEntries.indices.contains(resolvedIndex),
      currentMediaURI == queueEntries[resolvedIndex].uri {
      return
    }

    currentIndex = resolvedIndex
    if isShuffleEnabled {
      rebuildShuffleOrder(currentIndex: currentIndex)
    }
    playCurrent()
  }

  private func parseSourceEntries(from source: Any?) -> [IOSVideoSourceEntry] {
    guard let source else {
      return []
    }

    if let array = source as? [Any] {
      return array.compactMap { parseSourceEntry(from: $0) }
    }

    if let entry = parseSourceEntry(from: source) {
      return [entry]
    }

    return []
  }

  private func parseSourceEntry(from source: Any) -> IOSVideoSourceEntry? {
    if let value = source as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return IOSVideoSourceEntry(uri: value, title: nil)
    }

    if let map = source as? [String: Any],
       let uri = map["uri"] as? String,
       !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return IOSVideoSourceEntry(
        uri: uri,
        title: (map["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return nil
  }

  private func playCurrent() {
    guard currentIndex >= 0, currentIndex < queueEntries.count else {
      return
    }

    loadMedia(queueEntries[currentIndex], index: currentIndex)
  }

  private func loadMedia(_ entry: IOSVideoSourceEntry, index: Int) {
    guard let resolvedURL = resolveURL(from: entry.uri) else {
      showOverlay("Invalid video URL")
      return
    }

    let isReloadingCurrentMedia = currentMediaURI == entry.uri
    let preservedSubtitleURL = isReloadingCurrentMedia ? customSubtitleURL : nil
    let preservedSubtitleCues = isReloadingCurrentMedia ? customSubtitleCues : []
    let preservedSubtitleEnabled = subtitleEnabled

    currentIndex = index
    currentMediaURI = entry.uri
    currentRemoteURL = VideoStreamCache.isRemoteURL(resolvedURL) ? resolvedURL : nil
    currentSourceIsRemote = currentRemoteURL != nil
    currentResourceLoader = nil
    currentPlaybackRate = 1.0
    speedButton.setTitle("1x", for: .normal)
    subtitleEnabled = true
    currentEmbeddedSubtitleOption = nil
    customSubtitleCues = preservedSubtitleCues
    customSubtitleURL = preservedSubtitleURL
    subtitleEnabled = preservedSubtitleURL != nil ? preservedSubtitleEnabled : true
    subtitleLabel.isHidden = true
    currentSubtitleText = ""
    lastDuration = 0
    currentVideoPresentationSize = .zero
    bufferedSlider.value = 0
    bufferedSlider.bufferValue = 0
    currentTimeLabel.text = "00:00"
    durationLabel.text = "00:00"
    updateDisplayedTitle()
    resetZoom(showLabel: false)
    updatePictureInPictureSourceLayout()

    let asset: AVAsset
    if let remoteURL = currentRemoteURL {
      let prepared = VideoStreamCache.shared.prepareAsset(for: remoteURL)
      asset = prepared.asset
      currentResourceLoader = prepared.loader
    } else {
      asset = AVURLAsset(url: resolvedURL)
    }

    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 60
    item.audioTimePitchAlgorithm = .timeDomain
    if #available(iOS 15.0, *) {
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    observePlayerItem(item)
    player.replaceCurrentItem(with: item)
    player.rate = currentPlaybackRate
    if !paused {
      playPlayback(userInitiated: false)
    }

    pendingResumePosition = loadSavedPosition(for: entry.uri)
    if preservedSubtitleURL == nil {
      autoLoadSidecarSubtitlesIfNeeded(for: resolvedURL)
    }
    updateSubtitleSelectionUI()
    dispatchProgressEvent(force: true)
  }

  private func resolveURL(from uri: String) -> URL? {
    if let url = URL(string: uri), url.scheme != nil {
      return url
    }

    let expanded = (uri as NSString).expandingTildeInPath
    let fileURL = URL(fileURLWithPath: expanded)
    return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : URL(string: uri)
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    if let playbackEndedObserver {
      NotificationCenter.default.removeObserver(playbackEndedObserver)
      self.playbackEndedObserver = nil
    }

    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        self?.handlePlayerItemStatus(item.status)
      }
    }

    itemPresentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        self?.updateVideoPresentation(for: item)
      }
    }

    itemLoadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateBufferedUI()
        self?.dispatchProgressEvent(force: true)
      }
    }

    itemLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateBufferingUI()
      }
    }

    itemBufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateBufferingUI()
      }
    }

    let legibleOutput = AVPlayerItemLegibleOutput()
    legibleOutput.setDelegate(self, queue: DispatchQueue.main)
    legibleOutput.suppressesPlayerRendering = true
    item.add(legibleOutput)

    playbackEndedObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.handlePlaybackEnded()
    }
  }

  private func handlePlayerItemStatus(_ status: AVPlayerItem.Status) {
    switch status {
    case .readyToPlay:
      lastDuration = durationSeconds(for: player.currentItem?.duration)
      durationLabel.text = format(seconds: lastDuration)
      if let item = player.currentItem {
        updateVideoPresentation(for: item)
      }
      updateEmbeddedSubtitleGroup()
      if let resume = pendingResumePosition, resume > 0, lastDuration > 0, resume < lastDuration - 1 {
        player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        showOverlay("Resumed playback")
      }
      pendingResumePosition = nil
      onLoad?(["duration": lastDuration * 1000, "uri": currentMediaURI ?? NSNull(), "index": currentIndex])
      dispatchProgressEvent(force: true)
    case .failed:
      showOverlay("Playback failed")
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  private func handlePlaybackEnded() {
    clearSavedPosition(for: currentMediaURI)

    if isLooping {
      player.seek(to: .zero)
      playPlayback(userInitiated: false)
      return
    }

    if let nextIndex = nextPlaybackIndex() {
      currentIndex = nextIndex
      playCurrent()
      return
    }

    onVideoEnd?([:])
  }

  private func nextPlaybackIndex() -> Int? {
    guard !queueEntries.isEmpty else {
      return nil
    }

    if isShuffleEnabled {
      if shuffledIndexes.isEmpty {
        rebuildShuffleOrder(currentIndex: currentIndex)
      }
      let next = shuffledPosition + 1
      guard next >= 0, next < shuffledIndexes.count else {
        return nil
      }
      shuffledPosition = next
      return shuffledIndexes[next]
    }

    let next = currentIndex + 1
    return next < queueEntries.count ? next : nil
  }

  private func previousPlaybackIndex() -> Int? {
    guard !queueEntries.isEmpty else {
      return nil
    }

    if isShuffleEnabled {
      let previous = shuffledPosition - 1
      guard previous >= 0, previous < shuffledIndexes.count else {
        return nil
      }
      shuffledPosition = previous
      return shuffledIndexes[previous]
    }

    let previous = currentIndex - 1
    return previous >= 0 ? previous : nil
  }

  private func rebuildShuffleOrder(currentIndex: Int) {
    shuffledIndexes = Array(queueEntries.indices).shuffled()
    if let currentPosition = shuffledIndexes.firstIndex(of: currentIndex) {
      shuffledIndexes.swapAt(0, currentPosition)
    }
    shuffledPosition = 0
  }

  private func updateDisplayedTitle() {
    let resolvedTitle: String
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      resolvedTitle = title
    } else if currentIndex >= 0, currentIndex < queueEntries.count,
              let entryTitle = queueEntries[currentIndex].title,
              !entryTitle.isEmpty {
      resolvedTitle = entryTitle
    } else if let currentMediaURI, let url = resolveURL(from: currentMediaURI) {
      resolvedTitle = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    } else {
      resolvedTitle = "Now Playing"
    }

    titleLabel.text = resolvedTitle
  }

  private func handlePeriodicTimeUpdate() {
    updateCurrentTimeUI()
    updateBufferedUI()
    updateCustomSubtitle()
    clearEmbeddedSubtitleIfStale()
    savePlaybackState(force: false)
    dispatchProgressEvent(force: false)
  }

  private func updateCurrentTimeUI() {
    let seconds = durationSeconds(for: player.currentTime())
    currentTimeLabel.text = format(seconds: seconds)
    if lastDuration > 0, !bufferedSlider.isInteracting {
      bufferedSlider.value = CGFloat(min(1, max(0, seconds / lastDuration)))
    }
  }

  private func updateBufferedUI() {
    guard lastDuration > 0 else {
      bufferedSlider.bufferValue = 0
      return
    }

    let bufferedTime = max(loadedTimeRangeEnd(), currentCacheBufferedTimeEstimate())
    bufferedSlider.bufferValue = CGFloat(min(1, max(0, bufferedTime / lastDuration)))
  }

  private func updateBufferingUI() {
    let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.currentItem?.isPlaybackBufferEmpty == true
    buffering ? loader.startAnimating() : loader.stopAnimating()
  }

  private func currentCacheBufferedTimeEstimate() -> Double {
    guard currentSourceIsRemote, lastDuration > 0 else {
      return 0
    }

    let stats = currentCacheStats()
    guard stats.contentLength > 0 else {
      return 0
    }
    return (Double(stats.cachedBytes) / Double(stats.contentLength)) * lastDuration
  }

  private func loadedTimeRangeEnd() -> Double {
    guard let item = player.currentItem else {
      return 0
    }

    return item.loadedTimeRanges
      .map(\.timeRangeValue)
      .map { durationSeconds(for: $0.start) + durationSeconds(for: $0.duration) }
      .max() ?? 0
  }

  private func durationSeconds(for time: CMTime?) -> Double {
    guard let time else {
      return 0
    }

    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, !seconds.isNaN else {
      return 0
    }
    return max(0, seconds)
  }

  private func dispatchProgressEvent(force: Bool) {
    guard let onProgress else {
      return
    }

    let now = CACurrentMediaTime()
    if !force, now - lastProgressEventTimestamp < 0.5 {
      return
    }

    lastProgressEventTimestamp = now

    let currentTime = durationSeconds(for: player.currentTime())
    let duration = max(lastDuration, durationSeconds(for: player.currentItem?.duration))
    let bufferedPosition = max(loadedTimeRangeEnd(), currentCacheBufferedTimeEstimate())
    let bufferedPercent = duration > 0 ? Int((bufferedPosition * 100) / duration) : 0
    let cacheStats = currentCacheStats()

    onProgress([
      "currentTime": currentTime * 1000,
      "duration": duration * 1000,
      "bufferedPosition": bufferedPosition * 1000,
      "bufferedDuration": max(0, bufferedPosition - currentTime) * 1000,
      "bufferedPercent": max(0, min(100, bufferedPercent)),
      "cachedBytes": Double(cacheStats.cachedBytes),
      "cacheContentLength": Double(cacheStats.contentLength),
      "cachePercent": cacheStats.cachedPercent,
      "isPlaying": player.timeControlStatus == .playing,
      "isBuffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "isRemote": currentSourceIsRemote,
      "uri": currentMediaURI ?? NSNull(),
      "index": currentIndex,
    ])
  }

  private func currentCacheStats() -> VideoCacheStats {
    if let loader = currentResourceLoader {
      return loader.cacheStats
    }

    if let remoteURL = currentRemoteURL {
      return VideoStreamCache.shared.cacheStats(for: remoteURL)
    }

    return .empty
  }

  private func savePlaybackState(force: Bool) {
    guard resumePlaybackEnabled, let uri = currentMediaURI, !uri.isEmpty else {
      return
    }

    let currentPosition = durationSeconds(for: player.currentTime())
    if !force, abs(currentPosition - lastPersistedPosition) < 1 {
      return
    }

    lastPersistedPosition = currentPosition
    UserDefaults.standard.set(currentPosition, forKey: resumeKey(for: uri))
  }

  private func loadSavedPosition(for uri: String) -> Double? {
    guard resumePlaybackEnabled else {
      return nil
    }

    let value = UserDefaults.standard.double(forKey: resumeKey(for: uri))
    return value > 0 ? value : nil
  }

  private func clearSavedPosition(for uri: String?) {
    guard let uri else {
      return
    }

    UserDefaults.standard.removeObject(forKey: resumeKey(for: uri))
  }

  private func resumeKey(for uri: String) -> String {
    "ios_resume_\(VideoStreamCache.stableKey(for: uri))"
  }

  private func playPlayback(userInitiated: Bool) {
    configureAudioSession()
    player.playImmediately(atRate: currentPlaybackRate)
    playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    if userInitiated {
      showControls()
    }
  }

  private func pausePlayback(userInitiated: Bool) {
    player.pause()
    playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    if userInitiated {
      showControls()
    }
  }

  private func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Ignore audio session setup failures and continue playback inline.
    }
  }

  private func autoLoadSidecarSubtitlesIfNeeded(for videoURL: URL) {
    guard videoURL.isFileURL else {
      return
    }

    let baseName = videoURL.deletingPathExtension().lastPathComponent
    let directory = videoURL.deletingLastPathComponent()
    let candidates = ["srt", "vtt"]
      .map { directory.appendingPathComponent(baseName).appendingPathExtension($0) }

    if let subtitleURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      loadCustomSubtitles(from: subtitleURL, announce: false)
    }
  }

  private func updateEmbeddedSubtitleGroup() {
    guard let item = player.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
      currentEmbeddedSubtitleGroup = nil
      return
    }

    currentEmbeddedSubtitleGroup = group
    if subtitleEnabled, currentEmbeddedSubtitleOption == nil {
      currentEmbeddedSubtitleOption = group.options.first
      if let option = currentEmbeddedSubtitleOption {
        item.select(option, in: group)
      }
    }
  }

  private func updateSubtitleSelectionUI() {
    let active = subtitleEnabled && (!customSubtitleCues.isEmpty || currentEmbeddedSubtitleOption != nil)
    subtitleButton.tintColor = active ? UIColor.systemGreen : buttonTintColor
    configureTopToolStyle(subtitleButton, active: active)
  }

  fileprivate func loadCustomSubtitles(from url: URL, announce: Bool) {
    do {
      let parsedCues = try SubtitleParser.parse(url: url)
      guard !parsedCues.isEmpty else {
        showOverlay("Subtitle load failed")
        return
      }

      customSubtitleCues = parsedCues
      customSubtitleURL = url
      subtitleEnabled = true
      currentEmbeddedSubtitleOption = nil
      if let group = currentEmbeddedSubtitleGroup {
        player.currentItem?.select(nil, in: group)
      }
      updateCustomSubtitle()
      subtitleLabel.layer.zPosition = 200
      bringSubviewToFront(subtitleLabel)
      updateSubtitleSelectionUI()
      if announce {
        showOverlay("Subtitle loaded")
      }
    } catch {
      showOverlay("Subtitle load failed")
    }
  }

  private func buildSubtitleSearchQuery() -> String {
    guard let currentMediaURI, !currentMediaURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ""
    }

    let fallbackName = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName: String
    if let url = resolveURL(from: currentMediaURI) {
      let lastSegment = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
      if lastSegment.allSatisfy(\.isNumber), let fallbackName, !fallbackName.isEmpty {
        resolvedName = fallbackName
      } else {
        resolvedName = lastSegment
      }
    } else {
      resolvedName = currentMediaURI
    }

    let dotIndex = resolvedName.lastIndex(of: ".")
    let baseName = dotIndex.map { String(resolvedName[..<$0]) } ?? resolvedName
    return baseName
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func showSubtitleURLPrompt() {
    let controller = UIAlertController(title: "Subtitle URL", message: nil, preferredStyle: .alert)
    controller.addTextField { textField in
      textField.placeholder = "https://example.com/subtitles.srt"
      textField.keyboardType = .URL
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
      textField.textContentType = .URL
    }
    controller.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    controller.addAction(UIAlertAction(title: "Load", style: .default) { [weak self, weak controller] _ in
      let value = controller?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self?.beginRemoteSubtitleImport(from: value, suggestedFileName: nil, useSubtitleUserAgent: false)
    })
    topViewController()?.present(controller, animated: true)
  }

  private func showOnlineSubtitleSearch() {
    let controller = SubtitleSearchViewController(
      playerView: self,
      initialQuery: buildSubtitleSearchQuery()
    )
    controller.modalPresentationStyle = .overFullScreen
    controller.modalTransitionStyle = .crossDissolve
    topViewController()?.present(controller, animated: true)
  }

  private func beginRemoteSubtitleImport(from value: String, suggestedFileName: String?, useSubtitleUserAgent: Bool) {
    guard !value.isEmpty, let remoteURL = URL(string: value), remoteURL.scheme != nil else {
      showOverlay("Invalid subtitle URL")
      return
    }

    showOverlay("Loading subtitle", autoHide: 1.4)

    Task { [weak self] in
      guard let self else { return }
      do {
        let localURL = try await self.downloadRemoteSubtitle(
          from: remoteURL,
          suggestedFileName: suggestedFileName,
          useSubtitleUserAgent: useSubtitleUserAgent
        )
        DispatchQueue.main.async {
          self.loadCustomSubtitles(from: localURL, announce: true)
        }
      } catch {
        DispatchQueue.main.async {
          self.showOverlay("Subtitle load failed")
        }
      }
    }
  }

  private func subtitlesImportDirectory() throws -> URL {
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let directory = root.appendingPathComponent("downloaded-subtitles", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    return directory
  }

  private func downloadRemoteSubtitle(
    from remoteURL: URL,
    suggestedFileName: String?,
    useSubtitleUserAgent: Bool
  ) async throws -> URL {
    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 20
    request.setValue("text/plain,text/vtt,application/zip,application/octet-stream,*/*", forHTTPHeaderField: "Accept")
    if useSubtitleUserAgent {
      request.setValue(Self.subtitleUserAgent, forHTTPHeaderField: "User-Agent")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    let trimmedSuggestedName = suggestedFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = (trimmedSuggestedName?.isEmpty == false ? trimmedSuggestedName : response.suggestedFilename)
      ?? remoteURL.lastPathComponent
    let mimeType = response.mimeType?.lowercased()
    let directory = try subtitlesImportDirectory()
    let stableKey = VideoStreamCache.stableKey(for: remoteURL.absoluteString)

    if (mimeType?.contains("zip") == true) || fileName.lowercased().hasSuffix(".zip") || remoteURL.pathExtension.lowercased() == "zip" {
      let archiveURL = directory.appendingPathComponent("\(stableKey).zip")
      try? FileManager.default.removeItem(at: archiveURL)
      try data.write(to: archiveURL, options: .atomic)
      return try SimpleZipExtractor.extractFirstSubtitle(
        from: archiveURL,
        into: directory,
        preferredBaseName: sanitizedSubtitleBaseName(from: fileName),
        keyPrefix: stableKey
      )
    }

    let subtitleExtension = subtitleFileExtension(for: fileName, mimeType: mimeType)
    let targetURL = directory.appendingPathComponent("\(stableKey)-\(sanitizedSubtitleBaseName(from: fileName)).\(subtitleExtension)")
    try? FileManager.default.removeItem(at: targetURL)
    try data.write(to: targetURL, options: .atomic)
    return targetURL
  }

  fileprivate func searchSubtitles(query: String) async -> [SubtitleSearchResult] {
    do {
      let matches = try await searchSubdlMatches(query)
      var results: [SubtitleSearchResult] = []
      var seenURLs = Set<String>()

      for match in matches where match.subtitlesCount > 0 {
        let detailResults = try await fetchSubdlSubtitleResults(match)
        for result in detailResults where seenURLs.insert(result.downloadURL).inserted {
          results.append(result)
          if results.count >= 50 {
            return results
          }
        }
      }

      return results
    } catch {
      return []
    }
  }

  fileprivate func downloadSubtitleFile(_ result: SubtitleSearchResult) async -> URL? {
    guard let remoteURL = URL(string: result.downloadURL) else {
      return nil
    }

    return try? await downloadRemoteSubtitle(
      from: remoteURL,
      suggestedFileName: result.fileName,
      useSubtitleUserAgent: true
    )
  }

  private func sanitizedSubtitleBaseName(from fileName: String?) -> String {
    let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "subtitle"
    let decoded = fileName.removingPercentEncoding ?? fileName
    let rawBaseName = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
    let sanitized = rawBaseName
      .replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "_", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "subtitle" : sanitized
  }

  private func subtitleFileExtension(for fileName: String, mimeType: String?) -> String {
    let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    if pathExtension == "srt" || pathExtension == "vtt" {
      return pathExtension
    }
    if mimeType?.contains("vtt") == true {
      return "vtt"
    }
    return "srt"
  }

  fileprivate func searchSubdlMatches(_ query: String) async throws -> [SubtitleMediaMatch] {
    guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "\(Self.subdlBaseURL)/search/\(encodedQuery)"),
          let payload = try await fetchSubdlPageProps(url: url),
          let list = payload["list"] as? [[String: Any]] else {
      return []
    }

    return list.compactMap { item in
      guard let sdId = item["sd_id"] as? String,
            let slug = item["slug"] as? String,
            let title = item["name"] as? String else {
        return nil
      }

      return SubtitleMediaMatch(
        sdId: sdId,
        slug: slug,
        title: title,
        subtitlesCount: item["subtitles_count"] as? Int ?? 0
      )
    }
  }

  fileprivate func fetchSubdlSubtitleResults(_ match: SubtitleMediaMatch) async throws -> [SubtitleSearchResult] {
    guard let url = URL(string: "\(Self.subdlBaseURL)/subtitle/\(match.sdId)/\(match.slug)"),
          let payload = try await fetchSubdlPageProps(url: url),
          let subtitles = payload["subtitles"] as? [String: Any] else {
      return []
    }

    var results: [SubtitleSearchResult] = []
    for (languageKey, qualityValue) in subtitles {
      guard let qualities = qualityValue as? [String: Any] else {
        continue
      }

      for qualityGroup in qualities.values {
        guard let qualityGroup = qualityGroup as? [String: Any],
              let subs = qualityGroup["subs"] as? [[String: Any]] else {
          continue
        }

        for subtitle in subs {
          guard let link = subtitle["link"] as? String, !link.isEmpty else {
            continue
          }

          let releaseName = (subtitle["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
          let resolvedReleaseName = (releaseName?.isEmpty == false ? releaseName : nil) ?? match.title
          let languageValue = (subtitle["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
          let language = (languageValue?.isEmpty == false ? languageValue : nil)
            ?? languageKey.replacingOccurrences(of: "-", with: " ")
          let downloadURL = link.hasPrefix("http") ? link : "https://dl.subdl.com/subtitle/\(link)"
          let fileName = "\(sanitizedSubtitleBaseName(from: resolvedReleaseName)).zip"

          results.append(
            SubtitleSearchResult(
              mediaTitle: match.title,
              releaseName: resolvedReleaseName,
              language: language,
              fileName: fileName,
              downloadURL: downloadURL
            )
          )
        }
      }
    }

    return results
  }

  private func fetchSubdlPageProps(url: URL) async throws -> [String: Any]? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(Self.subtitleUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

    let (data, _) = try await URLSession.shared.data(for: request)
    guard let html = String(data: data, encoding: .utf8) else {
      return nil
    }

    let regex = try NSRegularExpression(
      pattern: #"<script id="__NEXT_DATA__" type="application/json">(.*?)</script>"#,
      options: [.dotMatchesLineSeparators]
    )
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    guard let match = regex.firstMatch(in: html, options: [], range: range),
          let jsonRange = Range(match.range(at: 1), in: html) else {
      return nil
    }

    let jsonString = String(html[jsonRange])
    guard let json = try JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any],
          let props = json["props"] as? [String: Any],
          let pageProps = props["pageProps"] as? [String: Any] else {
      return nil
    }

    return pageProps
  }

  private func updateCustomSubtitle() {
    guard subtitleEnabled else {
      subtitleLabel.isHidden = true
      currentSubtitleText = ""
      return
    }

    guard !customSubtitleCues.isEmpty else {
      return
    }

    let time = durationSeconds(for: player.currentTime())
    let cue = customSubtitleCues.first { time >= $0.start && time <= $0.end }
    let text = cue?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    subtitleLabel.text = text
    subtitleLabel.isHidden = text.isEmpty
    currentSubtitleText = text
  }

  private func clearEmbeddedSubtitleIfStale() {
    guard customSubtitleCues.isEmpty else {
      return
    }

    if CACurrentMediaTime() - lastEmbeddedSubtitleTimestamp > 0.9 {
      subtitleLabel.text = nil
      subtitleLabel.isHidden = true
      currentSubtitleText = ""
    }
  }

  func legibleOutput(
    _ output: AVPlayerItemLegibleOutput,
    didOutputAttributedStrings strings: [NSAttributedString],
    nativeSampleBuffers: [Any],
    forItemTime itemTime: CMTime
  ) {
    guard subtitleEnabled, customSubtitleCues.isEmpty else {
      return
    }

    let text = strings.map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    subtitleLabel.text = text
    subtitleLabel.isHidden = text.isEmpty
    currentSubtitleText = text
    lastEmbeddedSubtitleTimestamp = CACurrentMediaTime()
  }

  private func showControls() {
    guard controls, !controlsLocked else {
      return
    }

    hideControlsWorkItem?.cancel()
    controlsVisible = true
    controlsContainer.alpha = 1
    controlsContainer.isHidden = false
    updateSubtitleLayout()
    scheduleControlsHide()
  }

  private func hideControls() {
    guard !controlsLocked else {
      return
    }

    controlsVisible = false
    UIView.animate(withDuration: 0.2) {
      self.controlsContainer.alpha = 0
    } completion: { _ in
      self.controlsContainer.isHidden = true
      self.updateSubtitleLayout()
    }
  }

  private func scheduleControlsHide() {
    hideControlsWorkItem?.cancel()
    guard player.timeControlStatus == .playing, !isInPictureInPictureMode else {
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      self?.hideControls()
    }
    hideControlsWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + controlsAutoHideDelay, execute: workItem)
  }

  private func showOverlay(_ text: String, autoHide: TimeInterval = 1.0) {
    overlayWorkItem?.cancel()
    overlayLabel.text = text
    overlayLabel.alpha = 1
    overlayLabel.isHidden = false
    let workItem = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.2, animations: {
        self?.overlayLabel.alpha = 0
      }, completion: { _ in
        self?.overlayLabel.isHidden = true
      })
    }
    overlayWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: workItem)
  }

  private func updateBrightnessPreview() {
    let clampedBrightness = min(1, max(0.05, currentGestureBrightnessLevel))
#if targetEnvironment(simulator)
    let maxDimAlpha: CGFloat = 0.55
#else
    let maxDimAlpha: CGFloat = 0.18
#endif
    brightnessPreviewView.alpha = (1 - clampedBrightness) * maxDimAlpha
  }

  private func showGestureHud(_ hud: GestureHudView, percent: Int) {
    gestureHudHideWorkItem?.cancel()
    hud.setPercent(percent)

    let otherHud = hud === brightnessHud ? volumeHud : brightnessHud
    otherHud.isHidden = true
    otherHud.alpha = 0

    if hud.isHidden {
      hud.alpha = 0
      hud.isHidden = false
      UIView.animate(withDuration: 0.14) {
        hud.alpha = 1
      }
    } else {
      hud.alpha = 1
    }

    bringSubviewToFront(brightnessHud)
    bringSubviewToFront(volumeHud)
  }

  private func scheduleGestureHudHide() {
    gestureHudHideWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.hideGestureHud()
    }
    gestureHudHideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: workItem)
  }

  private func hideGestureHud() {
    gestureHudHideWorkItem?.cancel()
    [brightnessHud, volumeHud].forEach { hud in
      guard !hud.isHidden || hud.alpha > 0 else {
        return
      }

      UIView.animate(withDuration: 0.18, animations: {
        hud.alpha = 0
      }, completion: { _ in
        hud.isHidden = true
      })
    }
  }

  private func systemVolumeSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider {
      return slider
    }

    for subview in view.subviews {
      if let slider = systemVolumeSlider(in: subview) {
        return slider
      }
    }

    return nil
  }

  private func currentSystemVolumeLevel() -> Float {
    if let slider = systemVolumeSlider(in: hiddenVolumeView) {
      return slider.value
    }
#if targetEnvironment(simulator)
    return currentGestureVolumeLevel
#else
    return AVAudioSession.sharedInstance().outputVolume
#endif
  }

  private func applyGestureBrightness(_ brightness: CGFloat) {
    let clampedBrightness = min(1, max(0.05, brightness))
    currentGestureBrightnessLevel = clampedBrightness
    UIScreen.main.brightness = clampedBrightness
    updateBrightnessPreview()
    showGestureHud(brightnessHud, percent: Int(clampedBrightness * 100))
  }

  private func applyGestureVolume(_ volume: Float) {
    let clampedVolume = min(1, max(0, volume))
    currentGestureVolumeLevel = clampedVolume
    setSystemVolume(clampedVolume)
    showGestureHud(volumeHud, percent: Int(clampedVolume * 100))
  }

  private func updateZoomLabel() {
    zoomLabel.text = "\(Int(videoScale * 100))%"
    zoomLabel.alpha = 1
    zoomLabel.isHidden = false
    UIView.animate(withDuration: 0.2, delay: 0.8, options: [.curveEaseOut]) {
      self.zoomLabel.alpha = 0
    } completion: { _ in
      self.zoomLabel.isHidden = true
    }
  }

  private func applyVideoTransform() {
    var transform = CGAffineTransform.identity
    transform = transform.translatedBy(x: videoTranslation.x, y: videoTranslation.y)
    transform = transform.scaledBy(x: videoScale, y: videoScale)
    playerSurfaceView.transform = transform
  }

  private func resetZoom(showLabel: Bool) {
    videoScale = 1
    videoTranslation = .zero
    UIView.animate(withDuration: 0.2) {
      self.applyVideoTransform()
    }
    if showLabel {
      updateZoomLabel()
    }
  }

  private func clampTranslation() {
    let maxX = max(0, bounds.width * (videoScale - 1) * 0.5)
    let maxY = max(0, bounds.height * (videoScale - 1) * 0.5)
    videoTranslation.x = min(max(videoTranslation.x, -maxX), maxX)
    videoTranslation.y = min(max(videoTranslation.y, -maxY), maxY)
  }

  private func setSystemVolume(_ value: Float) {
    let clampedValue = min(1, max(0, value))
    if let slider = systemVolumeSlider(in: hiddenVolumeView) {
      slider.value = clampedValue
      slider.sendActions(for: .valueChanged)
    }

#if targetEnvironment(simulator)
    player.volume = clampedValue
    player.isMuted = clampedValue <= 0.001
#endif
  }

  @objc private func backTapped() {
    guard !isHandlingBackNavigation, !isCleaningUp else {
      return
    }

    isHandlingBackNavigation = true
    pendingAutoPictureInPicture = false
    cancelPictureInPictureStartRetry()

    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      guard let controller = self.owningViewController() ?? self.topViewController() else {
        self.completeBackNavigation(restoringFrom: nil)
        self.onBack?([:])
        return
      }

      if let navigationController = controller.navigationController, navigationController.viewControllers.count > 1 {
        let destinationController = navigationController.viewControllers.dropLast().last
        navigationController.popViewController(animated: true)
        if let transitionCoordinator = navigationController.transitionCoordinator {
          transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.completeBackNavigation(restoringFrom: destinationController)
          }
        } else {
          self.completeBackNavigation(restoringFrom: destinationController)
        }
      } else if controller.presentingViewController != nil {
        let presentingController = controller.presentingViewController
        controller.dismiss(animated: true) { [weak self] in
          self?.completeBackNavigation(restoringFrom: presentingController)
        }
      } else {
        self.completeBackNavigation(restoringFrom: controller)
        self.onBack?([:])
      }
    }
  }

  @objc private func playPauseTapped() {
    if player.timeControlStatus == .playing {
      pausePlayback(userInitiated: true)
    } else {
      playPlayback(userInitiated: true)
    }
  }

  @objc private func previousOrRewindTapped() {
    showControls()
    if let previousIndex = previousPlaybackIndex() {
      currentIndex = previousIndex
      playCurrent()
      showOverlay("Previous video")
      return
    }

    let target = max(0, durationSeconds(for: player.currentTime()) - 10)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    showOverlay("Rewind 10s")
  }

  @objc private func nextOrForwardTapped() {
    showControls()
    if let nextIndex = nextPlaybackIndex() {
      currentIndex = nextIndex
      playCurrent()
      showOverlay("Next video")
      return
    }

    let target = durationSeconds(for: player.currentTime()) + 10
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    showOverlay("Forward 10s")
  }

  @objc private func sliderBegan() {
    showControls()
  }

  @objc private func sliderChanged() {
    guard lastDuration > 0 else {
      return
    }
    let position = Double(bufferedSlider.value) * lastDuration
    currentTimeLabel.text = format(seconds: position)
  }

  @objc private func sliderEnded() {
    guard lastDuration > 0 else {
      return
    }
    let position = Double(bufferedSlider.value) * lastDuration
    player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
    scheduleControlsHide()
  }

  @objc private func showSpeedOptions() {
    let controller = UIAlertController(title: "Playback Speed", message: nil, preferredStyle: .actionSheet)
    [0.5, 1.0, 1.5, 2.0].forEach { speed in
      controller.addAction(UIAlertAction(title: "\(speed)x", style: .default) { _ in
        self.currentPlaybackRate = Float(speed)
        self.speedButton.setTitle("\(speed)x", for: .normal)
        if self.player.timeControlStatus == .playing {
          self.player.playImmediately(atRate: Float(speed))
        }
        self.showOverlay("Speed \(speed)x")
      })
    }
    controller.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(controller, from: speedButton)
  }

  @objc private func loopTapped() {
    isLooping.toggle()
    refreshButtonTint()
    showOverlay(isLooping ? "Loop on" : "Loop off")
  }

  @objc private func shuffleTapped() {
    isShuffleEnabled.toggle()
    if isShuffleEnabled {
      rebuildShuffleOrder(currentIndex: currentIndex)
    } else {
      shuffledIndexes.removeAll()
      shuffledPosition = -1
    }
    refreshButtonTint()
    showOverlay(isShuffleEnabled ? "Shuffle on" : "Shuffle off")
  }

  @objc private func backgroundPlayTapped() {
    backgroundPlayEnabled.toggle()
    UserDefaults.standard.set(backgroundPlayEnabled, forKey: "ios_background_play_enabled")
    refreshButtonTint()
    showOverlay(backgroundPlayEnabled ? "Background play on" : "Background play off")
  }

  @objc private func screenshotTapped() {
    captureScreenshot()
  }

  @objc private func showSettingsMenu() {
    configurePictureInPictureIfNeeded()

    let controller = UIAlertController(title: "Playback Settings", message: nil, preferredStyle: .actionSheet)

    controller.addAction(UIAlertAction(title: pictureInPictureEnabled ? "Disable Picture in Picture" : "Enable Picture in Picture", style: .default) { _ in
      self.pictureInPictureEnabled.toggle()
      UserDefaults.standard.set(self.pictureInPictureEnabled, forKey: "ios_picture_in_picture_enabled")
      self.configurePictureInPictureIfNeeded()
      if !self.pictureInPictureEnabled, self.pictureInPictureController?.isPictureInPictureActive == true {
        self.pictureInPictureController?.stopPictureInPicture()
      }
      self.refreshButtonTint()
      self.showOverlay(self.pictureInPictureEnabled ? "PiP on" : "PiP off")
    })

    if self.pictureInPictureEnabled, self.pictureInPictureController != nil {
      let manualTitle = pictureInPictureController?.isPictureInPictureActive == true ? "Stop Picture in Picture Now" : "Start Picture in Picture Now"
      let manualAction = UIAlertAction(title: manualTitle, style: .default) { _ in
        if self.pictureInPictureController?.isPictureInPictureActive == true {
          self.pictureInPictureController?.stopPictureInPicture()
        } else {
          _ = self.startPictureInPictureIfPossible(automatic: false)
        }
      }
      manualAction.isEnabled =
        pictureInPictureController?.isPictureInPictureActive == true
        || pictureInPictureController?.isPictureInPicturePossible == true
        || player.currentItem?.status == .readyToPlay
      controller.addAction(manualAction)
    }

    controller.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(controller, from: settingsButton)
  }

  @objc private func showSubtitleOptions() {
    guard enableSubtitle else {
      return
    }

    let controller = UIAlertController(title: "Subtitles", message: nil, preferredStyle: .actionSheet)

    controller.addAction(UIAlertAction(title: subtitleEnabled ? "Turn Subtitles Off" : "Turn Subtitles On", style: .default) { _ in
      self.subtitleEnabled.toggle()
      if !self.subtitleEnabled {
        self.subtitleLabel.isHidden = true
      }
      self.updateSubtitleSelectionUI()
    })

    controller.addAction(UIAlertAction(title: "Search Online Subtitles", style: .default) { _ in
      self.showOnlineSubtitleSearch()
    })

    if let group = currentEmbeddedSubtitleGroup {
      group.options.forEach { option in
        let title = option.displayName
        controller.addAction(UIAlertAction(title: title, style: .default) { _ in
          self.customSubtitleCues = []
          self.customSubtitleURL = nil
          self.currentEmbeddedSubtitleOption = option
          self.player.currentItem?.select(option, in: group)
          self.subtitleEnabled = true
          self.updateSubtitleSelectionUI()
          self.showOverlay("Subtitle \(title)")
        })
      }
    }

    controller.addAction(UIAlertAction(title: "Choose Subtitle File", style: .default) { _ in
      self.presentSubtitlePicker()
    })

    controller.addAction(UIAlertAction(title: "Load Subtitle URL", style: .default) { _ in
      self.showSubtitleURLPrompt()
    })

    if !customSubtitleCues.isEmpty {
      controller.addAction(UIAlertAction(title: "Remove Custom Subtitle", style: .destructive) { _ in
        self.customSubtitleCues = []
        self.customSubtitleURL = nil
        self.subtitleLabel.isHidden = true
        self.updateSubtitleSelectionUI()
      })
    }

    controller.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(controller, from: subtitleButton)
  }

  private func presentSubtitlePicker() {
    let types = [
      UTType(filenameExtension: "srt"),
      UTType(filenameExtension: "vtt"),
      UTType(filenameExtension: "ass"),
      UTType(filenameExtension: "ssa"),
      .plainText,
      .text,
    ].compactMap { $0 }

    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    topViewController()?.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      return
    }

    let needsAccess = url.startAccessingSecurityScopedResource()
    defer {
      if needsAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
    try? FileManager.default.removeItem(at: tempURL)
    do {
      try FileManager.default.copyItem(at: url, to: tempURL)
      loadCustomSubtitles(from: tempURL, announce: true)
    } catch {
      showOverlay("Subtitle import failed")
    }
  }

  @objc private func lockControlsTapped() {
    controlsLocked = true
    controlsContainer.isHidden = true
    unlockButton.isHidden = false
    showOverlay("Controls locked")
  }

  @objc private func unlockControlsTapped() {
    controlsLocked = false
    unlockButton.isHidden = true
    showControls()
    showOverlay("Controls unlocked")
  }

  @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
    if controlsLocked {
      unlockButton.isHidden = false
      return
    }

    controlsVisible ? hideControls() : showControls()
  }

  @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
    if controlsLocked {
      return
    }

    if videoScale > 1.02 {
      resetZoom(showLabel: true)
      return
    }

    let location = recognizer.location(in: self)
    if location.x < bounds.midX {
      let target = max(0, durationSeconds(for: player.currentTime()) - 10)
      player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      showOverlay("Rewind 10s")
    } else {
      let target = durationSeconds(for: player.currentTime()) + 10
      player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      showOverlay("Forward 10s")
    }
  }

  @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
    guard !controlsLocked else {
      return
    }

    if recognizer.state == .changed || recognizer.state == .ended {
      videoScale = min(3, max(1, videoScale * recognizer.scale))
      recognizer.scale = 1
      clampTranslation()
      applyVideoTransform()
      updateZoomLabel()
      scheduleControlsHide()
    }
  }

  @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
    guard !controlsLocked else {
      return
    }

    let translation = recognizer.translation(in: self)

    switch recognizer.state {
    case .began:
      gestureHudHideWorkItem?.cancel()
      gestureStartBrightness = currentGestureBrightnessLevel
      gestureStartVolume = currentSystemVolumeLevel()
      lastPanTranslation = .zero
      gestureMode = videoScale > 1.02 ? .panZoom : (recognizer.location(in: self).x < bounds.midX ? .brightness : .volume)
    case .changed:
      switch gestureMode {
      case .panZoom:
        videoTranslation.x += translation.x - lastPanTranslation.x
        videoTranslation.y += translation.y - lastPanTranslation.y
        clampTranslation()
        applyVideoTransform()
      case .brightness:
        let delta = -(translation.y / max(bounds.height, 1))
        applyGestureBrightness(gestureStartBrightness + delta)
      case .volume:
        let delta = Float(-(translation.y / max(bounds.height, 1)))
        applyGestureVolume(gestureStartVolume + delta)
      case .none:
        break
      }
      lastPanTranslation = translation
    case .ended, .cancelled, .failed:
      scheduleGestureHudHide()
      gestureMode = .none
      lastPanTranslation = .zero
    default:
      gestureMode = .none
      lastPanTranslation = .zero
      break
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }

  private func captureScreenshot() {
    guard let item = player.currentItem else {
      showOverlay("Screenshot unavailable")
      return
    }

    let generator = AVAssetImageGenerator(asset: item.asset)
    generator.appliesPreferredTrackTransform = true
    let time = player.currentTime()

    DispatchQueue.global(qos: .userInitiated).async {
      guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
        DispatchQueue.main.async {
          self.showOverlay("Screenshot unavailable")
        }
        return
      }

      let image = UIImage(cgImage: cgImage)
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized || status == .limited else {
          DispatchQueue.main.async {
            self.showOverlay("Photo permission denied")
          }
          return
        }

        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, _ in
          DispatchQueue.main.async {
            self.showOverlay(success ? "Screenshot saved" : "Screenshot failed")
          }
        }
      }
    }
  }

  @objc private func handleDidEnterBackground() {
    guard !isCleaningUp else {
      return
    }

    savePlaybackState(force: true)
    isAppInBackground = true

    if pendingAutoPictureInPicture || isAttemptingPictureInPictureStart {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        guard let self else {
          return
        }

        guard !self.isCleaningUp else {
          return
        }

        self.pendingAutoPictureInPicture = false
        self.isAttemptingPictureInPictureStart = false
        let pipActive = self.isInPictureInPictureMode || self.pictureInPictureController?.isPictureInPictureActive == true
        guard !pipActive, !self.backgroundPlayEnabled, self.player.timeControlStatus == .playing else {
          return
        }

        self.autoPausedForBackground = true
        self.pausePlayback(userInitiated: false)
      }
      return
    }

    let canHoldPlaybackForPiP =
      pictureInPictureEnabled
      && (isInPictureInPictureMode || pictureInPictureController?.isPictureInPicturePossible == true || pictureInPictureController?.isPictureInPictureActive == true)

    guard !backgroundPlayEnabled, !canHoldPlaybackForPiP else {
      return
    }
    if player.timeControlStatus == .playing {
      autoPausedForBackground = true
      pausePlayback(userInitiated: false)
    }
  }

  @objc private func handleWillResignActive() {
    guard !isAppInBackground,
          !isCleaningUp,
          !isHandlingBackNavigation,
          !pendingAutoPictureInPicture,
          !isAttemptingPictureInPictureStart else {
      return
    }

    guard pictureInPictureEnabled,
          pictureInPictureController != nil,
          player.timeControlStatus == .playing else {
      return
    }

    pendingAutoPictureInPicture = true
  }

  @objc private func handleSceneWillDeactivate(_ notification: Notification) {
    guard !isAppInBackground,
          !isCleaningUp,
          !isHandlingBackNavigation,
          !pendingAutoPictureInPicture,
          !isAttemptingPictureInPictureStart else {
      return
    }

    if let scene = notification.object as? UIWindowScene,
       let windowScene = window?.windowScene,
       scene !== windowScene {
      return
    }

    guard pictureInPictureEnabled,
          pictureInPictureController != nil,
          player.timeControlStatus == .playing else {
      return
    }

    pendingAutoPictureInPicture = true
  }

  @objc private func handleWillEnterForeground() {
    isAppInBackground = false
    pendingAutoPictureInPicture = false
    isAttemptingPictureInPictureStart = false
    cancelPictureInPictureStartRetry()
    if autoPausedForBackground, !paused {
      autoPausedForBackground = false
      playPlayback(userInitiated: false)
    }
  }

  @objc private func handleWillTerminate() {
    savePlaybackState(force: true)
  }

  private func present(_ controller: UIAlertController, from anchorView: UIView) {
    if let popover = controller.popoverPresentationController {
      popover.sourceView = anchorView
      popover.sourceRect = anchorView.bounds
    }
    topViewController()?.present(controller, animated: true)
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let baseController: UIViewController?
    if let base {
      baseController = base
    } else {
      baseController = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .rootViewController
    }

    if let navigationController = baseController as? UINavigationController {
      return topViewController(base: navigationController.visibleViewController)
    }
    if let tabController = baseController as? UITabBarController {
      return topViewController(base: tabController.selectedViewController)
    }
    if let presented = baseController?.presentedViewController {
      return topViewController(base: presented)
    }
    return baseController
  }

  private func format(seconds: Double) -> String {
    guard seconds.isFinite, !seconds.isNaN else {
      return "00:00"
    }
    let total = Int(max(0, seconds))
    let minutes = total / 60
    let remainingSeconds = total % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    cancelPictureInPictureStartRetry()
    isAttemptingPictureInPictureStart = false
    pendingAutoPictureInPicture = false
    isInPictureInPictureMode = true
    autoPausedForBackground = false
    hideControlsWorkItem?.cancel()
    hideControls()
    showOverlay("Picture in Picture")
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    cancelPictureInPictureStartRetry()
    isAttemptingPictureInPictureStart = false
    pendingAutoPictureInPicture = false
    isInPictureInPictureMode = true
    autoPausedForBackground = false
    if shouldPauseAfterPictureInPictureStarts {
      shouldPauseAfterPictureInPictureStarts = false
      pausePlayback(userInitiated: false)
    }
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    cancelPictureInPictureStartRetry()
    isAttemptingPictureInPictureStart = false
    pendingAutoPictureInPicture = false
    isInPictureInPictureMode = false
    shouldPauseAfterPictureInPictureStarts = false
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    cancelPictureInPictureStartRetry()
    isAttemptingPictureInPictureStart = false
    pendingAutoPictureInPicture = false
    isInPictureInPictureMode = false
    shouldPauseAfterPictureInPictureStarts = false
    if controls, !controlsLocked {
      showControls()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("RNVideoPlayer PiP failed to start: %@", error.localizedDescription)
    cancelPictureInPictureStartRetry()
    isAttemptingPictureInPictureStart = false
    pendingAutoPictureInPicture = false
    isInPictureInPictureMode = false
    if shouldPauseAfterPictureInPictureStarts {
      shouldPauseAfterPictureInPictureStarts = false
      pausePlayback(userInitiated: false)
    }

    guard isAppInBackground, !backgroundPlayEnabled, player.timeControlStatus == .playing else {
      showOverlay("PiP unavailable right now")
      return
    }

    autoPausedForBackground = true
    pausePlayback(userInitiated: false)
  }
}

private extension UIInterfaceOrientationMask {
  func contains(_ orientation: UIInterfaceOrientation) -> Bool {
    let targetMask: UIInterfaceOrientationMask
    switch orientation {
    case .portrait:
      targetMask = .portrait
    case .portraitUpsideDown:
      targetMask = .portraitUpsideDown
    case .landscapeLeft:
      targetMask = .landscapeLeft
    case .landscapeRight:
      targetMask = .landscapeRight
    default:
      return false
    }

    return rawValue & targetMask.rawValue != 0
  }
}

private final class PlayerSurfaceView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

private final class PaddingLabel: UILabel {
  var contentInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: contentInsets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + contentInsets.left + contentInsets.right,
      height: size.height + contentInsets.top + contentInsets.bottom
    )
  }
}

private final class GestureHudView: UIView {
  private let iconView = UIImageView()
  private let trackView = UIView()
  private let fillView = UIView()
  private let percentLabel = UILabel()
  private let fillColor: UIColor
  private var percent = 0
  private var fillHeightConstraint: NSLayoutConstraint?

  init(symbol: String, fillColor: UIColor) {
    self.fillColor = fillColor
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = 16
    backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    iconView.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    )
    addSubview(iconView)

    trackView.translatesAutoresizingMaskIntoConstraints = false
    trackView.backgroundColor = UIColor.white.withAlphaComponent(0.35)
    trackView.layer.cornerRadius = 4
    trackView.clipsToBounds = true
    addSubview(trackView)

    fillView.translatesAutoresizingMaskIntoConstraints = false
    fillView.backgroundColor = fillColor
    fillView.layer.cornerRadius = 4
    trackView.addSubview(fillView)

    percentLabel.translatesAutoresizingMaskIntoConstraints = false
    percentLabel.textColor = .white
    percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    percentLabel.textAlignment = .center
    addSubview(percentLabel)

    fillHeightConstraint = fillView.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      iconView.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),

      trackView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
      trackView.centerXAnchor.constraint(equalTo: centerXAnchor),
      trackView.widthAnchor.constraint(equalToConstant: 10),
      trackView.heightAnchor.constraint(equalToConstant: 132),

      fillView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
      fillView.trailingAnchor.constraint(equalTo: trackView.trailingAnchor),
      fillView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),
      fillHeightConstraint!,

      percentLabel.topAnchor.constraint(equalTo: trackView.bottomAnchor, constant: 14),
      percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      percentLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
    ])

    setPercent(50)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func setPercent(_ value: Int) {
    percent = min(100, max(0, value))
    percentLabel.text = "\(percent)%"
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let trackHeight = trackView.bounds.height > 0 ? trackView.bounds.height : 132
    let targetHeight: CGFloat
    if percent == 0 {
      targetHeight = 0
    } else {
      targetHeight = max(2, trackHeight * CGFloat(percent) / 100)
    }

    fillHeightConstraint?.constant = targetHeight
  }
}

private final class BufferedSlider: UIControl {
  private let trackLayer = CALayer()
  private let bufferLayer = CALayer()
  private let progressLayer = CALayer()
  private let thumbLayer = CALayer()

  var value: CGFloat = 0 {
    didSet { updateLayers() }
  }

  var bufferValue: CGFloat = 0 {
    didSet { updateLayers() }
  }

  var progressTintColor: UIColor = .systemTeal {
    didSet { progressLayer.backgroundColor = progressTintColor.cgColor }
  }

  var trackTintColor: UIColor = UIColor.white.withAlphaComponent(0.3) {
    didSet { trackLayer.backgroundColor = trackTintColor.cgColor }
  }

  var bufferTintColor: UIColor = UIColor.white.withAlphaComponent(0.85) {
    didSet { bufferLayer.backgroundColor = bufferTintColor.cgColor }
  }

  var thumbTintColor: UIColor = .systemTeal {
    didSet { thumbLayer.backgroundColor = thumbTintColor.cgColor }
  }

  private(set) var isInteracting = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.addSublayer(trackLayer)
    layer.addSublayer(bufferLayer)
    layer.addSublayer(progressLayer)
    layer.addSublayer(thumbLayer)
    thumbLayer.shadowColor = UIColor.black.cgColor
    thumbLayer.shadowOpacity = 0.25
    thumbLayer.shadowRadius = 3
    thumbLayer.shadowOffset = CGSize(width: 0, height: 1)
    trackLayer.backgroundColor = trackTintColor.cgColor
    bufferLayer.backgroundColor = bufferTintColor.cgColor
    progressLayer.backgroundColor = progressTintColor.cgColor
    thumbLayer.backgroundColor = thumbTintColor.cgColor
    accessibilityTraits = .adjustable
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateLayers()
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    isInteracting = true
    updateValue(for: touch.location(in: self))
    sendActions(for: .editingDidBegin)
    sendActions(for: .valueChanged)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    updateValue(for: touch.location(in: self))
    sendActions(for: .valueChanged)
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    isInteracting = false
    sendActions(for: .editingDidEnd)
  }

  override func cancelTracking(with event: UIEvent?) {
    isInteracting = false
    sendActions(for: .editingDidEnd)
  }

  private func updateValue(for point: CGPoint) {
    let inset: CGFloat = 10
    let usableWidth = max(1, bounds.width - inset * 2)
    let normalized = min(1, max(0, (point.x - inset) / usableWidth))
    value = normalized
  }

  private func updateLayers() {
    let inset: CGFloat = 10
    let trackHeight: CGFloat = 4
    let thumbSize: CGFloat = 16
    let trackFrame = CGRect(
      x: inset,
      y: (bounds.height - trackHeight) * 0.5,
      width: max(1, bounds.width - inset * 2),
      height: trackHeight
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.frame = trackFrame
    trackLayer.cornerRadius = trackHeight * 0.5
    bufferLayer.frame = CGRect(
      x: trackFrame.minX,
      y: trackFrame.minY,
      width: trackFrame.width * min(1, max(bufferValue, value)),
      height: trackHeight
    )
    bufferLayer.cornerRadius = trackHeight * 0.5
    progressLayer.frame = CGRect(
      x: trackFrame.minX,
      y: trackFrame.minY,
      width: trackFrame.width * value,
      height: trackHeight
    )
    progressLayer.cornerRadius = trackHeight * 0.5
    let thumbCenterX = trackFrame.minX + trackFrame.width * value
    thumbLayer.frame = CGRect(
      x: thumbCenterX - thumbSize * 0.5,
      y: (bounds.height - thumbSize) * 0.5,
      width: thumbSize,
      height: thumbSize
    )
    thumbLayer.cornerRadius = thumbSize * 0.5
    CATransaction.commit()
  }
}

private enum SubtitleParser {
  static func parse(url: URL) throws -> [SubtitleCue] {
    let content = try readText(from: url)
      .replacingOccurrences(of: "\u{feff}", with: "")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    let ext = url.pathExtension.lowercased()
    if ext == "ass" || ext == "ssa" || content.contains("[Events]") {
      return parseSSA(content)
    }

    if ext == "vtt" || content.hasPrefix("WEBVTT") {
      let parsed = parseBlocks(content.replacingOccurrences(of: "WEBVTT", with: ""))
      return parsed.isEmpty ? parseLineBased(content) : parsed
    }

    let parsed = parseBlocks(content)
    return parsed.isEmpty ? parseLineBased(content) : parsed
  }

  private static func readText(from url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let encodings: [String.Encoding] = [.utf8, .utf16, .unicode, .windowsCP1252, .isoLatin1]

    for encoding in encodings {
      if let string = String(data: data, encoding: encoding) {
        return string
      }
    }

    throw NSError(domain: "SubtitleParser", code: 1)
  }

  private static func parseBlocks(_ content: String) -> [SubtitleCue] {
    content
      .components(separatedBy: "\n\n")
      .compactMap { block -> SubtitleCue? in
        let lines = block
          .split(separator: "\n")
          .map { String($0).trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }

        guard let timelineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
          return nil
        }

        let parts = lines[timelineIndex].components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else {
          return nil
        }

        let text = cleanSubtitleText(lines.suffix(from: timelineIndex + 1).joined(separator: "\n"))
        guard !text.isEmpty else {
          return nil
        }

        return SubtitleCue(start: start, end: end, text: text)
      }
  }

  private static func parseLineBased(_ content: String) -> [SubtitleCue] {
    let lines = content
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    var index = 0
    var cues: [SubtitleCue] = []

    while index < lines.count {
      let line = lines[index]
      if !line.contains("-->") {
        index += 1
        continue
      }

      let parts = line.components(separatedBy: "-->")
      guard parts.count == 2,
        let start = parseTimestamp(parts[0]),
        let end = parseTimestamp(parts[1]) else {
        index += 1
        continue
      }

      index += 1
      var textLines: [String] = []
      while index < lines.count, !lines[index].isEmpty, !lines[index].contains("-->") {
        if Int(lines[index]) == nil {
          textLines.append(lines[index])
        }
        index += 1
      }

      let text = cleanSubtitleText(textLines.joined(separator: "\n"))
      if !text.isEmpty {
        cues.append(SubtitleCue(start: start, end: end, text: text))
      }
    }

    return cues
  }

  private static func parseSSA(_ content: String) -> [SubtitleCue] {
    content
      .components(separatedBy: "\n")
      .compactMap { rawLine -> SubtitleCue? in
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("Dialogue:") else {
          return nil
        }

        let payload = line.dropFirst("Dialogue:".count).trimmingCharacters(in: .whitespaces)
        let parts = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count >= 10,
          let start = parseTimestamp(String(parts[1])),
          let end = parseTimestamp(String(parts[2])) else {
          return nil
        }

        let rawText = String(parts[9])
          .replacingOccurrences(of: "\\N", with: "\n")
          .replacingOccurrences(of: "\\n", with: "\n")
        let text = cleanSubtitleText(rawText.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression))
        guard !text.isEmpty else {
          return nil
        }

        return SubtitleCue(start: start, end: end, text: text)
      }
  }

  private static func cleanSubtitleText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private static func parseTimestamp(_ value: String) -> Double? {
    let cleaned = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: " ")
      .first?
      .replacingOccurrences(of: ",", with: ".")
      .replacingOccurrences(of: "\u{200E}", with: "")
      .replacingOccurrences(of: "\u{200F}", with: "") ?? value

    let segments = cleaned.split(separator: ":").map(String.init)
    guard segments.count >= 2 else {
      return nil
    }

    let hours: Double
    let minutes: Double
    let seconds: Double

    if segments.count == 3 {
      hours = Double(segments[0]) ?? 0
      minutes = Double(segments[1]) ?? 0
      seconds = Double(segments[2]) ?? 0
    } else {
      hours = 0
      minutes = Double(segments[0]) ?? 0
      seconds = Double(segments[1]) ?? 0
    }

    return hours * 3600 + minutes * 60 + seconds
  }
}

private final class SubtitleSearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private weak var playerView: RNVideoPlayerView?
  private let initialQuery: String
  private let panelView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
  private let titleLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private let searchBar = UISearchBar()
  private let helperLabel = UILabel()
  private let statusLabel = UILabel()
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private let tableView = UITableView(frame: .zero, style: .plain)

  private var results: [SubtitleSearchResult] = []
  private var searchTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var hasTriggeredInitialSearch = false

  init(playerView: RNVideoPlayerView, initialQuery: String) {
    self.playerView = playerView
    self.initialQuery = initialQuery
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    searchTask?.cancel()
    downloadTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasTriggeredInitialSearch, !initialQuery.isEmpty else {
      return
    }
    hasTriggeredInitialSearch = true
    performSearch(query: initialQuery)
  }

  private func setupViews() {
    view.backgroundColor = UIColor.black.withAlphaComponent(0.72)

    panelView.translatesAutoresizingMaskIntoConstraints = false
    panelView.layer.cornerRadius = 24
    panelView.clipsToBounds = true
    view.addSubview(panelView)

    let contentView = panelView.contentView

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "Online subtitles"
    titleLabel.textColor = .white
    titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.tintColor = .white
    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    searchBar.translatesAutoresizingMaskIntoConstraints = false
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = "Search any subtitle"
    searchBar.text = initialQuery
    searchBar.delegate = self
    searchBar.tintColor = UIColor.systemTeal
    searchBar.searchTextField.textColor = .white
    searchBar.searchTextField.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    searchBar.searchTextField.leftView?.tintColor = UIColor.white.withAlphaComponent(0.8)

    helperLabel.translatesAutoresizingMaskIntoConstraints = false
    helperLabel.text = "Search by any name, episode, language, or keyword."
    helperLabel.textColor = UIColor.white.withAlphaComponent(0.76)
    helperLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    helperLabel.numberOfLines = 0

    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.color = .white
    activityIndicator.hidesWhenStopped = true

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.text = "Enter a search and press Search."
    statusLabel.textColor = UIColor.white.withAlphaComponent(0.86)
    statusLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
    statusLabel.numberOfLines = 0

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorColor = UIColor.white.withAlphaComponent(0.1)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.keyboardDismissMode = .onDrag
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 74
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SubtitleResultCell")

    contentView.addSubview(titleLabel)
    contentView.addSubview(closeButton)
    contentView.addSubview(searchBar)
    contentView.addSubview(helperLabel)
    contentView.addSubview(activityIndicator)
    contentView.addSubview(statusLabel)
    contentView.addSubview(tableView)

    NSLayoutConstraint.activate([
      panelView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      panelView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      panelView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      panelView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

      closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
      closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 34),
      closeButton.heightAnchor.constraint(equalToConstant: 34),

      searchBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      searchBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      searchBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),

      helperLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      helperLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      helperLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),

      activityIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      activityIndicator.topAnchor.constraint(equalTo: helperLabel.bottomAnchor, constant: 14),

      statusLabel.leadingAnchor.constraint(equalTo: activityIndicator.trailingAnchor, constant: 12),
      statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      statusLabel.centerYAnchor.constraint(equalTo: activityIndicator.centerYAnchor),

      tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    performSearch(query: searchBar.text ?? "")
  }

  private func performSearch(query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty, let playerView else {
      statusLabel.text = "Enter a search and press Search."
      return
    }

    searchTask?.cancel()
    downloadTask?.cancel()
    activityIndicator.startAnimating()
    statusLabel.text = "Searching Subdl..."
    results = []
    tableView.reloadData()

    searchTask = Task { [weak self, weak playerView] in
      guard let self, let playerView else { return }
      let results = await playerView.searchSubtitles(query: trimmedQuery)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        self.activityIndicator.stopAnimating()
        self.results = results
        self.tableView.reloadData()
        self.statusLabel.text = results.isEmpty
          ? "No subtitles found"
          : "\(results.count) subtitles found. Tap one to download."
      }
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    results.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "SubtitleResultCell", for: indexPath)
    let result = results[indexPath.row]

    var content = UIListContentConfiguration.subtitleCell()
    content.text = result.releaseName
    content.secondaryText = "\(result.mediaTitle) • \(result.language) • \(result.fileName)"
    content.textProperties.color = .white
    content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.72)
    content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    content.secondaryTextProperties.numberOfLines = 2
    content.image = UIImage(systemName: "captions.bubble.fill")
    content.imageProperties.tintColor = UIColor.systemTeal
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    cell.accessoryView = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
    (cell.accessoryView as? UIImageView)?.tintColor = UIColor.systemTeal
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let playerView else {
      return
    }

    let result = results[indexPath.row]
    tableView.deselectRow(at: indexPath, animated: true)
    searchTask?.cancel()
    downloadTask?.cancel()
    activityIndicator.startAnimating()
    statusLabel.text = "Downloading \(result.fileName)..."

    downloadTask = Task { [weak self, weak playerView] in
      guard let self, let playerView else { return }
      let localURL = await playerView.downloadSubtitleFile(result)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        self.activityIndicator.stopAnimating()
        guard let localURL else {
          self.statusLabel.text = "Unable to download subtitle."
          return
        }

        self.dismiss(animated: true) {
          playerView.loadCustomSubtitles(from: localURL, announce: true)
        }
      }
    }
  }
}

private enum SimpleZipExtractor {
  private enum ZipError: Error {
    case invalidArchive
    case unsupportedCompression(UInt16)
    case missingSubtitleEntry
    case inflateFailed(Int32)
  }

  private struct Entry {
    let fileName: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
  }

  private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
  private static let centralDirectoryFileHeaderSignature: UInt32 = 0x02014b50
  private static let localFileHeaderSignature: UInt32 = 0x04034b50

  static func extractFirstSubtitle(
    from archiveURL: URL,
    into outputDirectory: URL,
    preferredBaseName: String,
    keyPrefix: String
  ) throws -> URL {
    let data = try Data(contentsOf: archiveURL)
    defer {
      try? FileManager.default.removeItem(at: archiveURL)
    }

    let allowedExtensions: Set<String> = ["srt", "vtt"]
    let entries = try centralDirectoryEntries(in: data)
    guard let entry = entries.first(where: {
      let path = URL(fileURLWithPath: $0.fileName)
      let ext = path.pathExtension.lowercased()
      return !path.hasDirectoryPath && allowedExtensions.contains(ext)
    }) else {
      throw ZipError.missingSubtitleEntry
    }

    let extractedData = try extract(entry: entry, from: data)
    let extensionName = URL(fileURLWithPath: entry.fileName).pathExtension.lowercased()
    let outputURL = outputDirectory.appendingPathComponent("\(keyPrefix)-\(preferredBaseName).\(extensionName)")
    try? FileManager.default.removeItem(at: outputURL)
    try extractedData.write(to: outputURL, options: .atomic)
    return outputURL
  }

  private static func centralDirectoryEntries(in data: Data) throws -> [Entry] {
    guard data.count >= 22 else {
      throw ZipError.invalidArchive
    }

    let searchStart = max(0, data.count - (22 + 65535))
    var endOfCentralDirectoryOffset: Int?

    for offset in stride(from: data.count - 22, through: searchStart, by: -1) {
      if try readUInt32(in: data, offset: offset) == endOfCentralDirectorySignature {
        endOfCentralDirectoryOffset = offset
        break
      }
    }

    guard let endOfCentralDirectoryOffset else {
      throw ZipError.invalidArchive
    }

    let entryCount = Int(try readUInt16(in: data, offset: endOfCentralDirectoryOffset + 10))
    let centralDirectorySize = Int(try readUInt32(in: data, offset: endOfCentralDirectoryOffset + 12))
    let centralDirectoryOffset = Int(try readUInt32(in: data, offset: endOfCentralDirectoryOffset + 16))
    let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize

    guard centralDirectoryOffset >= 0, centralDirectoryEnd <= data.count else {
      throw ZipError.invalidArchive
    }

    var offset = centralDirectoryOffset
    var entries: [Entry] = []

    for _ in 0..<entryCount {
      guard try readUInt32(in: data, offset: offset) == centralDirectoryFileHeaderSignature else {
        throw ZipError.invalidArchive
      }

      let compressionMethod = try readUInt16(in: data, offset: offset + 10)
      let compressedSize = Int(try readUInt32(in: data, offset: offset + 20))
      let uncompressedSize = Int(try readUInt32(in: data, offset: offset + 24))
      let fileNameLength = Int(try readUInt16(in: data, offset: offset + 28))
      let extraLength = Int(try readUInt16(in: data, offset: offset + 30))
      let commentLength = Int(try readUInt16(in: data, offset: offset + 32))
      let localHeaderOffset = Int(try readUInt32(in: data, offset: offset + 42))
      let fileNameStart = offset + 46
      let fileNameEnd = fileNameStart + fileNameLength

      guard fileNameEnd <= data.count else {
        throw ZipError.invalidArchive
      }

      let fileName = String(data: data[fileNameStart..<fileNameEnd], encoding: .utf8) ?? ""
      entries.append(
        Entry(
          fileName: fileName,
          compressionMethod: compressionMethod,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset
        )
      )

      offset = fileNameEnd + extraLength + commentLength
      if offset > centralDirectoryEnd {
        throw ZipError.invalidArchive
      }
    }

    return entries
  }

  private static func extract(entry: Entry, from data: Data) throws -> Data {
    let headerOffset = entry.localHeaderOffset
    guard try readUInt32(in: data, offset: headerOffset) == localFileHeaderSignature else {
      throw ZipError.invalidArchive
    }

    let fileNameLength = Int(try readUInt16(in: data, offset: headerOffset + 26))
    let extraLength = Int(try readUInt16(in: data, offset: headerOffset + 28))
    let dataStart = headerOffset + 30 + fileNameLength + extraLength
    let dataEnd = dataStart + entry.compressedSize

    guard dataStart >= 0, dataEnd <= data.count else {
      throw ZipError.invalidArchive
    }

    let compressedData = Data(data[dataStart..<dataEnd])
    switch entry.compressionMethod {
    case 0:
      return compressedData
    case 8:
      return try inflateDeflatedData(compressedData, expectedSize: entry.uncompressedSize)
    default:
      throw ZipError.unsupportedCompression(entry.compressionMethod)
    }
  }

  private static func inflateDeflatedData(_ data: Data, expectedSize: Int) throws -> Data {
    var stream = z_stream()
    let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else {
      throw ZipError.inflateFailed(initStatus)
    }

    defer {
      inflateEnd(&stream)
    }

    let bufferSize = max(32 * 1024, min(max(expectedSize, 1), 256 * 1024))
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    return try data.withUnsafeBytes { rawBuffer throws -> Data in
      guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
        throw ZipError.invalidArchive
      }

      stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
      stream.avail_in = uInt(rawBuffer.count)

      while true {
        let bufferCount = buffer.count
        let status = buffer.withUnsafeMutableBytes { outputBuffer -> Int32 in
          stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = uInt(bufferCount)
          return inflate(&stream, Z_NO_FLUSH)
        }

        let written = buffer.count - Int(stream.avail_out)
        if written > 0 {
          output.append(contentsOf: buffer[0..<written])
        }

        if status == Z_STREAM_END {
          break
        }

        if status == Z_BUF_ERROR, stream.avail_in == 0 {
          break
        }

        guard status == Z_OK else {
          throw ZipError.inflateFailed(status)
        }
      }

      return output
    }
  }

  private static func readUInt16(in data: Data, offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else {
      throw ZipError.invalidArchive
    }

    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32(in data: Data, offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
      throw ZipError.invalidArchive
    }

    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}
