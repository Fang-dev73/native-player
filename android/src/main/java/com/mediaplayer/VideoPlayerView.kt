package com.nyjs.nativeplayer

import android.app.Activity
import android.app.Dialog
import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.media.AudioManager
import android.net.Uri
import android.util.Rational
import android.util.TypedValue
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.*
import android.view.ScaleGestureDetector
import androidx.core.view.drawToBitmap
import androidx.core.view.isVisible
import android.view.animation.AlphaAnimation
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import com.facebook.react.bridge.BaseActivityEventListener
import com.facebook.react.bridge.*
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStream
import java.io.File
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream
import android.graphics.drawable.GradientDrawable
import android.view.TextureView
import android.util.Log
import org.json.JSONObject
import kotlin.math.max

data class VideoSourceEntry(
    val uri: String,
    val title: String? = null
)

@UnstableApi
class VideoPlayerView(context: Context) : FrameLayout(context), LifecycleEventListener {
    private val reactContext = context as ReactContext
    private val trackSelector = createTrackSelector(context)
    private val player = createPlayer(context)
    private val textureView = TextureView(context)

    private val controls = FrameLayout(context)
    private val seekBar = SeekBar(context)

    private val playBtn = ImageView(context)
    private val forwardBtn = ImageView(context)
    private val rewindBtn = ImageView(context)
    private val speedBtn = TextView(context)
    private val subtitleBtn = TextView(context)
    private val screenshotBtn = ImageView(context)
    private val backgroundPlayBtn = ImageView(context)
    private val settingsBtn = ImageView(context)
    private val shuffleBtn = ImageView(context)
    private val lockBtn = ImageView(context)
    private val loopBtn = ImageView(context)
    private val backBtn = ImageView(context)
    private val fileNameText = TextView(context)

    private val currentText = TextView(context)
    private val durationText = TextView(context)
    private val overlayText = TextView(context)
    private val zoomIndicatorText = TextView(context)
    private val subtitleView = SubtitleView(context)
    private val subtitleFallbackText = TextView(context)
    private val subtitleCuePopupContainer = FrameLayout(context)
    private val subtitleCuePopupText = TextView(context)
    private val brightnessHud = LinearLayout(context)
    private val volumeHud = LinearLayout(context)
    private val brightnessBarTrack = FrameLayout(context)
    private val volumeBarTrack = FrameLayout(context)
    private val brightnessBarFill = View(context)
    private val volumeBarFill = View(context)
    private val brightnessIcon = ImageView(context)
    private val volumeIcon = ImageView(context)

    private val unlockBtn = ImageView(context)

    private val bufferLoader = ProgressBar(context)

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val playbackPrefs: SharedPreferences =
        context.getSharedPreferences("media_player_resume", Context.MODE_PRIVATE)
    private val bufferedTrackColor = Color.parseColor("#E6FFFFFF")

    private var lastDuration = 0L
    private var lastPlaybackState = Player.STATE_IDLE
    private var currentSourceIsRemote = false
    private var isSeeking = false
    private var controlsVisible = true
    private var controlsLocked = false
    private var lastKnownCacheStats = VideoCacheStats()
    private var lastProgressEventAtMs = 0L
    private var lastCacheStatsRefreshAtMs = 0L
    private var isCacheStatsRefreshInFlight = false

    private val hideHandler = Handler(Looper.getMainLooper())

    private var gestureBrightness = 0f
    private var gestureVolume = 0
    private var initialTouchY = 0f
    private var initialTouchX = 0f
    private var lastGestureUiUpdate = 0L
    private var gestureMode = 0
    private val gestureUiThrottleMs = 120L
    private val overlayHideRunnable = Runnable {
        overlayText.animate().cancel()
        overlayText.animate().alpha(0f).setDuration(200)
            .withEndAction { overlayText.visibility = View.GONE }
            .start()
    }
    private val zoomIndicatorHideRunnable = Runnable {
        zoomIndicatorText.animate().cancel()
        zoomIndicatorText.animate().alpha(0f).setDuration(180)
            .withEndAction { zoomIndicatorText.visibility = View.GONE }
            .start()
    }
    private val gestureHudHideRunnable = Runnable { hideGestureHud() }
    private val minVideoZoom = 1f
    private val maxVideoZoom = 3f
    private var videoZoomScale = 1f
    private var videoPanX = 0f
    private var videoPanY = 0f
    private var lastPanTouchX = 0f
    private var lastPanTouchY = 0f
    private var isZoomGestureActive = false
    private var isPanningZoomedVideo = false
    private var gesturePopup: PopupWindow? = null
    private var unlockPopup: PopupWindow? = null
    private var subtitleCuePopup: PopupWindow? = null
    private val popupHudContainer = LinearLayout(context)
    private val popupHudIcon = ImageView(context)
    private val popupHudTrack = FrameLayout(context)
    private val popupHudFill = View(context)
    private val popupHudPercent = TextView(context)
    private val unlockPopupContainer = FrameLayout(context)
    private val resumeOverlay = FrameLayout(context)
    private val resumeCard = LinearLayout(context)
    private val resumeTitleText = TextView(context)
    private val resumeMessageText = TextView(context)
    private val resumeInfoRow = LinearLayout(context)
    private val resumeDismissBtn = TextView(context)
    private val resumeInfoText = TextView(context)
    private val resumeStartOverBtn = TextView(context)
    private val resumeContinueBtn = TextView(context)
    private val subtitleDrawerOverlay = FrameLayout(context)
    private val subtitleDrawerPanel = LinearLayout(context)
    private val subtitleDrawerTitle = TextView(context)
    private val subtitleDrawerOnlineBtn = TextView(context)
    private val subtitleDrawerContent = LinearLayout(context)
    private val subtitleEmptyStateText = TextView(context)
    private val subtitleSelectedCard = LinearLayout(context)
    private val subtitleSelectedCheck = CheckBox(context)
    private val subtitleSelectedName = TextView(context)
    private val subtitleSelectedMeta = TextView(context)
    private val subtitleRemoveRow = LinearLayout(context)
    private val resumeBannerStartOverLabel = TextView(context)
    private var buttonTintColor = Color.WHITE
    private var subtitleTextColor = Color.WHITE
    private var subtitleCheckboxColor = Color.WHITE
    private var subtitleDescriptionColor = Color.WHITE
    private var backgroundPlayEnabled = playbackPrefs.getBoolean(PREF_BACKGROUND_PLAY_ENABLED, false)
    private var pictureInPictureEnabled = playbackPrefs.getBoolean(PREF_PICTURE_IN_PICTURE_ENABLED, true)
    private var suppressAutoPictureInPictureUntilResume = false
    private var enteredPictureInPictureFromLeaveHint = false
    private var autoPausedForBackground = false
    private var isInPictureInPictureMode = false
    private var pendingPictureInPictureUiRestore = false
    private val playBtnBg = GradientDrawable()
    private val rewindBtnBg = GradientDrawable()
    private val forwardBtnBg = GradientDrawable()
    private var subtitleDrawerDialog: Dialog? = null
    private var subtitleSearchDialog: Dialog? = null
    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var subtitleMenuOpenCount = 0
    private var wasPlayingBeforeSubtitleMenu = false
    private var subtitleDrawerOpenedAtMs = 0L
    private var resumeContinuePlaying = false
    private var wasPlayingWhenLocked = false
    private var currentMediaUri: String? = null
    private var pendingInitialControlsRestore = false
    private var pendingResumePositionMs: Long? = null
    private var hasHandledResumePrompt = false
    private var lastPersistedUri: String? = null
    private var lastPersistedPositionMs = -1L
    private var resumePlaybackEnabled = false
    private var didAutoResumeCurrentMedia = false
    private var suppressResumeSaveUntilRestart = false

    private var isLooping = false
    private var isShuffleEnabled = false
    private var isVideoVertical = false
    private var controlsEnabled = true
    private var enableSubtitle = false

    // Subtitle state
    private var subtitlePlaybackEnabled = true
    private var userDisabledSubtitles = false
    private var hasEmbeddedSubtitles = false
    private var didAutoEnableEmbeddedSubtitles = false

    private var subtitleToggleRowOverlay: LinearLayout? = null
    private var subtitleToggleRowDialog: LinearLayout? = null

    private var selectedSubtitleUri: Uri? = null
    private var selectedSubtitleMimeType: String? = null
    private var activeSubtitleText: CharSequence = ""
    private var isAwaitingSubtitlePickerResult = false
    private var originalRequestedOrientation: Int? = null
    private var appliedRequestedOrientation: Int? = null

    private val videoQueue = mutableListOf<VideoSourceEntry>()
    private val shuffledQueue = mutableListOf<Int>()
    private var currentIndex = 0
    private var shuffledQueuePosition = -1
    private var pendingIndex: Int? = null
    private var topBar: LinearLayout? = null
    private var playerTitle: String? = null

    private val lockOverlay = FrameLayout(context)
    private val subtitlePickerListener = object : BaseActivityEventListener() {
        override fun onActivityResult(
            activity: Activity,
            requestCode: Int,
            resultCode: Int,
            data: Intent?
        ) {
            handleSubtitlePickerResult(activity, requestCode, resultCode, data)
        }
    }

    init {
        clipChildren = false
        clipToPadding = false
        reactContext.addActivityEventListener(subtitlePickerListener)
        reactContext.addLifecycleEventListener(this)
        registerAsActivePlayerView()

        addView(textureView, LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        player.setVideoTextureView(textureView)

        setupOverlay()
        setupBufferLoader()
        setupControls()
        setupSubtitleDrawer()
        setupLockOverlay()
        setupUnlockButton()
        setupGestures()
        setupPlayer()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun resumePositionKey(uri: String) = "position_${uri.hashCode()}"

    private fun createTrackSelector(context: Context): DefaultTrackSelector {
        return DefaultTrackSelector(context).apply {
            setParameters(
                buildUponParameters()
                    .setViewportSizeToPhysicalDisplaySize(context, true)
                    .setAllowVideoMixedMimeTypeAdaptiveness(true)
                    .setAllowVideoNonSeamlessAdaptiveness(true)
                    .setExceedVideoConstraintsIfNecessary(true)
                    .build()
            )
        }
    }

    private fun createPlayer(context: Context): ExoPlayer {
        val renderersFactory =
            DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)
                .setAllowedVideoJoiningTimeMs(0)
        val loadControl =
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                    12_000,
                    60_000,
                    750,
                    2_000
                )
                .setPrioritizeTimeOverSizeThresholds(true)
                .build()
        val mediaSourceFactory =
            DefaultMediaSourceFactory(VideoCacheManager.buildCacheDataSourceFactory(context))

        return ExoPlayer.Builder(context)
            .setRenderersFactory(renderersFactory)
            .setMediaSourceFactory(mediaSourceFactory)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setSeekBackIncrementMs(10_000)
            .setSeekForwardIncrementMs(10_000)
            .setHandleAudioBecomingNoisy(true)
            .setSeekParameters(SeekParameters.CLOSEST_SYNC)
            .build()
    }

    companion object {
        private const val SUBTITLE_PICK_REQUEST = 4107
        private const val SUBDL_BASE_URL = "https://subdl.com"
        private const val SUBDL_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36"
        private const val SUBTITLE_LOG_TAG = "SubtitleDebug"
        private const val PREF_BACKGROUND_PLAY_ENABLED = "background_play_enabled"
        private const val PREF_PICTURE_IN_PICTURE_ENABLED = "picture_in_picture_enabled"
        private var pendingSubtitlePickerView: WeakReference<VideoPlayerView>? = null
        private var activePlaybackView: WeakReference<VideoPlayerView>? = null

        fun dispatchSubtitlePickerResult(
            activity: Activity,
            requestCode: Int,
            resultCode: Int,
            data: Intent?
        ): Boolean {
            val view = pendingSubtitlePickerView?.get() ?: return false
            return view.handleSubtitlePickerResult(activity, requestCode, resultCode, data)
        }

        fun dispatchUserLeaveHint(activity: Activity): Boolean {
            val view = activePlaybackView?.get() ?: return false
            return view.handleUserLeaveHint(activity)
        }

        fun dispatchPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
            activePlaybackView?.get()?.handlePictureInPictureModeChanged(isInPictureInPictureMode)
        }
    }

    private data class SubtitleSearchResult(
        val mediaTitle: String,
        val releaseName: String,
        val language: String,
        val fileName: String,
        val downloadUrl: String
    )

    private data class SubtitleMediaMatch(
        val sdId: String,
        val slug: String,
        val title: String,
        val subtitlesCount: Int
    )

    // ---------------- CONTROLS VISIBILITY ----------------

    private fun showControls() {
        controls.clearAnimation()
        controls.alpha = 1f
        controls.bringToFront()
        topBar?.bringToFront()

        controls.visibility = View.VISIBLE

        val fade = AlphaAnimation(0f, 1f)
        fade.duration = 200
        controls.startAnimation(fade)

        controlsVisible = true

        if (activeSubtitleText.isNotBlank()) {
            showSubtitleCuePopup(activeSubtitleText)
        }

        hideHandler.removeCallbacksAndMessages(null)
        hideHandler.postDelayed({ hideControls() }, 2500)
    }

    private fun clampVideoPan() {
        val contentWidth = textureView.width.takeIf { it > 0 }?.toFloat() ?: width.toFloat()
        val contentHeight = textureView.height.takeIf { it > 0 }?.toFloat() ?: height.toFloat()
        if (contentWidth <= 0f || contentHeight <= 0f) {
            videoPanX = 0f
            videoPanY = 0f
            return
        }

        val maxPanX = ((contentWidth * (videoZoomScale - 1f)) / 2f).coerceAtLeast(0f)
        val maxPanY = ((contentHeight * (videoZoomScale - 1f)) / 2f).coerceAtLeast(0f)
        videoPanX = videoPanX.coerceIn(-maxPanX, maxPanX)
        videoPanY = videoPanY.coerceIn(-maxPanY, maxPanY)
    }

    private fun applyVideoZoom() {
        textureView.pivotX = textureView.width / 2f
        textureView.pivotY = textureView.height / 2f
        textureView.scaleX = videoZoomScale
        textureView.scaleY = videoZoomScale
        textureView.translationX = videoPanX
        textureView.translationY = videoPanY
    }

    private fun currentZoomLabel(): String {
        val zoomPercent = Math.round(videoZoomScale * 100f)
        return "${zoomPercent.coerceIn(100, Math.round(maxVideoZoom * 100f))}%"
    }

    private fun showZoomIndicator(autoHideDelayMs: Long = 900L) {
        zoomIndicatorText.text = currentZoomLabel()
        zoomIndicatorText.removeCallbacks(zoomIndicatorHideRunnable)
        zoomIndicatorText.animate().cancel()
        zoomIndicatorText.bringToFront()

        if (zoomIndicatorText.visibility != View.VISIBLE) {
            zoomIndicatorText.alpha = 0f
            zoomIndicatorText.visibility = View.VISIBLE
            zoomIndicatorText.animate().alpha(1f).setDuration(120).start()
        } else {
            zoomIndicatorText.alpha = 1f
        }

        zoomIndicatorText.postDelayed(zoomIndicatorHideRunnable, autoHideDelayMs)
    }

    private fun hideZoomIndicator() {
        zoomIndicatorText.removeCallbacks(zoomIndicatorHideRunnable)
        zoomIndicatorText.animate().cancel()
        zoomIndicatorText.visibility = View.GONE
        zoomIndicatorText.alpha = 0f
    }

    private fun resetVideoZoom(showFeedback: Boolean = false) {
        videoZoomScale = minVideoZoom
        videoPanX = 0f
        videoPanY = 0f
        isZoomGestureActive = false
        isPanningZoomedVideo = false
        applyVideoZoom()
        if (showFeedback) {
            showZoomIndicator()
        } else {
            hideZoomIndicator()
        }
    }

    private fun updateVideoZoom(scale: Float, focusX: Float, focusY: Float) {
        val previousScale = videoZoomScale
        val nextScale = scale.coerceIn(minVideoZoom, maxVideoZoom)
        if (kotlin.math.abs(nextScale - previousScale) < 0.01f) return

        val contentWidth = textureView.width.takeIf { it > 0 }?.toFloat() ?: width.toFloat()
        val contentHeight = textureView.height.takeIf { it > 0 }?.toFloat() ?: height.toFloat()
        val focusOffsetX = focusX - (contentWidth / 2f)
        val focusOffsetY = focusY - (contentHeight / 2f)
        val scaleRatio = if (previousScale > 0f) nextScale / previousScale else 1f

        videoPanX = (videoPanX * scaleRatio) + ((1f - scaleRatio) * focusOffsetX)
        videoPanY = (videoPanY * scaleRatio) + ((1f - scaleRatio) * focusOffsetY)
        videoZoomScale = nextScale

        if (videoZoomScale <= minVideoZoom + 0.01f) {
            videoPanX = 0f
            videoPanY = 0f
        } else {
            clampVideoPan()
        }

        applyVideoZoom()
        showZoomIndicator()
    }

    private fun setupLockOverlay() {

    lockOverlay.layoutParams = LayoutParams(
        LayoutParams.MATCH_PARENT,
        LayoutParams.MATCH_PARENT
    )

    lockOverlay.setBackgroundColor(Color.TRANSPARENT)
    lockOverlay.visibility = View.GONE
    lockOverlay.elevation = 130f
    lockOverlay.translationZ = 130f

    lockOverlay.isClickable = true
    lockOverlay.isFocusable = true
    lockOverlay.setOnTouchListener { _, _ ->
        if (!controlsLocked) return@setOnTouchListener false
        true
    }

    addView(lockOverlay)
}

    private fun setupUnlockButton() {

    val params = FrameLayout.LayoutParams(
        dp(48),
        dp(48),
        Gravity.TOP or Gravity.END
    ).apply {
        topMargin = dp(18)
        marginEnd = dp(18)
    }

    unlockBtn.setImageResource(R.drawable.ic_unlock_overlay)
    unlockBtn.setColorFilter(buttonTintColor)
    unlockBtn.setPadding(dp(10), dp(10), dp(10), dp(10))
    unlockBtn.scaleType = ImageView.ScaleType.CENTER_INSIDE

    val bg = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.parseColor("#D91A1A1A"))
        setStroke(dp(2), buttonTintColor)
    }

    unlockBtn.background = bg
    unlockBtn.layoutParams = params
    unlockBtn.visibility = View.GONE

    unlockBtn.setOnClickListener {
        unlockControls()
    }
}

    private fun showUnlockPrompt() {
        if (!controlsLocked) return
        lockOverlay.setBackgroundColor(Color.TRANSPARENT)
        lockOverlay.visibility = View.VISIBLE
        lockOverlay.bringToFront()
        showUnlockPopup()
        if (wasPlayingWhenLocked && !player.isPlaying) {
            player.play()
            playBtn.setImageResource(R.drawable.ic_pause_player)
        }
    }

    private fun unlockControls() {
        controlsLocked = false
        showOverlay("Controls Unlocked")
        lockOverlay.setBackgroundColor(Color.TRANSPARENT)
        lockOverlay.visibility = View.GONE
        hideUnlockPopup()
        showControls()
    }

    private fun updateProgressUi() {
        if (lastDuration <= 0L) return

        val currentPosition = player.currentPosition.coerceAtLeast(0L)
        val progress = ((currentPosition * 1000) / lastDuration).toInt().coerceIn(0, seekBar.max)
        if (!isSeeking && seekBar.progress != progress) {
            seekBar.progress = progress
        }

        updateBufferedProgressUi(progress)

        val time = format(currentPosition)
        if (currentText.text != time) {
            currentText.text = time
        }

        dispatchProgressEvent()
        maybeRefreshCacheStats()
    }

    private fun updateBufferedProgressUi(progressOverride: Int? = null) {
        if (!currentSourceIsRemote || lastDuration <= 0L) {
            if (seekBar.secondaryProgress != 0) {
                seekBar.secondaryProgress = 0
            }
            return
        }

        val bufferedPositionProgress =
            ((player.bufferedPosition.coerceAtLeast(0L).coerceAtMost(lastDuration) * 1000) / lastDuration)
                .toInt()
                .coerceIn(0, seekBar.max)
        val cacheProgress = (lastKnownCacheStats.cachedPercent * 10).coerceIn(0, seekBar.max)
        val baseProgress = progressOverride ?: seekBar.progress
        val secondaryProgress = max(baseProgress, max(bufferedPositionProgress, cacheProgress))
        if (seekBar.secondaryProgress != secondaryProgress) {
            seekBar.secondaryProgress = secondaryProgress
        }
    }

    private fun maybeRefreshCacheStats(force: Boolean = false) {
        val uri = currentMediaUri ?: return
        if (!currentSourceIsRemote) return

        val now = SystemClock.uptimeMillis()
        if (!force) {
            if (isCacheStatsRefreshInFlight) return
            if (now - lastCacheStatsRefreshAtMs < 900L) return
        }

        isCacheStatsRefreshInFlight = true
        uiScope.launch(Dispatchers.IO) {
            val stats = VideoCacheManager.getCacheStats(context, uri)
            withContext(Dispatchers.Main) {
                isCacheStatsRefreshInFlight = false
                if (currentMediaUri != uri) {
                    return@withContext
                }
                lastCacheStatsRefreshAtMs = SystemClock.uptimeMillis()
                lastKnownCacheStats = stats
                updateBufferedProgressUi()
                dispatchProgressEvent(force = true)
            }
        }
    }

    private fun dispatchProgressEvent(force: Boolean = false) {
        val duration = lastDuration.takeIf { it > 0L } ?: return
        val now = SystemClock.uptimeMillis()
        if (!force && now - lastProgressEventAtMs < 500L) {
            return
        }
        lastProgressEventAtMs = now

        val currentPosition = player.currentPosition.coerceAtLeast(0L)
        val bufferedPosition = player.bufferedPosition.coerceAtLeast(0L).coerceAtMost(duration)
        val bufferedPercent =
            ((bufferedPosition * 100L) / duration).toInt().coerceIn(0, 100)
        val map = Arguments.createMap().apply {
            putDouble("currentTime", currentPosition.toDouble())
            putDouble("duration", duration.toDouble())
            putDouble("bufferedPosition", bufferedPosition.toDouble())
            putDouble(
                "bufferedDuration",
                (bufferedPosition - currentPosition).coerceAtLeast(0L).toDouble()
            )
            putInt("bufferedPercent", bufferedPercent)
            putDouble("cachedBytes", lastKnownCacheStats.cachedBytes.toDouble())
            putDouble("cacheContentLength", lastKnownCacheStats.contentLength.toDouble())
            putInt("cachePercent", lastKnownCacheStats.cachedPercent)
            putBoolean("isPlaying", player.isPlaying)
            putBoolean("isBuffering", lastPlaybackState == Player.STATE_BUFFERING)
            putBoolean("isRemote", currentSourceIsRemote)
            putString("uri", currentMediaUri)
            putInt("index", currentIndex)
        }
        sendEvent("onProgress", map)
    }

    private fun setupResumeOverlay() {
        resumeOverlay.layoutParams = LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT
        )
        resumeOverlay.setBackgroundColor(Color.parseColor("#73000000"))
        resumeOverlay.visibility = View.GONE
        resumeOverlay.isClickable = true
        resumeOverlay.isFocusable = true
        resumeOverlay.elevation = 150f
        resumeOverlay.translationZ = 150f

        resumeCard.orientation = LinearLayout.VERTICAL
        resumeCard.setPadding(dp(22), dp(22), dp(22), dp(18))
        resumeCard.background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(Color.parseColor("#F2141414"))
            setStroke(dp(1), Color.parseColor("#33FFFFFF"))
        }

        resumeTitleText.apply {
            text = "Resume Playback?"
            setTextColor(Color.WHITE)
            textSize = 20f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

        resumeMessageText.apply {
            setTextColor(Color.parseColor("#CCFFFFFF"))
            textSize = 15f
        }

        val actions = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }

        val actionTextColor = Color.parseColor("#4DD0E1")

        resumeStartOverBtn.apply {
            text = "START OVER"
            setTextColor(actionTextColor)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(dp(8), dp(12), dp(8), dp(8))
        }

        resumeContinueBtn.apply {
            text = "RESUME"
            setTextColor(actionTextColor)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(dp(18), dp(12), dp(8), dp(8))
        }

        actions.addView(resumeStartOverBtn)
        actions.addView(resumeContinueBtn)

        resumeCard.addView(
            resumeTitleText,
            LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
        )
        resumeCard.addView(
            resumeMessageText,
            LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(10)
            }
        )
        resumeCard.addView(
            actions,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(18)
            }
        )

        resumeOverlay.addView(
            resumeCard,
            LayoutParams(dp(300), LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )

        addView(resumeOverlay)
    }

    private fun savePlaybackState(force: Boolean = false) {
        if (!resumePlaybackEnabled) return
        val uri = currentMediaUri ?: return
        if (lastDuration <= 0) return

        val position = player.currentPosition.coerceAtLeast(0L)
        if (suppressResumeSaveUntilRestart) {
            if (position > 1_000L && !force) return
            suppressResumeSaveUntilRestart = false
        }
        val safeDuration = lastDuration.coerceAtLeast(0L)
        val shouldClearPosition = safeDuration > 0L && position >= safeDuration - 1_000L
        val positionToStore = if (shouldClearPosition) 0L else position
        val shouldWrite =
            force ||
                uri != lastPersistedUri ||
                kotlin.math.abs(positionToStore - lastPersistedPositionMs) >= 1_000L

        if (!shouldWrite) return

        playbackPrefs.edit().apply {
            putString("last_uri", uri)
            putInt("last_index", currentIndex)
            putLong("last_position", positionToStore)
            putLong(resumePositionKey(uri), positionToStore)
        }.apply()

        lastPersistedUri = uri
        lastPersistedPositionMs = positionToStore
    }

    private fun clearSavedPosition(uri: String) {
        playbackPrefs.edit().apply {
            putLong(resumePositionKey(uri), 0L)
            putLong("last_position", 0L)
        }.apply()
        if (lastPersistedUri == uri) {
            lastPersistedPositionMs = 0L
        }
    }

    private fun rebuildShuffledQueue(anchorIndex: Int = currentIndex) {
        shuffledQueue.clear()
        if (videoQueue.isEmpty()) {
            shuffledQueuePosition = -1
            return
        }

        val safeAnchorIndex = anchorIndex.coerceIn(0, videoQueue.lastIndex)
        shuffledQueue.add(safeAnchorIndex)
        shuffledQueue.addAll(videoQueue.indices.filter { it != safeAnchorIndex }.shuffled())
        shuffledQueuePosition = 0
    }

    private fun syncShufflePosition() {
        if (!isShuffleEnabled) return
        if (currentIndex !in videoQueue.indices) {
            shuffledQueuePosition = -1
            return
        }

        val existingPosition = shuffledQueue.indexOf(currentIndex)
        if (existingPosition >= 0) {
            shuffledQueuePosition = existingPosition
            return
        }

        rebuildShuffledQueue(currentIndex)
    }

    private fun getNextPlaybackIndex(): Int? {
        if (videoQueue.isEmpty()) return null

        if (!isShuffleEnabled) {
            return (currentIndex + 1).takeIf { it < videoQueue.size }
        }

        syncShufflePosition()
        val nextPosition = shuffledQueuePosition + 1
        return shuffledQueue.getOrNull(nextPosition)
    }

    private fun getPreviousPlaybackIndex(): Int? {
        if (videoQueue.isEmpty()) return null

        if (!isShuffleEnabled) {
            return (currentIndex - 1).takeIf { it >= 0 }
        }

        syncShufflePosition()
        val previousPosition = shuffledQueuePosition - 1
        return shuffledQueue.getOrNull(previousPosition)
    }

    private fun inferSubtitleMimeType(raw: String): String? {
        val value = raw.lowercase()
        return when {
            value.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
            value.endsWith(".vtt") -> MimeTypes.TEXT_VTT
            value.endsWith(".ssa") || value.endsWith(".ass") -> MimeTypes.TEXT_SSA
            value.endsWith(".ttml") || value.endsWith(".xml") -> MimeTypes.APPLICATION_TTML
            else -> null
        }
    }

    private fun resolveSubtitleMimeType(uri: Uri): String? {
        getDisplayNameFromUri(uri)?.let { displayName ->
            inferSubtitleMimeType(displayName)?.let { return it }
        }

        uri.lastPathSegment?.let { lastSegment ->
            inferSubtitleMimeType(Uri.decode(lastSegment))?.let { return it }
        }

        val rawMimeType = runCatching { context.contentResolver.getType(uri) }.getOrNull()?.lowercase()
        return when (rawMimeType) {
            MimeTypes.APPLICATION_SUBRIP,
            "application/srt",
            "text/srt",
            "application/x-subrip" -> MimeTypes.APPLICATION_SUBRIP

            MimeTypes.TEXT_VTT,
            "application/x-subtitle-vtt" -> MimeTypes.TEXT_VTT

            MimeTypes.TEXT_SSA,
            "text/x-ssa",
            "text/x-ass" -> MimeTypes.TEXT_SSA

            MimeTypes.APPLICATION_TTML,
            "application/xml",
            "text/xml" -> MimeTypes.APPLICATION_TTML

            else -> null
        }
    }

    private fun rebuildMediaItemWithCurrentSubtitle(): MediaItem? {
        val uri = currentMediaUri ?: return null
        val builder = MediaItem.Builder().setUri(Uri.parse(uri))

        val subtitleUri = selectedSubtitleUri
        Log.d(SUBTITLE_LOG_TAG, "rebuild_media subtitleUri=$subtitleUri enabled=$subtitlePlaybackEnabled mime=$selectedSubtitleMimeType")
        if (subtitlePlaybackEnabled && subtitleUri != null) {
            val subtitleBuilder = MediaItem.SubtitleConfiguration.Builder(subtitleUri)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                .setLabel(subtitleLabelForUri(subtitleUri))

            selectedSubtitleMimeType?.let { subtitleBuilder.setMimeType(it) }
            builder.setSubtitleConfigurations(listOf(subtitleBuilder.build()))
        }

        return builder.build()
    }

    private fun refreshMediaItemPreservingState() {
        val item = rebuildMediaItemWithCurrentSubtitle() ?: return
        val position = player.currentPosition
        val shouldPlay = player.isPlaying || player.playWhenReady

        player.setMediaItem(item, position)
        player.prepare()
        if (shouldPlay) {
            player.play()
            playBtn.setImageResource(R.drawable.ic_pause_player)
        } else {
            player.pause()
            playBtn.setImageResource(R.drawable.ic_play_arrow_player)
        }
    }

    private fun applySubtitle(uri: Uri, mimeType: String?) {
        Log.d(
            SUBTITLE_LOG_TAG,
            "apply_subtitle uri=$uri mimeType=$mimeType currentMediaUri=$currentMediaUri"
        )
        selectedSubtitleUri = uri
        selectedSubtitleMimeType = mimeType
        userDisabledSubtitles = false
        subtitlePlaybackEnabled = true
        setSubtitlePlaybackEnabled(true)
        showOverlay("Subtitles Loaded")
    }

    private fun clearSubtitle() {
        Log.d(SUBTITLE_LOG_TAG, "clear_subtitle")
        selectedSubtitleUri = null
        selectedSubtitleMimeType = null
        refreshMediaItemPreservingState()
        updateSubtitleRendererVisibility()
        updateSubtitleButtonStyle()
        updateSubtitleDrawerUi()
        showOverlay("Subtitles Removed")
    }

    private fun openSubtitlePicker() {
        val activity = reactContext.currentActivity ?: return
        closeSubtitleDrawer()
        subtitleDrawerDialog?.dismiss()

        val initialUri = buildSubtitlePickerInitialUri()
        isAwaitingSubtitlePickerResult = true
        suppressAutoPictureInPictureUntilResume = true
        pendingSubtitlePickerView = WeakReference(this)
        Log.d(
            SUBTITLE_LOG_TAG,
            "open_picker currentMediaUri=$currentMediaUri initialUri=$initialUri"
        )

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                initialUri?.let { uri ->
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                }
            }
        }
        try {
            activity.startActivityForResult(intent, SUBTITLE_PICK_REQUEST)
        } catch (_: Exception) {
            isAwaitingSubtitlePickerResult = false
            if (pendingSubtitlePickerView?.get() === this) {
                pendingSubtitlePickerView = null
            }
            showOverlay("Unable to open subtitle picker")
        }
    }

    private fun buildSubtitlePickerInitialUri(): Uri? {
        val uriString = currentMediaUri ?: return null
        val parsed = Uri.parse(uriString)

        val folderPath = when (parsed.scheme) {
            ContentResolver.SCHEME_FILE -> {
                parsed.path?.let { path -> File(path).parentFile?.absolutePath }
            }

            else -> resolveCurrentMediaFolderPath(parsed)
        } ?: return null

        return buildExternalStorageDocumentUri(folderPath)
    }

    private fun resolveCurrentMediaFolderPath(uri: Uri): String? {
        return try {
            val projection =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    arrayOf(MediaStore.MediaColumns.RELATIVE_PATH)
                } else {
                    @Suppress("DEPRECATION")
                    arrayOf(MediaStore.MediaColumns.DATA)
                }

            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return null

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getString(0)?.trim()?.trim('/')
                } else {
                    cursor.getString(0)?.let { absolutePath ->
                        File(absolutePath).parentFile?.absolutePath
                    }
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun buildExternalStorageDocumentUri(rawPath: String): Uri? {
        val normalizedPath = rawPath
            .trim()
            .trim('/')
            .removePrefix("/storage/emulated/0/")
            .removePrefix("storage/emulated/0/")
            .removePrefix("/sdcard/")
            .removePrefix("sdcard/")
            .removePrefix("primary:")
            .trim('/')

        val documentId =
            if (normalizedPath.isBlank()) {
                "primary"
            } else {
                "primary:$normalizedPath"
            }

        return runCatching {
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                documentId
            )
        }.getOrNull()
    }

    private fun getDisplayNameFromUri(uri: Uri): String? {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            return uri.lastPathSegment?.let { Uri.decode(it) }
        }

        val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
        val queriedName = try {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx < 0) return null
                cursor.getString(idx)
            }
        } catch (_: Exception) {
            null
        }

        if (!queriedName.isNullOrBlank()) {
            return queriedName
        }

        return runCatching {
            DocumentsContract.getDocumentId(uri)
                .substringAfterLast(':')
                .substringAfterLast('/')
                .takeIf { it.isNotBlank() }
        }.getOrNull() ?: uri.lastPathSegment?.let { Uri.decode(it) }
    }

    private fun buildSubtitleSearchQuery(): String {
        val currentUri = currentMediaUri
        if (currentUri.isNullOrBlank()) return ""

        val parsed = Uri.parse(currentUri)
        val lastSegment = parsed.lastPathSegment?.let { Uri.decode(it) }.orEmpty()
        if (lastSegment.isBlank()) return ""

        val nameToUse = if (lastSegment.all { it.isDigit() }) {
            getDisplayNameFromUri(parsed)?.let { Uri.decode(it) } ?: lastSegment
        } else {
            lastSegment
        }

        val dotIndex = nameToUse.lastIndexOf('.')
        val baseName = if (dotIndex > 0) nameToUse.substring(0, dotIndex) else nameToUse
        return baseName.replace('_', ' ').replace('.', ' ').trim()
    }

    private fun handleSubtitlePickerResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ): Boolean {
        if (requestCode != SUBTITLE_PICK_REQUEST) return false
        if (!isAwaitingSubtitlePickerResult && pendingSubtitlePickerView?.get() !== this) return false

        isAwaitingSubtitlePickerResult = false
        if (pendingSubtitlePickerView?.get() === this) {
            pendingSubtitlePickerView = null
        }

        Log.d(
            SUBTITLE_LOG_TAG,
            "activity_result resultCode=$resultCode dataUri=${data?.data}"
        )

        if (resultCode != Activity.RESULT_OK) {
            return true
        }

        val uri = data?.data ?: return true
        val takeFlags =
            data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                takeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {
        }

        val mimeType = resolveSubtitleMimeType(uri)
        Log.d(
            SUBTITLE_LOG_TAG,
            "picker_result uri=$uri displayName=${getDisplayNameFromUri(uri)} mime=$mimeType"
        )
        if (mimeType == null) {
            showOverlay("Unsupported subtitle file")
            return true
        }

        applySubtitle(uri, mimeType)
        return true
    }

    private fun beginSubtitleMenuSession() {
        if (subtitleMenuOpenCount == 0) {
            wasPlayingBeforeSubtitleMenu = player.isPlaying
            if (wasPlayingBeforeSubtitleMenu) {
                player.pause()
                playBtn.setImageResource(R.drawable.ic_play_arrow_player)
            }
        }
        subtitleMenuOpenCount++
    }

    private fun endSubtitleMenuSession() {
        subtitleMenuOpenCount = (subtitleMenuOpenCount - 1).coerceAtLeast(0)
        if (subtitleMenuOpenCount == 0 && wasPlayingBeforeSubtitleMenu) {
            wasPlayingBeforeSubtitleMenu = false
            player.play()
            playBtn.setImageResource(R.drawable.ic_pause_player)
        }
    }

    private fun showOnlineSubtitleSearchDialog() {
        beginSubtitleMenuSession()
        closeSubtitleDrawer()
        subtitleDrawerDialog?.dismiss()
        subtitleSearchDialog?.dismiss()

        val dialog = Dialog(context, android.R.style.Theme_Translucent_NoTitleBar_Fullscreen)
        subtitleSearchDialog = dialog

        val overlay = FrameLayout(context).apply {
            setBackgroundColor(Color.parseColor("#66000000"))
            setOnClickListener { dialog.dismiss() }
        }

        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F014181B"))
            }
            setPadding(dp(16), dp(16), dp(16), dp(16))
            setOnClickListener { }
        }

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val title = TextView(context).apply {
            text = "Online subtitles"
            setTextColor(Color.WHITE)
            textSize = 20f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }

        val closeBtn = TextView(context).apply {
            text = "CLOSE"
            setTextColor(Color.parseColor("#6DB7FF"))
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setOnClickListener { dialog.dismiss() }
        }

        header.addView(title)
        header.addView(closeBtn)

        val searchRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val input = EditText(context).apply {
            hint = "Search any subtitle"
            setText(buildSubtitleSearchQuery())
            setSelection(text.length)
            setTextColor(Color.WHITE)
            setHintTextColor(Color.parseColor("#88FFFFFF"))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#22111111"))
                setStroke(dp(1), Color.parseColor("#33FFFFFF"))
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }

        val searchBtn = TextView(context).apply {
            text = "SEARCH"
            setTextColor(Color.parseColor("#6DB7FF"))
            textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#1E2B36"))
                setStroke(dp(1), Color.parseColor("#336DB7FF"))
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }

        searchRow.addView(input)
        searchRow.addView(
            searchBtn,
            LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(10)
            }
        )

        val helperText = TextView(context).apply {
            text = "Search by any name, episode, language, or keyword."
            setTextColor(Color.parseColor("#AAFFFFFF"))
            textSize = 13f
            setPadding(0, dp(10), 0, dp(10))
        }

        val progressBar = ProgressBar(context).apply {
            visibility = View.GONE
        }

        val statusText = TextView(context).apply {
            text = "Enter a search and press Search."
            setTextColor(Color.parseColor("#CCFFFFFF"))
            textSize = 14f
            setPadding(0, dp(6), 0, dp(10))
        }

        val resultScroller = ScrollView(context).apply {
            isFillViewport = true
        }
        val resultList = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        resultScroller.addView(
            resultList,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val renderResults = { results: List<SubtitleSearchResult> ->
            resultList.removeAllViews()
            results.forEachIndexed { index, result ->
                val row = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    background = GradientDrawable().apply {
                        cornerRadius = dp(12).toFloat()
                        setColor(Color.parseColor("#161D22"))
                        setStroke(dp(1), Color.parseColor("#223B4A"))
                    }
                    setPadding(dp(14), dp(14), dp(14), dp(14))
                    setOnClickListener {
                        uiScope.launch {
                            progressBar.visibility = View.VISIBLE
                            statusText.text = "Downloading ${result.fileName}..."
                            val downloaded = runCatching { downloadSubtitleFile(result) }.getOrNull()
                            progressBar.visibility = View.GONE
                            if (downloaded != null) {
                                dialog.dismiss()
                                applySubtitle(Uri.fromFile(downloaded), inferSubtitleMimeType(downloaded.name))
                            } else {
                                statusText.text = "Unable to download subtitle."
                            }
                        }
                    }
                }

                val name = TextView(context).apply {
                    text = result.releaseName
                    setTextColor(Color.WHITE)
                    textSize = 16f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                }

                val meta = TextView(context).apply {
                    text = "${result.mediaTitle} • ${result.language} • ${result.fileName}"
                    setTextColor(Color.parseColor("#AFFFFFFF"))
                    textSize = 13f
                    maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    setPadding(0, dp(6), 0, 0)
                }

                val action = TextView(context).apply {
                    text = "DOWNLOAD"
                    setTextColor(Color.parseColor("#6DB7FF"))
                    textSize = 13f
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    setPadding(0, dp(10), 0, 0)
                }

                row.addView(name)
                row.addView(meta)
                row.addView(action)
                resultList.addView(
                    row,
                    LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                        if (index > 0) topMargin = dp(10)
                    }
                )
            }
        }

        val searchAction = {
            val query = input.text?.toString()?.trim().orEmpty()
            if (query.isEmpty()) {
                showOverlay("Enter search text")
            } else {
                uiScope.launch {
                    progressBar.visibility = View.VISIBLE
                    statusText.text = "Searching Subdl..."
                    val results = runCatching { searchSubtitles(query) }.getOrElse { emptyList() }
                    progressBar.visibility = View.GONE
                    if (results.isEmpty()) {
                        statusText.text = "No subtitles found"
                        resultList.removeAllViews()
                    } else {
                        statusText.text = "${results.size} subtitles found. Tap one to download."
                        renderResults(results)
                    }
                }
            }
        }

        searchBtn.setOnClickListener { searchAction() }
        input.setOnEditorActionListener { _, _, _ ->
            searchAction()
            true
        }

        panel.addView(header)
        panel.addView(
            searchRow,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(16)
            }
        )
        panel.addView(helperText)
        panel.addView(progressBar)
        panel.addView(statusText)
        panel.addView(
            resultScroller,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f)
        )

        overlay.addView(
            panel,
            FrameLayout.LayoutParams(dp(360), LayoutParams.MATCH_PARENT, Gravity.END)
        )

        dialog.setContentView(overlay)
        dialog.window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setLayout(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
            setGravity(Gravity.END)
        }
        dialog.setOnDismissListener {
            subtitleSearchDialog = null
            endSubtitleMenuSession()
        }
        dialog.show()

        val initialQuery = input.text?.toString()?.trim().orEmpty()
        if (initialQuery.isNotEmpty()) {
            searchAction()
        }
    }

    private suspend fun searchSubtitles(query: String): List<SubtitleSearchResult> =
        withContext(Dispatchers.IO) {
            val matches = searchSubdlMatches(query)
            val results = mutableListOf<SubtitleSearchResult>()
            val seenUrls = mutableSetOf<String>()

            for (match in matches) {
                if (match.subtitlesCount <= 0) continue
                val detailResults = fetchSubdlSubtitleResults(match)
                for (result in detailResults) {
                    if (seenUrls.add(result.downloadUrl)) {
                        results.add(result)
                    }
                    if (results.size >= 50) break
                }
                if (results.size >= 50) break
            }

            results
        }

    private suspend fun downloadSubtitleFile(result: SubtitleSearchResult): File =
        withContext(Dispatchers.IO) {
            val subtitleDir = File(context.getExternalFilesDir(null), "subtitles").apply {
                mkdirs()
            }
            val fileConnection = (URL(result.downloadUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("User-Agent", SUBDL_USER_AGENT)
                connectTimeout = 15000
                readTimeout = 15000
            }

            try {
                fileConnection.inputStream.use { input ->
                    val downloadedZip = File(subtitleDir, result.fileName.ifBlank { "subtitle.zip" })
                    FileOutputStream(downloadedZip).use { output -> input.copyTo(output) }
                    extractSubtitleFile(downloadedZip, subtitleDir)
                }
            } finally {
                fileConnection.disconnect()
            }
        }

    private fun searchSubdlMatches(query: String): List<SubtitleMediaMatch> {
        val encodedQuery = Uri.encode(query.trim())
        val payload = fetchSubdlPageProps("$SUBDL_BASE_URL/search/$encodedQuery") ?: return emptyList()
        val list = payload.optJSONArray("list") ?: return emptyList()
        val matches = mutableListOf<SubtitleMediaMatch>()

        for (i in 0 until list.length()) {
            val item = list.optJSONObject(i) ?: continue
            matches.add(
                SubtitleMediaMatch(
                    sdId = item.optString("sd_id"),
                    slug = item.optString("slug"),
                    title = item.optString("name"),
                    subtitlesCount = item.optInt("subtitles_count", 0)
                )
            )
        }

        return matches
    }

    private fun fetchSubdlSubtitleResults(match: SubtitleMediaMatch): List<SubtitleSearchResult> {
        val payload =
            fetchSubdlPageProps("$SUBDL_BASE_URL/subtitle/${match.sdId}/${match.slug}") ?: return emptyList()
        val subtitles = payload.optJSONObject("subtitles") ?: return emptyList()
        val results = mutableListOf<SubtitleSearchResult>()

        val languageKeys = subtitles.keys()
        while (languageKeys.hasNext()) {
            val languageKey = languageKeys.next()
            val qualities = subtitles.optJSONObject(languageKey) ?: continue
            val qualityKeys = qualities.keys()

            while (qualityKeys.hasNext()) {
                val qualityKey = qualityKeys.next()
                val qualityGroup = qualities.optJSONObject(qualityKey) ?: continue
                val subs = qualityGroup.optJSONArray("subs") ?: continue

                for (i in 0 until subs.length()) {
                    val sub = subs.optJSONObject(i) ?: continue
                    val link = sub.optString("link")
                    if (link.isBlank()) continue

                    val releaseName = sub.optString("title").ifBlank { match.title }
                    val fileName = "${releaseName.take(80).replace(Regex("[^A-Za-z0-9._ -]"), "_")}.zip"
                    val language = sub.optString("language").ifBlank { languageKey.replace('-', ' ') }
                    val downloadUrl =
                        if (link.startsWith("http")) link else "https://dl.subdl.com/subtitle/$link"

                    results.add(
                        SubtitleSearchResult(
                            mediaTitle = match.title,
                            releaseName = releaseName,
                            language = language,
                            fileName = fileName,
                            downloadUrl = downloadUrl
                        )
                    )
                }
            }
        }

        return results
    }

    private fun fetchSubdlPageProps(url: String): JSONObject? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("User-Agent", SUBDL_USER_AGENT)
            setRequestProperty("Accept", "text/html,application/xhtml+xml")
            connectTimeout = 15000
            readTimeout = 15000
        }

        return try {
            val html = connection.inputStream.bufferedReader().use { it.readText() }
            val json =
                Regex("""<script id="__NEXT_DATA__" type="application/json">(.*?)</script>""")
                    .find(html)
                    ?.groupValues
                    ?.getOrNull(1)
                    ?: return null
            JSONObject(json).optJSONObject("props")?.optJSONObject("pageProps")
        } finally {
            connection.disconnect()
        }
    }

    private fun extractSubtitleFile(zipFile: File, outputDir: File): File {
        ZipInputStream(zipFile.inputStream().buffered()).use { zipInput ->
            var entry = zipInput.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    val entryName = entry.name.substringAfterLast('/')
                    val mimeType = inferSubtitleMimeType(entryName)
                    if (mimeType != null) {
                        val targetFile = File(outputDir, entryName.ifBlank { "subtitle.srt" })
                        FileOutputStream(targetFile).use { output -> zipInput.copyTo(output) }
                        zipInput.closeEntry()
                        zipFile.delete()
                        return targetFile
                    }
                }
                zipInput.closeEntry()
                entry = zipInput.nextEntry
            }
        }

        zipFile.delete()
        throw IllegalStateException("No subtitle file found in zip")
    }

    private fun showSubtitleUrlDialog() {
        closeSubtitleDrawer()
        subtitleDrawerDialog?.dismiss()
        val input = EditText(context).apply {
            hint = "https://example.com/subtitles.srt"
            setTextColor(Color.WHITE)
            setHintTextColor(Color.parseColor("#88FFFFFF"))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#22111111"))
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }

        AlertDialog.Builder(context)
            .setTitle("Subtitle URL")
            .setView(input)
            .setPositiveButton("Load") { _, _ ->
                val value = input.text?.toString()?.trim().orEmpty()
                if (value.isNotEmpty()) {
                    applySubtitle(Uri.parse(value), inferSubtitleMimeType(value))
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showSubtitleOptions() {
        showSubtitleDrawerDialog()
    }

    private fun showSubtitleDrawerDialog() {
        subtitleDrawerDialog?.dismiss()
        beginSubtitleMenuSession()
        Log.d(
            SUBTITLE_LOG_TAG,
            "show_dialog selectedUri=$selectedSubtitleUri enabled=$subtitlePlaybackEnabled hasEmbedded=$hasEmbeddedSubtitles"
        )

        val dialog = Dialog(context, android.R.style.Theme_Translucent_NoTitleBar_Fullscreen)
        subtitleDrawerDialog = dialog

        val overlay = FrameLayout(context).apply {
            setBackgroundColor(Color.parseColor("#66000000"))
            setOnClickListener { dialog.dismiss() }
        }

        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F014181B"))
            }
            setOnClickListener { }
        }

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val title = TextView(context).apply {
            text = "Subtitle"
            setTextColor(Color.WHITE)
            textSize = 22f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }

        val onlineBtn = TextView(context).apply {
            text = "Online subtitles"
            setTextColor(Color.WHITE)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setOnClickListener {
                dialog.dismiss()
                showOnlineSubtitleSearchDialog()
            }
        }

        header.addView(title)
        header.addView(onlineBtn)

        panel.addView(header)

        val selectedSubtitle = selectedSubtitleUri
        if (selectedSubtitle != null) {
            val selectedCard = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(16), dp(16), dp(16))
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat()
                    setColor(Color.parseColor("#1CFFFFFF"))
                    setStroke(dp(1), Color.parseColor("#55FFFFFF"))
                }
            }

            val check = CheckBox(context).apply {
                buttonTintList = ColorStateList.valueOf(subtitleCheckboxColor)
                isClickable = false
                isFocusable = false
                isDuplicateParentStateEnabled = false
                setPadding(0, 0, dp(6), 0)
                layoutParams = LinearLayout.LayoutParams(dp(24), dp(24))
                scaleX = 1.1f
                scaleY = 1.1f
                minWidth = 0
                minimumWidth = 0
                includeFontPadding = false
            }

            val textWrap = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
            }

            val name = TextView(context).apply {
                text = subtitleLabelForUri(selectedSubtitle)
                setTextColor(Color.WHITE)
                textSize = 16f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                maxLines = 2
                ellipsize = android.text.TextUtils.TruncateAt.END
            }

            val meta = TextView(context).apply {
                text = ""
                textSize = 14f
                setPadding(0, dp(6), 0, 0)
            }

            val syncSelectedCardUi = {
                val subtitleEnabled = subtitlePlaybackEnabled
                check.isChecked = subtitleEnabled
                meta.text = if (subtitleEnabled) "Selected subtitle is on" else "Selected subtitle is off"
                meta.setTextColor(currentSubtitleDescriptionColor(subtitleEnabled))
                (selectedCard.background as? GradientDrawable)?.apply {
                    setColor(
                        if (subtitleEnabled) {
                            Color.parseColor("#1CFFFFFF")
                        } else {
                            Color.parseColor("#14111111")
                        }
                    )
                    setStroke(
                        dp(1),
                        if (subtitleEnabled) {
                            Color.parseColor("#55FFFFFF")
                        } else {
                            Color.parseColor("#33FFFFFF")
                        }
                    )
                }
            }

            selectedCard.isClickable = true
            selectedCard.isFocusable = true
            selectedCard.setOnClickListener {
                setSubtitlePlaybackEnabled(!subtitlePlaybackEnabled)
                syncSelectedCardUi()
            }

            textWrap.addView(name)
            textWrap.addView(meta)
            selectedCard.addView(check)
            selectedCard.addView(
                textWrap,
                LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginStart = dp(14)
                }
            )
            panel.addView(
                selectedCard,
                LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                    topMargin = dp(28)
                }
            )
            syncSelectedCardUi()
        } else {
            panel.addView(
                TextView(context).apply {
                    text = "No subtitles loaded yet."
                    setTextColor(Color.parseColor("#AFFFFFFF"))
                    textSize = 15f
                    setPadding(0, dp(28), 0, dp(12))
                }
            )
        }

        panel.addView(
            createSubtitleDrawerRow(R.drawable.ic_upload, "Open") {
                dialog.dismiss()
                openSubtitlePicker()
            },
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(16)
            }
        )
        panel.addView(
            createSubtitleDrawerRow(R.drawable.ic_link, "Load from URL") {
                dialog.dismiss()
                showSubtitleUrlDialog()
            }
        )

        if (selectedSubtitle != null) {
            panel.addView(
                createSubtitleDrawerRow(R.drawable.ic_delete, "Remove subtitles") {
                    dialog.dismiss()
                    clearSubtitle()
                }
            )
        }

        overlay.addView(
            panel,
            FrameLayout.LayoutParams(dp(320), LayoutParams.MATCH_PARENT, Gravity.END)
        )

        dialog.setContentView(overlay)
        dialog.window?.apply {
            setBackgroundDrawableResource(android.R.color.transparent)
            setLayout(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
            setGravity(Gravity.END)
        }
        dialog.setOnDismissListener {
            subtitleDrawerDialog = null
            endSubtitleMenuSession()
        }
        updateSubtitleDrawerUi()
        dialog.show()
    }

    private fun updateSubtitleButtonStyle() {
        val subtitlesActive = subtitlePlaybackEnabled && (selectedSubtitleUri != null || hasEmbeddedSubtitles)
        subtitleBtn.setTextColor(if (subtitlesActive) Color.GREEN else Color.WHITE)
        subtitleBtn.background = createTopToolBackground(subtitlesActive)
    }

    private fun topToolButtonSize(): Int = if (isVideoVertical) dp(30) else dp(40)

    private fun topToolInset(): Int = if (isVideoVertical) dp(4) else dp(7)

    private fun createTopToolBackground(active: Boolean = false): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = if (isVideoVertical) dp(10).toFloat() else dp(14).toFloat()
            setColor(
                if (active) Color.parseColor("#33101010")
                else Color.parseColor("#2A000000")
            )
            setStroke(
                dp(1),
                if (active) Color.parseColor("#5500FF66")
                else Color.parseColor("#26FFFFFF")
            )
        }
    }

    private fun applyTopToolIconStyle(button: ImageView) {
        val inset = topToolInset()
        button.scaleType = ImageView.ScaleType.CENTER_INSIDE
        button.setPadding(inset, inset, inset, inset)
        button.background = createTopToolBackground()
    }

    private fun refreshButtonTintUi() {
        rewindBtn.setColorFilter(buttonTintColor)
        playBtn.setColorFilter(buttonTintColor)
        forwardBtn.setColorFilter(buttonTintColor)

        resumeBannerStartOverLabel.setTextColor(buttonTintColor)
        backBtn.setColorFilter(buttonTintColor)
        screenshotBtn.setColorFilter(buttonTintColor)
        lockBtn.setColorFilter(buttonTintColor)
        speedBtn.setTextColor(buttonTintColor)
        if (!isLooping) {
            loopBtn.setColorFilter(buttonTintColor)
        }
        if (!isShuffleEnabled) {
            shuffleBtn.setColorFilter(buttonTintColor)
        }
        updateBackgroundPlayButtonStyle()
        updateSettingsButtonStyle()
    }

    private fun subtitleLabelForUri(uri: Uri?): String {
        if (uri == null) return "No subtitle selected"
        getDisplayNameFromUri(uri)?.takeIf { it.isNotBlank() }?.let { return it }
        val direct = uri.lastPathSegment?.let { Uri.decode(it) }.orEmpty()
        if (direct.isNotBlank()) return direct
        return uri.toString().substringAfterLast('/').substringBefore('?').ifBlank { uri.toString() }
    }

    private fun withColorAlpha(color: Int, alphaFraction: Float): Int {
        val alpha = (Color.alpha(color) * alphaFraction).toInt().coerceIn(0, 255)
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
    }

    private fun currentSubtitleDescriptionColor(active: Boolean): Int {
        return if (active) subtitleDescriptionColor else withColorAlpha(subtitleDescriptionColor, 0.68f)
    }

    private fun registerAsActivePlayerView() {
        activePlaybackView = WeakReference(this)
    }

    private fun persistPlaybackFeatureSettings() {
        playbackPrefs.edit().apply {
            putBoolean(PREF_BACKGROUND_PLAY_ENABLED, backgroundPlayEnabled)
            putBoolean(PREF_PICTURE_IN_PICTURE_ENABLED, pictureInPictureEnabled)
        }.apply()
    }

    private fun updateBackgroundPlayButtonStyle() {
        backgroundPlayBtn.setColorFilter(if (backgroundPlayEnabled) Color.GREEN else buttonTintColor)
    }

    private fun updateSettingsButtonStyle() {
        settingsBtn.setColorFilter(if (pictureInPictureEnabled) Color.GREEN else buttonTintColor)
    }

    private fun toggleBackgroundPlay() {
        backgroundPlayEnabled = !backgroundPlayEnabled
        persistPlaybackFeatureSettings()
        updateBackgroundPlayButtonStyle()
        showOverlay(if (backgroundPlayEnabled) "Background Play On" else "Background Play Off")
    }

    private fun showPlaybackSettingsDialog() {
        val initialPip = pictureInPictureEnabled
        val options = arrayOf("Picture in Picture")
        val checked = booleanArrayOf(pictureInPictureEnabled)

        AlertDialog.Builder(context)
            .setTitle("Playback Settings")
            .setMultiChoiceItems(options, checked) { _, which, isChecked ->
                if (which == 0) {
                    pictureInPictureEnabled = isChecked
                }
            }
            .setPositiveButton("Done") { _, _ ->
                persistPlaybackFeatureSettings()
                updateSettingsButtonStyle()
                showOverlay(if (pictureInPictureEnabled) "PiP On" else "PiP Off")
            }
            .setNegativeButton("Cancel") { _, _ ->
                pictureInPictureEnabled = initialPip
                updateSettingsButtonStyle()
            }
            .show()
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        val videoSize = player.videoSize
        if (videoSize.width > 0 && videoSize.height > 0) {
            builder.setAspectRatio(Rational(videoSize.width, videoSize.height))
        }
        return builder.build()
    }

    private fun canEnterPictureInPicture(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return false
        if (!pictureInPictureEnabled) return false
        if (suppressAutoPictureInPictureUntilResume) return false
        if (currentMediaUri.isNullOrBlank()) return false
        if (activity.isFinishing) return false
        if (activity.isDestroyed) return false
        if (player.currentMediaItem == null) return false
        if (player.playbackState == Player.STATE_IDLE) return false
        if (player.playbackState == Player.STATE_ENDED) return false
        return true
    }

    private fun handleUserLeaveHint(activity: Activity): Boolean {
        registerAsActivePlayerView()
        if (!canEnterPictureInPicture(activity)) return false

        return try {
            enteredPictureInPictureFromLeaveHint = activity.enterPictureInPictureMode(buildPictureInPictureParams())
            enteredPictureInPictureFromLeaveHint
        } catch (_: Exception) {
            false
        }
    }

    private fun handlePictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        this.isInPictureInPictureMode = isInPictureInPictureMode
        if (isInPictureInPictureMode) {
            resetVideoZoom()
            pendingPictureInPictureUiRestore = false
            hideControls()
            subtitleDrawerDialog?.dismiss()
            subtitleSearchDialog?.dismiss()
            hideSubtitleCuePopup()
            autoPausedForBackground = false
        } else {
            player.pause()
            playBtn.setImageResource(R.drawable.ic_play_arrow_player)
            enteredPictureInPictureFromLeaveHint = false
            autoPausedForBackground = false
            pendingPictureInPictureUiRestore = true
            restoreUiAfterPictureInPicture()
        }
    }

    private fun restoreUiAfterPictureInPicture() {
        if (isInPictureInPictureMode) return

        post {
            if (isInPictureInPictureMode || !isAttachedToWindow) return@post

            pendingPictureInPictureUiRestore = false
            refreshPlaybackChrome(showControlsAfterRefresh = true)
        }
    }

    private fun refreshPlaybackChrome(showControlsAfterRefresh: Boolean) {
        registerAsActivePlayerView()

        if (currentIndex in videoQueue.indices) {
            updateDisplayedTitle(videoQueue[currentIndex])
        } else {
            fileNameText.text = playerTitle ?: "Now Playing"
        }

        controls.clearAnimation()
        controls.alpha = 1f
        controls.bringToFront()
        topBar?.clearAnimation()
        topBar?.alpha = 1f
        topBar?.bringToFront()
        updateControlsToolVisibility()
        bringGestureUiToFront()

        if (controlsLocked) {
            showUnlockPrompt()
        } else if (showControlsAfterRefresh && !isInPictureInPictureMode) {
            controlsVisible = false
            showControls()
        }

        if (activeSubtitleText.isNotBlank()) {
            showSubtitleCuePopup(activeSubtitleText)
        } else {
            hideSubtitleCuePopup()
        }

        controls.requestLayout()
        controls.invalidate()
        requestLayout()
        invalidate()
    }

    override fun onHostResume() {
        suppressAutoPictureInPictureUntilResume = false
        isAwaitingSubtitlePickerResult = false
        enteredPictureInPictureFromLeaveHint = false
        autoPausedForBackground = false
        registerAsActivePlayerView()
        if (pendingPictureInPictureUiRestore) {
            restoreUiAfterPictureInPicture()
        }
    }

    override fun onHostPause() {
        if (isInPictureInPictureMode || enteredPictureInPictureFromLeaveHint) {
            autoPausedForBackground = false
            return
        }
        if (isAwaitingSubtitlePickerResult || suppressAutoPictureInPictureUntilResume) {
            return
        }
        if (backgroundPlayEnabled) {
            autoPausedForBackground = false
            return
        }
        if (player.isPlaying) {
            player.pause()
            playBtn.setImageResource(R.drawable.ic_play_arrow_player)
            autoPausedForBackground = true
        } else {
            autoPausedForBackground = false
        }
    }

    override fun onHostDestroy() = Unit

    private fun createSubtitleDrawerRow(
        iconRes: Int,
        label: String,
        onClick: () -> Unit
    ): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.TRANSPARENT)
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setOnClickListener { onClick() }
        }

        val icon = ImageView(context).apply {
            setImageResource(iconRes)
            setColorFilter(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(dp(20), dp(20))
        }

        val text = TextView(context).apply {
            this.text = label
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(dp(16), 0, 0, 0)
        }

        row.addView(icon)
        row.addView(text)
        return row
    }

    private fun createSubtitleToggleRow(onClick: () -> Unit): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.TRANSPARENT)
            }
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setOnClickListener {
                if (!isEnabled) return@setOnClickListener
                onClick()
            }
        }

        val icon = ImageView(context).apply {
            setImageResource(R.drawable.ic_subtitles)
            setColorFilter(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(dp(20), dp(20))
        }

        val text = TextView(context).apply {
            tag = "subtitleToggleText"
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(dp(16), 0, 0, 0)
        }

        row.addView(icon)
        row.addView(text)
        return row
    }

    private fun setupSubtitleDrawer() {
        subtitleDrawerOverlay.layoutParams = LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT
        )
        subtitleDrawerOverlay.setBackgroundColor(Color.parseColor("#66000000"))
        subtitleDrawerOverlay.visibility = View.GONE
        subtitleDrawerOverlay.alpha = 0f
        subtitleDrawerOverlay.elevation = 120f
        subtitleDrawerOverlay.translationZ = 120f
        subtitleDrawerOverlay.isClickable = true
        subtitleDrawerOverlay.isFocusable = true
        subtitleDrawerOverlay.setOnTouchListener { _, event ->
            if (event.action != MotionEvent.ACTION_DOWN) return@setOnTouchListener true
            if (SystemClock.uptimeMillis() - subtitleDrawerOpenedAtMs < 180L) return@setOnTouchListener true

            val panelLeft = subtitleDrawerPanel.left.toFloat()
            val panelTop = subtitleDrawerPanel.top.toFloat()
            val panelRight = subtitleDrawerPanel.right.toFloat()
            val panelBottom = subtitleDrawerPanel.bottom.toFloat()
            val insidePanel =
                event.x in panelLeft..panelRight &&
                    event.y in panelTop..panelBottom

            if (!insidePanel) {
                closeSubtitleDrawer()
            }
            true
        }

        subtitleDrawerPanel.apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F014181B"))
            }
            setOnClickListener { }
        }

        val panelParams = LayoutParams(
            dp(320),
            LayoutParams.MATCH_PARENT,
            Gravity.END
        )

        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        subtitleDrawerTitle.apply {
            text = "Subtitle"
            setTextColor(Color.WHITE)
            textSize = 22f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }

        subtitleDrawerOnlineBtn.apply {
            text = "Online subtitles"
            setTextColor(Color.WHITE)
            textSize = 14f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setOnClickListener { showOnlineSubtitleSearchDialog() }
        }

        header.addView(subtitleDrawerTitle)
        header.addView(subtitleDrawerOnlineBtn)

        subtitleSelectedCard.apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(Color.parseColor("#1CFFFFFF"))
                setStroke(dp(1), Color.parseColor("#55FFFFFF"))
            }
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (selectedSubtitleUri != null) {
                    setSubtitlePlaybackEnabled(!subtitlePlaybackEnabled)
                }
            }
        }

        subtitleSelectedCheck.apply {
            buttonTintList = ColorStateList.valueOf(subtitleCheckboxColor)
            isClickable = false
            isFocusable = false
            isDuplicateParentStateEnabled = false
            setPadding(0, 0, dp(6), 0)
            minWidth = 0
            minimumWidth = 0
            includeFontPadding = false
        }

        val subtitleSelectedTextWrap = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        }

        subtitleSelectedName.apply {
            setTextColor(Color.WHITE)
            textSize = 16f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }

        subtitleSelectedMeta.apply {
            text = "Selected subtitle is on"
            setTextColor(currentSubtitleDescriptionColor(true))
            textSize = 14f
            setPadding(0, dp(6), 0, 0)
        }

        subtitleSelectedTextWrap.addView(subtitleSelectedName)
        subtitleSelectedTextWrap.addView(subtitleSelectedMeta)
        subtitleSelectedCard.addView(subtitleSelectedCheck)
        subtitleSelectedCard.addView(
            subtitleSelectedTextWrap,
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(14)
            }
        )

        subtitleEmptyStateText.apply {
            text = "No subtitles loaded yet."
            setTextColor(Color.parseColor("#AFFFFFFF"))
            textSize = 15f
            setPadding(0, dp(12), 0, dp(12))
        }

        subtitleDrawerContent.apply {
            orientation = LinearLayout.VERTICAL
        }

        subtitleDrawerContent.addView(subtitleSelectedCard)
        subtitleDrawerContent.addView(subtitleEmptyStateText)
        subtitleDrawerContent.addView(
            createSubtitleDrawerRow(R.drawable.ic_upload, "Open") {
                openSubtitlePicker()
            }
        )
        subtitleDrawerContent.addView(
            createSubtitleDrawerRow(R.drawable.ic_link, "Load from URL") {
                showSubtitleUrlDialog()
            }
        )

        subtitleRemoveRow.apply {
            orientation = LinearLayout.VERTICAL
            addView(
                createSubtitleDrawerRow(R.drawable.ic_delete, "Remove subtitles") {
                    clearSubtitle()
                }
            )
        }
        subtitleDrawerContent.addView(subtitleRemoveRow)

        subtitleDrawerPanel.addView(header)
        subtitleDrawerPanel.addView(
            subtitleDrawerContent,
            LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(28)
            }
        )

        subtitleDrawerOverlay.addView(subtitleDrawerPanel, panelParams)
        addView(subtitleDrawerOverlay)
        updateSubtitleDrawerUi()
    }

    private fun updateSubtitleDrawerUi() {
        val hasSubtitle = selectedSubtitleUri != null
        val hasEmbedded = hasEmbeddedSubtitles
        val hasAnySubtitle = hasSubtitle || hasEmbedded
        Log.d(
            SUBTITLE_LOG_TAG,
            "update_drawer hasSubtitle=$hasSubtitle enabled=$subtitlePlaybackEnabled hasEmbedded=$hasEmbedded label=${subtitleLabelForUri(selectedSubtitleUri)}"
        )

        subtitleSelectedCard.isVisible = hasSubtitle
        subtitleEmptyStateText.isVisible = !hasAnySubtitle
        subtitleRemoveRow.isVisible = hasSubtitle
        subtitleSelectedName.text = subtitleLabelForUri(selectedSubtitleUri)
        subtitleSelectedCheck.isChecked = hasSubtitle && subtitlePlaybackEnabled
        subtitleSelectedMeta.text =
            if (!hasSubtitle) {
                "No subtitle selected"
            } else if (subtitlePlaybackEnabled) {
                "Selected subtitle is on"
            } else {
                "Selected subtitle is off"
            }
        subtitleSelectedCheck.buttonTintList = ColorStateList.valueOf(subtitleCheckboxColor)
        subtitleSelectedMeta.setTextColor(
            currentSubtitleDescriptionColor(hasSubtitle && subtitlePlaybackEnabled)
        )
        (subtitleSelectedCard.background as? GradientDrawable)?.apply {
            setColor(
                if (hasSubtitle && subtitlePlaybackEnabled) {
                    Color.parseColor("#1CFFFFFF")
                } else {
                    Color.parseColor("#14111111")
                }
            )
            setStroke(
                dp(1),
                if (hasSubtitle && subtitlePlaybackEnabled) {
                    Color.parseColor("#55FFFFFF")
                } else {
                    Color.parseColor("#33FFFFFF")
                }
            )
        }
    }

    private fun updateSubtitleRendererVisibility() {
        val shouldShow = subtitlePlaybackEnabled && (selectedSubtitleUri != null || hasEmbeddedSubtitles)
        subtitleView.visibility = if (shouldShow) View.VISIBLE else View.GONE
        if (shouldShow) {
            subtitleView.bringToFront()
            subtitleFallbackText.visibility =
                if (activeSubtitleText.isNotBlank()) View.VISIBLE else View.GONE
            subtitleFallbackText.bringToFront()
        } else {
            subtitleFallbackText.visibility = View.GONE
        }
        if (!shouldShow) {
            subtitleView.setCues(emptyList())
            activeSubtitleText = ""
            subtitleFallbackText.text = ""
            hideSubtitleCuePopup()
        }
    }

    private fun ensureSubtitleCuePopup() {
        if (subtitleCuePopup != null) return

        subtitleCuePopupText.apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setTypeface(typeface, android.graphics.Typeface.NORMAL)
            setPadding(dp(18), dp(12), dp(18), dp(12))
            maxLines = 3
            isSingleLine = false
            setHorizontallyScrolling(false)
            setLineSpacing(0f, 1.08f)
            background = null
        }
        applySubtitleAppearance()

        subtitleCuePopupContainer.removeAllViews()
        subtitleCuePopupContainer.setPadding(dp(20), 0, dp(20), 0)
        subtitleCuePopupContainer.addView(
            subtitleCuePopupText,
            FrameLayout.LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        subtitleCuePopup = PopupWindow(
            subtitleCuePopupContainer,
            LayoutParams.MATCH_PARENT,
            LayoutParams.WRAP_CONTENT,
            false
        ).apply {
            isTouchable = false
            isFocusable = false
            isOutsideTouchable = false
            elevation = 260f
            animationStyle = 0
            isClippingEnabled = false
        }
    }

    private fun showSubtitleCuePopup(text: CharSequence) {
        if (text.isBlank()) {
            hideSubtitleCuePopup()
            return
        }

        post {
            ensureSubtitleCuePopup()
            subtitleCuePopupText.text = text
            val popup = subtitleCuePopup ?: return@post
            val anchor = reactContext.currentActivity?.window?.decorView ?: this
            if (!anchor.isAttachedToWindow) return@post

            val width = (resources.displayMetrics.widthPixels - dp(24)).coerceAtLeast(dp(220))
            val bottomOffset = computeSubtitlePopupBottomOffset(anchor)
            if (!popup.isShowing) {
                popup.width = width
                popup.height = LayoutParams.WRAP_CONTENT
                popup.showAtLocation(anchor, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL, 0, bottomOffset)
            } else {
                popup.update(0, bottomOffset, width, LayoutParams.WRAP_CONTENT)
            }
        }
    }

    private fun hideSubtitleCuePopup() {
        subtitleCuePopup?.dismiss()
    }

    private fun computeSubtitlePopupBottomOffset(anchor: View): Int {
        if (!controlsVisible || controls.visibility != View.VISIBLE) {
            return if (isVideoVertical) dp(42) else dp(28)
        }

        val anchorLocation = IntArray(2)
        val seekLocation = IntArray(2)
        anchor.getLocationOnScreen(anchorLocation)
        seekBar.getLocationOnScreen(seekLocation)

        val seekTopRelative = seekLocation[1] - anchorLocation[1]
        val anchorHeight = anchor.height.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
        val bottomOffset = (anchorHeight - seekTopRelative) + dp(10)
        return bottomOffset.coerceIn(if (isVideoVertical) dp(42) else dp(28), anchorHeight - dp(24))
    }

    private fun computeSubtitleTextSizeSp(): Float {
        val metrics = resources.displayMetrics
        val smallestWidthDp =
            minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
        return (smallestWidthDp * 0.045f).coerceIn(16f, 21f)
    }

    private fun applySubtitleAppearance() {
        val textSizeSp = computeSubtitleTextSizeSp()
        val shadowRadius = (textSizeSp * 0.4f).coerceIn(4f, 8f)

        subtitleView.setStyle(
            CaptionStyleCompat(
                subtitleTextColor,
                Color.TRANSPARENT,
                Color.TRANSPARENT,
                CaptionStyleCompat.EDGE_TYPE_OUTLINE,
                Color.BLACK,
                null
            )
        )
        subtitleView.setFixedTextSize(TypedValue.COMPLEX_UNIT_SP, textSizeSp)

        subtitleFallbackText.apply {
            setTextColor(subtitleTextColor)
            textSize = textSizeSp
            setShadowLayer(shadowRadius, 0f, 0f, Color.BLACK)
            background = null
        }

        subtitleCuePopupText.apply {
            setTextColor(subtitleTextColor)
            textSize = textSizeSp
            setShadowLayer(shadowRadius, 0f, 0f, Color.BLACK)
            background = null
        }
    }

    private fun setSubtitlePlaybackEnabled(enabled: Boolean) {
        subtitlePlaybackEnabled = enabled
        Log.d(
            SUBTITLE_LOG_TAG,
            "toggle_subtitle enabled=$enabled selectedUri=$selectedSubtitleUri mime=$selectedSubtitleMimeType"
        )

        player.setTrackSelectionParameters(
            player.trackSelectionParameters
                .buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !enabled)
                .build()
        )

        if (selectedSubtitleUri != null) {
            refreshMediaItemPreservingState()
        }

        updateSubtitleRendererVisibility()
        updateSubtitleButtonStyle()
        updateSubtitleDrawerUi()
    }

    private fun openSubtitleDrawer() {
        if (subtitleDrawerOverlay.visibility == View.VISIBLE) return
        beginSubtitleMenuSession()
        updateSubtitleDrawerUi()
        hideHandler.removeCallbacksAndMessages(null)
        controls.visibility = View.VISIBLE
        controlsVisible = true
        subtitleDrawerOpenedAtMs = SystemClock.uptimeMillis()
        subtitleDrawerOverlay.bringToFront()
        subtitleDrawerPanel.bringToFront()
        subtitleDrawerOverlay.visibility = View.VISIBLE
        subtitleDrawerOverlay.alpha = 1f
        subtitleDrawerPanel.translationX = 0f
        subtitleDrawerOverlay.requestLayout()
        subtitleDrawerOverlay.invalidate()
    }

    private fun closeSubtitleDrawer() {
        if (subtitleDrawerOverlay.visibility != View.VISIBLE) return
        subtitleDrawerOverlay.alpha = 0f
        subtitleDrawerOverlay.visibility = View.GONE
        val drawerWidth = subtitleDrawerPanel.width.takeIf { it > 0 } ?: dp(320)
        subtitleDrawerPanel.translationX = drawerWidth.toFloat()
        endSubtitleMenuSession()
        showControls()
    }

    private fun showResumePromptIfNeeded() {
        if (!resumePlaybackEnabled) return
        val uri = currentMediaUri ?: return
        val resumePosition = pendingResumePositionMs ?: return
        if (hasHandledResumePrompt || resumePosition <= 0L || lastDuration <= 0L) return
        if (resumePosition >= lastDuration - 1_000L) {
            clearSavedPosition(uri)
            pendingResumePositionMs = null
            hasHandledResumePrompt = true
            return
        }

        hasHandledResumePrompt = true
        pendingResumePositionMs = null
        player.seekTo(resumePosition)
        updateProgressUi()
        didAutoResumeCurrentMedia = true
        // Refresh label color in case buttonTintColor was set after setupControls
        resumeBannerStartOverLabel.setTextColor(buttonTintColor)
        resumeInfoRow.visibility = View.VISIBLE
    }

    private fun syncResumeStateForCurrentMedia() {
        val uri = currentMediaUri ?: return

        if (!resumePlaybackEnabled) {
            pendingResumePositionMs = null
            hasHandledResumePrompt = true
            didAutoResumeCurrentMedia = false
            resumeInfoRow.visibility = View.GONE
            return
        }

        pendingResumePositionMs = playbackPrefs.getLong(resumePositionKey(uri), 0L)
            .takeIf { it > 0L }
        hasHandledResumePrompt = false

        if (lastDuration > 0L) {
            showResumePromptIfNeeded()
        }
    }

    private fun loadMedia(entry: VideoSourceEntry, index: Int = currentIndex) {
        val uri = entry.uri
        registerAsActivePlayerView()
        currentMediaUri = uri
        currentSourceIsRemote = VideoCacheManager.isRemoteUri(uri)
        pendingInitialControlsRestore = true
        resetVideoZoom()
        currentIndex = index
        Log.d(SUBTITLE_LOG_TAG, "load_media uri=$uri index=$index")

        subtitlePlaybackEnabled = true
        userDisabledSubtitles = false
        hasEmbeddedSubtitles = false
        didAutoEnableEmbeddedSubtitles = false
        selectedSubtitleUri = null
        selectedSubtitleMimeType = null

        setSubtitlePlaybackEnabled(true)

        pendingResumePositionMs = playbackPrefs.getLong(resumePositionKey(uri), 0L)
            .takeIf { resumePlaybackEnabled && it > 0L }
        hasHandledResumePrompt = false
        lastPersistedUri = uri
        lastPersistedPositionMs = -1L
        didAutoResumeCurrentMedia = false
        suppressResumeSaveUntilRestart = false
        lastDuration = 0L
        lastPlaybackState = Player.STATE_IDLE
        lastKnownCacheStats = VideoCacheStats()
        lastProgressEventAtMs = 0L
        lastCacheStatsRefreshAtMs = 0L
        isCacheStatsRefreshInFlight = false
        currentText.text = "00:00"
        seekBar.progress = 0
        seekBar.secondaryProgress = 0
        resumeInfoRow.visibility = View.GONE

        try {
            val parsed = Uri.parse(uri)
            if (parsed.scheme == ContentResolver.SCHEME_FILE) {
                val videoFile = File(parsed.path ?: "")
                val parent = videoFile.parentFile
                if (parent != null && parent.exists()) {
                    val base = videoFile.nameWithoutExtension
                    val subtitle = parent.listFiles()?.firstOrNull {
                        val name = it.name.lowercase()
                        it.isFile && (
                            name == "$base.srt" ||
                            name == "$base.vtt" ||
                            name == "$base.ass" ||
                            name == "$base.ssa"
                        )
                    }
                    if (subtitle != null) {
                        selectedSubtitleUri = Uri.fromFile(subtitle)
                        selectedSubtitleMimeType = inferSubtitleMimeType(subtitle.name)
                        Log.d(
                            SUBTITLE_LOG_TAG,
                            "auto_load_local_subtitle subtitle=${subtitle.absolutePath} mime=$selectedSubtitleMimeType"
                        )
                        setSubtitlePlaybackEnabled(true)
                        showOverlay("Subtitle Loaded")
                    }
                }
            }
        } catch (_: Exception) {}

        val item = rebuildMediaItemWithCurrentSubtitle() ?: MediaItem.fromUri(Uri.parse(uri))
        player.setMediaItem(item)
        player.prepare()
        player.play()
        playBtn.setImageResource(R.drawable.ic_pause_player)
        if (currentSourceIsRemote) {
            maybeRefreshCacheStats(force = true)
        }

        updateDisplayedTitle(entry)

        playbackPrefs.edit().apply {
            putString("last_uri", uri)
            putInt("last_index", currentIndex)
        }.apply()
    }

    private fun ensureUnlockPopup() {
        if (unlockPopup != null) return

        unlockBtn.visibility = View.VISIBLE
        unlockBtn.alpha = 1f
        unlockBtn.isClickable = true

        (unlockBtn.parent as? ViewGroup)?.removeView(unlockBtn)
        unlockPopupContainer.removeAllViews()
        unlockPopupContainer.addView(unlockBtn)

        unlockPopup = PopupWindow(
            unlockPopupContainer,
            LayoutParams.WRAP_CONTENT,
            LayoutParams.WRAP_CONTENT,
            false
        ).apply {
            isTouchable = true
            isOutsideTouchable = false
            isFocusable = false
            elevation = 160f
        }
    }

    private fun showUnlockPopup() {
        ensureUnlockPopup()
        val popup = unlockPopup ?: return
        if (!popup.isShowing) {
            popup.showAtLocation(this, Gravity.TOP or Gravity.END, dp(18), dp(18))
        } else {
            popup.update(dp(18), dp(18), -1, -1)
        }
    }

    private fun hideUnlockPopup() {
        unlockPopup?.dismiss()
        unlockPopup = null
        unlockPopupContainer.removeAllViews()
        unlockBtn.visibility = View.GONE
    }

    private fun resetLockUiState() {
        controlsLocked = false
        wasPlayingWhenLocked = false
        lockOverlay.visibility = View.GONE
        lockOverlay.setBackgroundColor(Color.TRANSPARENT)
        hideUnlockPopup()
    }

    private fun hideControls() {
        if (subtitleDrawerOverlay.visibility == View.VISIBLE) return
        controls.clearAnimation()

        val fade = AlphaAnimation(1f, 0f)
        fade.duration = 200
        controls.startAnimation(fade)

        controls.visibility = View.GONE
        controlsVisible = false

        if (activeSubtitleText.isNotBlank()) {
            showSubtitleCuePopup(activeSubtitleText)
        }
    }

    // ---------------- OVERLAY ----------------

    private fun setupOverlay() {
        subtitleView.apply {
            setApplyEmbeddedStyles(false)
            setApplyEmbeddedFontSizes(false)
            setBottomPaddingFraction(0.10f)
            visibility = View.GONE
            alpha = 1f
            elevation = 40f
            translationZ = 40f
        }

        addView(
            subtitleView,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        )

        subtitleFallbackText.apply {
            gravity = Gravity.CENTER
            textAlignment = View.TEXT_ALIGNMENT_CENTER
            setTypeface(typeface, android.graphics.Typeface.NORMAL)
            setPadding(dp(18), dp(10), dp(18), dp(10))
            maxLines = 3
            isSingleLine = false
            setHorizontallyScrolling(false)
            setLineSpacing(0f, 1.1f)
            background = null
            visibility = View.GONE
            alpha = 1f
            elevation = 200f
            translationZ = 200f
        }

        addView(
            subtitleFallbackText,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(92)
                marginStart = dp(24)
                marginEnd = dp(24)
            }
        )

        applySubtitleAppearance()

        overlayText.setTextColor(Color.WHITE)
        overlayText.textSize = 18f
        overlayText.setBackgroundColor(Color.parseColor("#66000000"))
        overlayText.gravity = Gravity.CENTER
        overlayText.visibility = View.GONE
        overlayText.setPadding(dp(16), dp(8), dp(16), dp(8))

        addView(
            overlayText,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )

        zoomIndicatorText.apply {
            setTextColor(Color.WHITE)
            textSize = 28f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            includeFontPadding = false
            minWidth = dp(92)
            minHeight = dp(56)
            setPadding(dp(20), dp(14), dp(20), dp(14))
            visibility = View.GONE
            alpha = 0f
            background = GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                setColor(Color.parseColor("#CC111317"))
                setStroke(dp(1), Color.parseColor("#40FFFFFF"))
            }
        }

        addView(
            zoomIndicatorText,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )

        // Brightness HUD (MX-style)
        brightnessIcon.setImageResource(R.drawable.ic_sun)
        brightnessIcon.setColorFilter(Color.WHITE)
        brightnessHud.orientation = LinearLayout.VERTICAL
        brightnessHud.gravity = Gravity.CENTER_HORIZONTAL
        brightnessHud.visibility = View.GONE
        brightnessHud.setPadding(dp(14), dp(14), dp(14), dp(14))
        brightnessHud.background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(Color.parseColor("#CC1A1A1A"))
        }
        brightnessHud.addView(
            brightnessIcon,
            LinearLayout.LayoutParams(dp(24), dp(24))
        )
        brightnessBarTrack.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(Color.parseColor("#55FFFFFF"))
        }
        brightnessHud.addView(
            brightnessBarTrack,
            LinearLayout.LayoutParams(dp(8), dp(116)).apply {
                topMargin = dp(12)
            }
        )
        brightnessBarTrack.addView(
            brightnessBarFill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                0,
                Gravity.BOTTOM
            )
        )
        brightnessBarFill.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(Color.parseColor("#FFD54F"))
        }
        addView(
            brightnessHud,
            LayoutParams(dp(84), dp(230), Gravity.LEFT or Gravity.CENTER_VERTICAL).apply {
                leftMargin = dp(24)
            }
        )

        // Volume HUD (MX-style)
        volumeIcon.setImageResource(R.drawable.ic_volume_up)
        volumeIcon.setColorFilter(Color.WHITE)
        volumeHud.orientation = LinearLayout.VERTICAL
        volumeHud.gravity = Gravity.CENTER_HORIZONTAL
        volumeHud.visibility = View.GONE
        volumeHud.setPadding(dp(14), dp(14), dp(14), dp(14))
        volumeHud.background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(Color.parseColor("#CC1A1A1A"))
        }
        volumeHud.addView(
            volumeIcon,
            LinearLayout.LayoutParams(dp(24), dp(24))
        )
        volumeBarTrack.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(Color.parseColor("#55FFFFFF"))
        }
        volumeHud.addView(
            volumeBarTrack,
            LinearLayout.LayoutParams(dp(8), dp(116)).apply {
                topMargin = dp(12)
            }
        )
        volumeBarTrack.addView(
            volumeBarFill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                0,
                Gravity.BOTTOM
            )
        )
        volumeBarFill.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(Color.parseColor("#80D8FF"))
        }
        addView(
            volumeHud,
            LayoutParams(dp(84), dp(230), Gravity.RIGHT or Gravity.CENTER_VERTICAL).apply {
                rightMargin = dp(24)
            }
        )

        post {
            updateHudFill(brightnessBarTrack, brightnessBarFill, 50)
            updateHudFill(volumeBarTrack, volumeBarFill, 50)
        }
    }

    private fun updateHudFill(track: FrameLayout, fill: View, percent: Int) {
        val clamped = percent.coerceIn(0, 100)
        val trackHeight = if (track.height > 0) track.height else dp(116)
        val target = (trackHeight * clamped / 100).coerceAtLeast(dp(2))
        val lp = fill.layoutParams as FrameLayout.LayoutParams
        if (lp.height != target) {
            lp.height = target
            fill.layoutParams = lp
        }
    }

    private fun ensurePopupHud() {
        if (gesturePopup != null) return

        popupHudContainer.orientation = LinearLayout.VERTICAL
        popupHudContainer.gravity = Gravity.CENTER_HORIZONTAL
        popupHudContainer.setPadding(dp(14), dp(14), dp(14), dp(14))
        popupHudContainer.background = GradientDrawable().apply {
            cornerRadius = dp(16).toFloat()
            setColor(Color.parseColor("#E6000000"))
        }

        popupHudContainer.addView(
            popupHudIcon,
            LinearLayout.LayoutParams(dp(24), dp(24))
        )
        popupHudIcon.setColorFilter(Color.WHITE)

        popupHudTrack.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(Color.parseColor("#55FFFFFF"))
        }
        popupHudContainer.addView(
            popupHudTrack,
            LinearLayout.LayoutParams(dp(10), dp(130)).apply { topMargin = dp(10) }
        )

        popupHudTrack.addView(
            popupHudFill,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                0,
                Gravity.BOTTOM
            )
        )

        popupHudPercent.setTextColor(Color.WHITE)
        popupHudPercent.textSize = 12f
        popupHudPercent.gravity = Gravity.CENTER
        popupHudContainer.addView(
            popupHudPercent,
            LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(10)
            }
        )

        gesturePopup = PopupWindow(
            popupHudContainer,
            dp(88),
            dp(248),
            false
        ).apply {
            isTouchable = false
            isOutsideTouchable = false
            isFocusable = false
            isClippingEnabled = false
            elevation = 100f
        }
    }

    private fun updatePopupFill(percent: Int) {
        val clamped = percent.coerceIn(0, 100)
        val trackHeight = if (popupHudTrack.height > 0) popupHudTrack.height else dp(130)
        val target = (trackHeight * clamped / 100).coerceAtLeast(dp(2))
        val lp = popupHudFill.layoutParams as FrameLayout.LayoutParams
        if (lp.height != target) {
            lp.height = target
            popupHudFill.layoutParams = lp
        }
    }

    private fun showPopupHud(isBrightness: Boolean, percent: Int) {
        ensurePopupHud()
        val popup = gesturePopup ?: return

        popupHudIcon.setImageResource(
            if (isBrightness) R.drawable.ic_sun
            else R.drawable.ic_volume_up
        )
        popupHudFill.background = GradientDrawable().apply {
            cornerRadius = dp(4).toFloat()
            setColor(
                Color.parseColor(
                    if (isBrightness) "#FFD54F" else "#80D8FF"
                )
            )
        }
        popupHudPercent.text = "${percent.coerceIn(0, 100)}%"
        updatePopupFill(percent)
        popupHudContainer.post { updatePopupFill(percent) }

        val loc = IntArray(2)
        getLocationOnScreen(loc)
        val popupW = dp(88)
        val popupH = dp(248)
        val x = if (isBrightness) {
            loc[0] + dp(20)
        } else {
            loc[0] + width - popupW - dp(20)
        }.coerceAtLeast(0)
        val y = (loc[1] + (height - popupH) / 2).coerceAtLeast(0)

        if (!popup.isShowing) {
            popup.showAtLocation(this, Gravity.TOP or Gravity.START, x, y)
        } else {
            popup.update(x, y, -1, -1)
        }
    }

    private fun hidePopupHud() {
        gesturePopup?.dismiss()
    }

    private fun showGestureHud(hud: LinearLayout, track: FrameLayout, fill: View, percent: Int) {
        hideHandler.removeCallbacks(gestureHudHideRunnable)
        if (hud.visibility != View.VISIBLE) hud.visibility = View.VISIBLE
        val isBrightness = hud === brightnessHud
        Log.d("GestureDebug", "HUD_SHOW side=${if (isBrightness) "brightness" else "volume"} percent=$percent")
        updateHudFill(track, fill, percent)
        hud.post { updateHudFill(track, fill, percent) }
        showPopupHud(isBrightness, percent)
    }

    private fun hideGestureHud() {
        Log.d("GestureDebug", "HUD_HIDE")
        brightnessHud.visibility = View.GONE
        volumeHud.visibility = View.GONE
        hidePopupHud()
    }

    private fun bringGestureUiToFront() {
        overlayText.bringToFront()
        zoomIndicatorText.bringToFront()
        brightnessHud.bringToFront()
        volumeHud.bringToFront()

        overlayText.elevation = 80f
        zoomIndicatorText.elevation = 95f
        brightnessHud.elevation = 90f
        volumeHud.elevation = 90f
        overlayText.translationZ = 80f
        zoomIndicatorText.translationZ = 95f
        brightnessHud.translationZ = 90f
        volumeHud.translationZ = 90f
    }

    private fun showOverlay(text: String) {

        overlayText.text = text
        overlayText.removeCallbacks(overlayHideRunnable)
        overlayText.animate().cancel()
        overlayText.alpha = 0f
        overlayText.visibility = View.VISIBLE

        overlayText.animate().alpha(1f).setDuration(120).start()
        overlayText.postDelayed(overlayHideRunnable, 900)
    }

    // ---------------- BUFFER ----------------

    private fun setupBufferLoader() {

        bufferLoader.visibility = View.GONE

        addView(
            bufferLoader,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )
    }

    // ---------------- CONTROLS ----------------

    private fun setupControls() {

        controls.removeAllViews()

        controls.layoutParams =
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)

        val center = LinearLayout(context)
        center.gravity = Gravity.CENTER
        center.orientation = LinearLayout.HORIZONTAL

        val iconSize = dp(56)

        val iconParams = LinearLayout.LayoutParams(iconSize, iconSize)
        iconParams.setMargins(dp(20), 0, dp(20), 0)

        rewindBtn.setImageResource(R.drawable.ic_skip_previous_player)
        playBtn.setImageResource(R.drawable.ic_pause_player)
        forwardBtn.setImageResource(R.drawable.ic_skip_next_player)

        rewindBtn.layoutParams = iconParams
        playBtn.layoutParams = iconParams
        forwardBtn.layoutParams = iconParams

        rewindBtn.setColorFilter(buttonTintColor)
        playBtn.setColorFilter(buttonTintColor)
        forwardBtn.setColorFilter(buttonTintColor)

        center.background = GradientDrawable().apply {
            cornerRadius = dp(24).toFloat()
            setColor(Color.parseColor("#4C000000"))
        }
        center.setPadding(dp(16), dp(8), dp(16), dp(8))

        rewindBtnBg.apply { setColor(Color.TRANSPARENT); setStroke(0, Color.TRANSPARENT); shape = GradientDrawable.OVAL }
        forwardBtnBg.apply { setColor(Color.TRANSPARENT); setStroke(0, Color.TRANSPARENT); shape = GradientDrawable.OVAL }
        playBtnBg.apply { 
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor("#1FFFFFFF"))
            setStroke(0, Color.TRANSPARENT)
        }

        listOf(
            rewindBtnBg to rewindBtn,
            playBtnBg to playBtn,
            forwardBtnBg to forwardBtn
        ).forEach { (bg, btn) ->
            btn.background = bg
            btn.setPadding(dp(12), dp(12), dp(12), dp(12))
            btn.scaleType = ImageView.ScaleType.CENTER_INSIDE
        }

        center.addView(rewindBtn)
        center.addView(playBtn)
        center.addView(forwardBtn)

        // ---------------- TOP CONTROLS (GRADIENT MODERN UI) ----------------

        val topBar = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = if (isVideoVertical) Gravity.TOP else Gravity.CENTER_VERTICAL
            layoutParams = LayoutParams(
                LayoutParams.MATCH_PARENT,
                if (isVideoVertical) dp(96) else dp(58),
                Gravity.TOP
            ).apply {
                topMargin = dp(10)
                marginStart = dp(12)
                marginEnd = dp(12)
            }
            setPadding(dp(8), if (isVideoVertical) dp(8) else dp(6), dp(8), dp(6))
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.parseColor("#4C000000"))
            }
        }
        this.topBar = topBar

        val leftHeader = LinearLayout(context).apply {
            orientation = if (isVideoVertical) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = if (isVideoVertical) Gravity.TOP or Gravity.START else Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
            minimumWidth = 0
        }

        backBtn.apply {
            setImageResource(R.drawable.ic_back_arrow)
            setColorFilter(buttonTintColor)
            background = createTopToolBackground()
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            val inset = topToolInset()
            setPadding(inset, inset, inset, inset)
            layoutParams = LinearLayout.LayoutParams(topToolButtonSize(), topToolButtonSize()).apply {
                marginEnd = if (isVideoVertical) 0 else dp(8)
                bottomMargin = if (isVideoVertical) dp(6) else 0
                topMargin = 0
            }
        }

        fileNameText.apply {
            setTextColor(Color.WHITE)
            textSize = if (isVideoVertical) 12f else 16f
            maxLines = if (isVideoVertical) 2 else 1
            minLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            text = "Now Playing"
            gravity = if (isVideoVertical) Gravity.START else Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = 0
                marginEnd = if (isVideoVertical) dp(8) else 0
            }
        }

        leftHeader.removeAllViews()
        if (isVideoVertical) {
            leftHeader.addView(
                backBtn,
                LinearLayout.LayoutParams(topToolButtonSize(), topToolButtonSize()).apply {
                    bottomMargin = dp(6)
                }
            )
            leftHeader.addView(
                fileNameText,
                LinearLayout.LayoutParams(
                    LayoutParams.MATCH_PARENT,
                    LayoutParams.WRAP_CONTENT
                )
            )
        } else {
            leftHeader.addView(backBtn)
            leftHeader.addView(fileNameText)
        }

        val rightTools = LinearLayout(context).apply {
            orientation = if (isVideoVertical) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = if (isVideoVertical) Gravity.TOP or Gravity.END else Gravity.END or Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT
            )
        }

        val toolButtonSize = topToolButtonSize()
        val toolIconParams = LinearLayout.LayoutParams(toolButtonSize, toolButtonSize).apply {
            if (isVideoVertical) {
                setMargins(dp(2), dp(2), dp(2), dp(2))
            } else {
                setMargins(dp(12), dp(6), dp(12), dp(6))
            }
        }

        lockBtn.apply {
            setImageResource(R.drawable.ic_lock_player)
            setColorFilter(buttonTintColor)
            layoutParams = toolIconParams
            applyTopToolIconStyle(this)
        }

        loopBtn.apply {
            setImageResource(R.drawable.ic_repeat_player)
            setColorFilter(if (isLooping) Color.GREEN else buttonTintColor)
            layoutParams = toolIconParams
            applyTopToolIconStyle(this)
        }

        shuffleBtn.apply {
            setImageResource(R.drawable.ic_shuffle_player)
            setColorFilter(if (isShuffleEnabled) Color.GREEN else buttonTintColor)
            layoutParams = toolIconParams
            applyTopToolIconStyle(this)
        }

        subtitleBtn.apply {
            text = "CC"
            textSize = if (isVideoVertical) 8f else 10f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            includeFontPadding = false
            setPadding(0, 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(
                toolButtonSize,
                toolButtonSize
            ).apply {
                if (isVideoVertical) {
                    setMargins(dp(2), dp(2), dp(2), dp(2))
                } else {
                    setMargins(dp(12), dp(6), dp(12), dp(6))
                }
            }
        }
        updateSubtitleButtonStyle()

        backgroundPlayBtn.apply {
            setImageResource(R.drawable.ic_background_play)
            setColorFilter(buttonTintColor)
            layoutParams = toolIconParams
            contentDescription = "Background play"
            applyTopToolIconStyle(this)
        }
        updateBackgroundPlayButtonStyle()

        screenshotBtn.apply {
            setImageResource(R.drawable.ic_camera_capture)
            setColorFilter(buttonTintColor)
            layoutParams = toolIconParams
            applyTopToolIconStyle(this)
        }

        settingsBtn.apply {
            setImageResource(R.drawable.ic_tune)
            setColorFilter(buttonTintColor)
            layoutParams = toolIconParams
            contentDescription = "Playback settings"
            applyTopToolIconStyle(this)
        }
        updateSettingsButtonStyle()

        speedBtn.apply {
            text = "1x"
            setTextColor(buttonTintColor)
            textSize = if (isVideoVertical) 7f else 10f
            gravity = Gravity.CENTER
            includeFontPadding = false
            background = createTopToolBackground()
            setPadding(0, 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(
                toolButtonSize,
                toolButtonSize
            ).apply {
                if (isVideoVertical) {
                    setMargins(dp(2), dp(2), dp(2), dp(2))
                } else {
                    setMargins(dp(12), dp(6), dp(12), dp(6))
                }
            }
        }

        // ---- Vertical tool rows (no startOverBtn in toolbar) ----
        val verticalToolRows = if (isVideoVertical) {
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.END
            }.also { container ->
                val topRow = LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END or Gravity.CENTER_VERTICAL
                }
                val bottomRow = LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END or Gravity.CENTER_VERTICAL
                }

                topRow.addView(lockBtn)
                topRow.addView(loopBtn)
                topRow.addView(shuffleBtn)

                bottomRow.addView(backgroundPlayBtn)
                bottomRow.addView(subtitleBtn)
                bottomRow.addView(settingsBtn)
                bottomRow.addView(screenshotBtn)
                bottomRow.addView(speedBtn)

                container.addView(topRow)
                container.addView(
                    bottomRow,
                    LinearLayout.LayoutParams(
                        LayoutParams.WRAP_CONTENT,
                        LayoutParams.WRAP_CONTENT
                    ).apply {
                        topMargin = dp(2)
                    }
                )
            }
        } else {
            null
        }

        rightTools.removeAllViews()
        if (isVideoVertical) {
            verticalToolRows?.let { rightTools.addView(it) }
        } else {
            // startOverBtn intentionally excluded from toolbar
            rightTools.addView(lockBtn)
            rightTools.addView(loopBtn)
            rightTools.addView(shuffleBtn)
            rightTools.addView(backgroundPlayBtn)
            rightTools.addView(subtitleBtn)
            rightTools.addView(settingsBtn)
            rightTools.addView(screenshotBtn)
            rightTools.addView(speedBtn)
        }

        topBar.removeAllViews()
        topBar.addView(
            leftHeader,
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)
        )
        topBar.addView(
            rightTools,
            LinearLayout.LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT
            )
        )
        updateControlsToolVisibility()

        val bottom = LinearLayout(context)

        bottom.orientation = LinearLayout.HORIZONTAL
        bottom.gravity = Gravity.CENTER_VERTICAL
        bottom.setPadding(dp(16), dp(10), dp(16), dp(10))
        bottom.background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(Color.parseColor("#4C000000"))
        }

        currentText.setTextColor(Color.WHITE)
        durationText.setTextColor(Color.WHITE)

        currentText.text = "00:00"
        durationText.text = "00:00"

        val seekParams =
            LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f)

        seekParams.setMargins(dp(12), 0, dp(12), 0)

        bottom.addView(currentText)
        bottom.addView(seekBar, seekParams)
        bottom.addView(durationText)

        // ---------------- MX-STYLE RESUME BANNER ----------------
        resumeInfoRow.apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#E6000000"))
            }
            visibility = View.GONE

            val dismissIcon = TextView(context).apply {
                text = "✕"
                setTextColor(Color.parseColor("#AAFFFFFF"))
                textSize = 15f
                setPadding(0, 0, dp(12), 0)
                setOnClickListener {
                    resumeInfoRow.visibility = View.GONE
                }
            }

            val msgText = TextView(context).apply {
                text = "Continue from where you stopped."
                setTextColor(Color.WHITE)
                textSize = 14f
            }

            val startOverLabel = resumeBannerStartOverLabel.apply {
                text = "START OVER"
                setTextColor(buttonTintColor)
                textSize = 14f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(14), 0, 0, 0)
                setOnClickListener {
                    player.seekTo(0)
                    resumeInfoRow.visibility = View.GONE
                    currentMediaUri?.let { clearSavedPosition(it) }
                    showOverlay("Started Over")
                }
            }

            addView(dismissIcon)
            addView(msgText)
            addView(startOverLabel)
        }

        controls.addView(
            center,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        )
        controls.addView(
            bottom,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
                bottomMargin = dp(12)
                marginStart = dp(12)
                marginEnd = dp(12)
            }
        )
        // Banner sits just above the seekbar
        controls.addView(
            resumeInfoRow,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.START or Gravity.BOTTOM).apply {
                leftMargin = dp(16)
                bottomMargin = dp(64)
            }
        )
        controls.addView(topBar)

        addView(controls)
        bringGestureUiToFront()

        // BUTTON EVENTS

        playBtn.setOnClickListener {

            showControls()

            if (player.isPlaying) {
                player.pause()
                playBtn.setImageResource(R.drawable.ic_play_arrow_player)
            } else {
                player.play()
                playBtn.setImageResource(R.drawable.ic_pause_player)
            }
        }

        forwardBtn.setOnClickListener {

            showControls()

            val nextIndex = getNextPlaybackIndex()

            if (nextIndex != null) {
                currentIndex = nextIndex
                syncShufflePosition()
                playCurrent()
                showOverlay("Next Video")
            } else {
                showOverlay("No Next Video")
            }
        }

        rewindBtn.setOnClickListener {

            showControls()

            val previousIndex = getPreviousPlaybackIndex()

            if (previousIndex != null) {
                currentIndex = previousIndex
                syncShufflePosition()
                playCurrent()
                showOverlay("Previous Video")
            } else {
                showOverlay("No Previous Video")
            }
        }

        speedBtn.setOnClickListener { showSpeedDialog() }

        screenshotBtn.setOnClickListener { takeScreenshot() }

        backgroundPlayBtn.setOnClickListener {
            registerAsActivePlayerView()
            toggleBackgroundPlay()
        }

        shuffleBtn.setOnClickListener {
            isShuffleEnabled = !isShuffleEnabled
            if (isShuffleEnabled) {
                rebuildShuffledQueue(currentIndex)
            } else {
                shuffledQueue.clear()
                shuffledQueuePosition = -1
            }
            shuffleBtn.setColorFilter(if (isShuffleEnabled) Color.GREEN else buttonTintColor)
            showOverlay(if (isShuffleEnabled) "Shuffle On" else "Shuffle Off")
        }

        subtitleBtn.setOnClickListener { showSubtitleOptions() }

        settingsBtn.setOnClickListener {
            registerAsActivePlayerView()
            showPlaybackSettingsDialog()
        }

        lockBtn.setOnClickListener {
            wasPlayingWhenLocked = player.isPlaying
            controlsLocked = true
            showOverlay("Controls Locked")
            hideHandler.removeCallbacksAndMessages(null)
            hideControls()
            showUnlockPrompt()
            post { showUnlockPrompt() }
        }

        backBtn.setOnClickListener {
            val activity = reactContext.currentActivity
            if (activity != null) {
                val componentActivity = activity as? androidx.activity.ComponentActivity
                if (componentActivity != null) {
                    componentActivity.onBackPressedDispatcher.onBackPressed()
                } else {
                    @Suppress("DEPRECATION")
                    activity.onBackPressed()
                }
            }
        }

        loopBtn.setOnClickListener { toggleLoop() }

        seekBar.max = 1000
        val trackHeight = dp(4)
        seekBar.minHeight = trackHeight
        seekBar.maxHeight = trackHeight
        seekBar.splitTrack = false

        val trackBg = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(2).toFloat()
            setColor(Color.parseColor("#4DFFFFFF"))
        }

        val trackSecondary = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(2).toFloat()
            setColor(Color.parseColor("#D8FFFFFF"))
        }

        val trackProgress = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(2).toFloat()
            setColor(Color.parseColor("#00BFA5"))
        }

        val progressDrawable = android.graphics.drawable.LayerDrawable(arrayOf(
            trackBg,
            android.graphics.drawable.ClipDrawable(trackSecondary, Gravity.START, android.graphics.drawable.ClipDrawable.HORIZONTAL),
            android.graphics.drawable.ClipDrawable(trackProgress, Gravity.START, android.graphics.drawable.ClipDrawable.HORIZONTAL)
        ))
        progressDrawable.setId(0, android.R.id.background)
        progressDrawable.setId(1, android.R.id.secondaryProgress)
        progressDrawable.setId(2, android.R.id.progress)

        seekBar.progressDrawable = progressDrawable

        val thumbGd = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setSize(dp(16), dp(16))
            setColor(Color.parseColor("#00BFA5"))
        }
        seekBar.thumb = thumbGd
        seekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {

            override fun onStartTrackingTouch(p0: SeekBar?) {
                if (controlsLocked) return
                isSeeking = true
                showControls()
            }

            override fun onStopTrackingTouch(p0: SeekBar?) {
                isSeeking = false
            }

            override fun onProgressChanged(p0: SeekBar?, progress: Int, fromUser: Boolean) {

                if (fromUser && lastDuration > 0) {

                    val seekPosition = progress * lastDuration / 1000
                    player.seekTo(seekPosition)
                }
            }
        })
    }

    // ---------------- GESTURES ----------------

    private fun setupGestures() {

        val detector = GestureDetector(
            context,
            object : GestureDetector.SimpleOnGestureListener() {

                override fun onDoubleTap(e: MotionEvent): Boolean {

                    if (controlsLocked) return true
                    if (videoZoomScale > minVideoZoom + 0.02f) {
                        resetVideoZoom(showFeedback = true)
                        return true
                    }

                    if (e.x < width / 2) {
                        player.seekTo((player.currentPosition - 10000).coerceAtLeast(0))
                        showOverlay("⏪ 10s")
                    } else {
                        player.seekTo(player.currentPosition + 10000)
                        showOverlay("⏩ 10s")
                    }

                    return true
                }

                override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                    if (controlsLocked) {
                        showUnlockPrompt()
                        return true
                    }
                    if (controlsVisible) hideControls()
                    else showControls()
                    return true
                }
            })

        val scaleDetector =
            ScaleGestureDetector(
                context,
                object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                    override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                        if (controlsLocked) return false
                        isZoomGestureActive = true
                        isPanningZoomedVideo = false
                        gestureMode = 0
                        hideGestureHud()
                        return true
                    }

                    override fun onScale(detector: ScaleGestureDetector): Boolean {
                        if (controlsLocked) return false
                        updateVideoZoom(
                            videoZoomScale * detector.scaleFactor,
                            detector.focusX,
                            detector.focusY
                        )
                        return true
                    }

                    override fun onScaleEnd(detector: ScaleGestureDetector) {
                        isZoomGestureActive = false
                        if (videoZoomScale <= minVideoZoom + 0.01f) {
                            resetVideoZoom()
                        }
                    }
                }
            )

        setOnTouchListener { _, event ->

            if (controlsLocked) {
                return@setOnTouchListener false
            }

            scaleDetector.onTouchEvent(event)
            val action = event.actionMasked
            val isMultiTouch = event.pointerCount > 1

            if (action == MotionEvent.ACTION_POINTER_DOWN) {
                isZoomGestureActive = true
                gestureMode = 0
                hideGestureHud()
                return@setOnTouchListener true
            }

            if (isMultiTouch || isZoomGestureActive) {
                if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                    isZoomGestureActive = false
                    isPanningZoomedVideo = false
                }
                return@setOnTouchListener true
            }

            detector.onTouchEvent(event)

            when (action) {

                MotionEvent.ACTION_DOWN -> {
                    Log.d(
                        "GestureDebug",
                        "DOWN x=$initialTouchX y=$initialTouchY brightnessStart=$gestureBrightness volumeStart=$gestureVolume"
                    )

                    initialTouchX = event.x
                    initialTouchY = event.y
                    lastPanTouchX = event.x
                    lastPanTouchY = event.y
                    isPanningZoomedVideo = false

                    gestureMode = 0

                    gestureBrightness = try {
                        val activity = reactContext.currentActivity
                        if (activity != null) {
                            val lp = activity.window.attributes
                            if (lp.screenBrightness >= 0f) lp.screenBrightness else 0.5f
                        } else {
                            0.5f
                        }
                    } catch (e: Exception) {
                        0.5f
                    }

                    gestureVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                }

                MotionEvent.ACTION_MOVE -> {
                    bringGestureUiToFront()
                    if (videoZoomScale > minVideoZoom + 0.02f) {
                        val deltaX = event.x - lastPanTouchX
                        val deltaY = event.y - lastPanTouchY
                        val movedFarEnough =
                            kotlin.math.abs(event.x - initialTouchX) > dp(8) ||
                                kotlin.math.abs(event.y - initialTouchY) > dp(8)

                        if (isPanningZoomedVideo || movedFarEnough) {
                            isPanningZoomedVideo = true
                            gestureMode = 0
                            videoPanX += deltaX
                            videoPanY += deltaY
                            clampVideoPan()
                            applyVideoZoom()
                            lastPanTouchX = event.x
                            lastPanTouchY = event.y
                            return@setOnTouchListener true
                        }
                    }

                    lastPanTouchX = event.x
                    lastPanTouchY = event.y
                    val deltaY = initialTouchY - event.y
                    Log.d("GestureDebug", "MOVE deltaY=$deltaY mode=$gestureMode")
                    if (gestureMode == 0) {
                        if (kotlin.math.abs(deltaY) > dp(24)) {
                            gestureMode = if (initialTouchX < width / 2) 1 else 2
                        } else {
                            return@setOnTouchListener true
                        }
                    }
                    val percent = deltaY.toFloat() / height.toFloat()

                    Log.d("GestureDebug", "BRIGHTNESS_GESTURE percent=$percent start=$gestureBrightness")
                    if (gestureMode == 1) {
                        try {
                            val activity = reactContext.currentActivity
                            if (activity == null) {
                                Log.e("GestureDebug", "BRIGHTNESS_ACTIVITY_NULL")
                                return@setOnTouchListener true
                            }

                            val newBrightness =
                                (gestureBrightness + percent)
                                    .coerceIn(0f, 1f)

                            Log.d("GestureDebug", "CALCULATED_BRIGHTNESS=$newBrightness")

                            val lp = activity.window.attributes
                            lp.screenBrightness = newBrightness
                            activity.window.attributes = lp

                            Log.d("GestureDebug", "APPLIED_BRIGHTNESS=${lp.screenBrightness}")
                            val percentValue = (newBrightness * 100).toInt()

                            showGestureHud(brightnessHud, brightnessBarTrack, brightnessBarFill, percentValue)

                            val now = System.currentTimeMillis()
                            if (now - lastGestureUiUpdate > gestureUiThrottleMs) {
                                overlayText.text = "Brightness ${percentValue}%"
                                overlayText.visibility = View.VISIBLE
                                lastGestureUiUpdate = now
                            }
                        } catch (e: Exception) {
                            Log.e("GestureDebug", "BRIGHTNESS_ERROR: ${e.message}", e)
                        }

                    } else if (gestureMode == 2) {
                        val maxVol =
                            audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)

                        val newVol =
                            (gestureVolume + percent * maxVol).toInt()
                                .coerceIn(0, maxVol)

                        audioManager.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            newVol,
                            0
                        )

                        val percentVol = (newVol * 100 / maxVol)

                        showGestureHud(volumeHud, volumeBarTrack, volumeBarFill, percentVol)

                        val now = System.currentTimeMillis()
                        if (now - lastGestureUiUpdate > gestureUiThrottleMs) {
                            overlayText.text = "Volume ${percentVol}%"
                            overlayText.visibility = View.VISIBLE
                            Log.d("GestureDebug", "VOLUME percentVol=$percentVol newVol=$newVol")
                            lastGestureUiUpdate = now
                        }
                    }
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {

                    gestureMode = 0
                    isPanningZoomedVideo = false

                    hideHandler.removeCallbacks(gestureHudHideRunnable)
                    hideHandler.postDelayed(gestureHudHideRunnable, 420)

                    hideHandler.postDelayed({
                        overlayText.visibility = View.GONE
                    }, 300)
                }
            }

            !controlsLocked
        }
    }

    // ---------------- SPEED ----------------

    private fun showSpeedDialog() {

        val speeds = arrayOf(0.5f, 1f, 1.5f, 2f)

        AlertDialog.Builder(context)
            .setTitle("Playback Speed")
            .setItems(arrayOf("0.5x", "1x", "1.5x", "2x")) { _, which ->

                val speed = speeds[which]
                player.setPlaybackSpeed(speed)

                speedBtn.text = "${speed}x"
                showOverlay("Speed ${speed}x")
            }
            .show()
    }

    // ---------------- SCREENSHOT ----------------

    private fun takeScreenshot() {

        val bitmap = textureView.drawToBitmap()
        val resolver = context.contentResolver

        val values = ContentValues()

        values.put(
            MediaStore.Images.Media.DISPLAY_NAME,
            "screenshot_${System.currentTimeMillis()}.png"
        )

        values.put(MediaStore.Images.Media.MIME_TYPE, "image/png")

        val uri =
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)

        uri?.let {

            resolver.openOutputStream(it)?.use { stream: OutputStream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            }

            Toast.makeText(context, "Screenshot saved", Toast.LENGTH_SHORT).show()
        }
    }

    private fun toggleLoop() {

        isLooping = !isLooping

        if (isLooping) {
            loopBtn.setColorFilter(Color.GREEN)
            showOverlay("Loop On")
        } else {
            loopBtn.setColorFilter(buttonTintColor)
            showOverlay("Loop Off")
        }
    }

    private fun updateControlsToolVisibility() {
        val toolVisibility = if (controlsEnabled) View.VISIBLE else View.GONE
        backBtn.visibility = toolVisibility
        lockBtn.visibility = toolVisibility
        shuffleBtn.visibility = toolVisibility
        loopBtn.visibility = toolVisibility
        backgroundPlayBtn.visibility = toolVisibility
        screenshotBtn.visibility = toolVisibility
        settingsBtn.visibility = toolVisibility
        speedBtn.visibility = toolVisibility
        subtitleBtn.visibility =
            if (controlsEnabled && enableSubtitle) View.VISIBLE else View.GONE

        topBar?.visibility = if (controlsEnabled) View.VISIBLE else View.GONE
    }

    // ---------------- PLAYER ----------------

    private fun setupPlayer() {

        postDelayed({ hideControls() }, 1000)

        player.addListener(object : Player.Listener {

            override fun onPlaybackStateChanged(state: Int) {
                lastPlaybackState = state

                if (state == Player.STATE_BUFFERING) {
                    bufferLoader.visibility = View.VISIBLE
                } else {
                    bufferLoader.visibility = View.GONE
                }

                if (state == Player.STATE_READY && player.duration > 0) {

                    lastDuration = player.duration
                    durationText.text = format(lastDuration)
                    updateProgressUi()
                    maybeRefreshCacheStats(force = true)
                    showResumePromptIfNeeded()
                    if (pendingInitialControlsRestore && !isInPictureInPictureMode) {
                        pendingInitialControlsRestore = false
                        refreshPlaybackChrome(showControlsAfterRefresh = true)
                    }

                    val map = Arguments.createMap()
                    map.putDouble("duration", lastDuration.toDouble())
                    map.putString("uri", currentMediaUri)
                    map.putInt("index", currentIndex)

                    sendEvent("onLoad", map)
                }

                if (state == Player.STATE_ENDED) {
                    currentMediaUri?.let { clearSavedPosition(it) }

                    if (isLooping) {
                        player.seekTo(0)
                        player.play()
                        playBtn.setImageResource(R.drawable.ic_pause_player)
                        return
                    }

                    val nextIndex = getNextPlaybackIndex()
                    if (nextIndex != null) {
                        currentIndex = nextIndex
                        syncShufflePosition()
                        playCurrent()
                        return
                    }

                    sendEvent("onVideoEnd", Arguments.createMap())
                }

                dispatchProgressEvent(force = true)
            }

            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
                val hasText = tracks.groups.any { it.type == C.TRACK_TYPE_TEXT && it.isSupported() }
                    tracks.groups.forEachIndexed { i, group ->
                        Log.d(SUBTITLE_LOG_TAG, "track_group[$i] type=${group.type} supported=${group.isSupported()} selected=${group.isSelected} count=${group.length}")
                        for (j in 0 until group.length) {
                            Log.d(SUBTITLE_LOG_TAG, "  format[$j]=${group.getTrackFormat(j)}")
                        }
                    }
                Log.d(SUBTITLE_LOG_TAG, "tracks_changed hasText=$hasText selectedUri=$selectedSubtitleUri enabled=$subtitlePlaybackEnabled")
                Log.d(
                    SUBTITLE_LOG_TAG,
                    "tracks_changed hasText=$hasText selectedUri=$selectedSubtitleUri mime=$selectedSubtitleMimeType enabled=$subtitlePlaybackEnabled"
                )
                if (hasText != hasEmbeddedSubtitles) {
                    hasEmbeddedSubtitles = hasText
                    updateSubtitleRendererVisibility()
                    updateSubtitleButtonStyle()
                    updateSubtitleDrawerUi()
                }

                if (hasText && !userDisabledSubtitles && !didAutoEnableEmbeddedSubtitles && selectedSubtitleUri == null) {
                    didAutoEnableEmbeddedSubtitles = true
                    setSubtitlePlaybackEnabled(true)
                    showOverlay("Subtitles On")
                }
            }

            override fun onCues(cueGroup: CueGroup) {
                Log.d(SUBTITLE_LOG_TAG, "ON_CUES fired count=${cueGroup.cues.size}") 
                val cueText =
                    cueGroup.cues
                        .mapNotNull { cue -> cue.text?.toString()?.trim()?.takeIf { it.isNotBlank() } }
                        .joinToString("\n")
                Log.d(
                    SUBTITLE_LOG_TAG,
                    "on_cues count=${cueGroup.cues.size} enabled=$subtitlePlaybackEnabled text=${cueText.take(120)}"
                )
                post {
                    if (subtitlePlaybackEnabled) {
                        subtitleView.setCues(cueGroup.cues)
                        activeSubtitleText = cueText
                        subtitleFallbackText.text = cueText
                        subtitleFallbackText.visibility =
                            if (cueText.isNotBlank()) View.VISIBLE else View.GONE
                        subtitleFallbackText.bringToFront()
                        subtitleFallbackText.requestLayout()
                        subtitleFallbackText.invalidate()
                        showSubtitleCuePopup(cueText)
                    } else {
                        subtitleView.setCues(emptyList())
                        activeSubtitleText = ""
                        subtitleFallbackText.text = ""
                        subtitleFallbackText.visibility = View.GONE
                        hideSubtitleCuePopup()
                    }
                }
            }

            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {

                val width = videoSize.width
                val height = videoSize.height

                if (width == 0 || height == 0) return

                isVideoVertical = height > width

                post {
                    applyVideoOrientation(width, height)
                    adjustVideoLayout()
                }
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int
            ) {
                updateProgressUi()
                maybeRefreshCacheStats(force = true)
            }
        })

        post(object : Runnable {

            override fun run() {

                if (controlsVisible) {
                    updateProgressUi()
                }
                savePlaybackState()

                postDelayed(this, 250)
            }
        })
    }

    private fun adjustVideoLayout() {

        val params = textureView.layoutParams as LayoutParams

        if (isVideoVertical) {

            params.width = LayoutParams.WRAP_CONTENT
            params.height = LayoutParams.MATCH_PARENT
            params.gravity = Gravity.CENTER

        } else {

            params.width = LayoutParams.MATCH_PARENT
            params.height = LayoutParams.MATCH_PARENT
            params.gravity = Gravity.CENTER
        }

        textureView.layoutParams = params
        textureView.post { applyVideoZoom() }
    }

    private fun applyVideoOrientation(videoWidth: Int, videoHeight: Int) {
        val activity = reactContext.currentActivity ?: return
        if (originalRequestedOrientation == null) {
            originalRequestedOrientation = activity.requestedOrientation
        }

        val target = if (videoHeight > videoWidth) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }

        if (appliedRequestedOrientation != target) {
            activity.requestedOrientation = target
            appliedRequestedOrientation = target
            Log.d("GestureDebug", "VIDEO_ORIENTATION_APPLIED target=$target w=$videoWidth h=$videoHeight")
        }
    }

    private fun restoreOriginalOrientation() {
        val activity = reactContext.currentActivity ?: return
        val original = originalRequestedOrientation ?: return
        activity.requestedOrientation = original
        Log.d("GestureDebug", "VIDEO_ORIENTATION_RESTORED original=$original")
        originalRequestedOrientation = null
        appliedRequestedOrientation = null
    }

    private fun format(ms: Long): String {

        val total = ms / 1000
        val min = total / 60
        val sec = total % 60

        return String.format("%02d:%02d", min, sec)
    }

    // ---------------- PUBLIC ----------------

    fun setSource(uri: String) {
        loadMedia(VideoSourceEntry(uri = uri, title = playerTitle), currentIndex)
        postDelayed({ hideControls() }, 1000)
    }

    fun pause() {
        player.pause()
        playBtn.setImageResource(R.drawable.ic_play_arrow_player)
    }

    fun play() {
        registerAsActivePlayerView()
        player.play()
        playBtn.setImageResource(R.drawable.ic_pause_player)
    }

    fun cleanup() {
        savePlaybackState(force = true)
        hideHandler.removeCallbacksAndMessages(null)
        resetLockUiState()
        subtitleDrawerDialog?.dismiss()
        subtitleSearchDialog?.dismiss()
        hideSubtitleCuePopup()
        hidePopupHud()
        restoreOriginalOrientation()
        if (pendingSubtitlePickerView?.get() === this) {
            pendingSubtitlePickerView = null
        }
        if (activePlaybackView?.get() === this) {
            activePlaybackView = null
        }
        isAwaitingSubtitlePickerResult = false
        reactContext.removeActivityEventListener(subtitlePickerListener)
        reactContext.removeLifecycleEventListener(this)
        uiScope.cancel()
        player.release()
    }

    fun setResumePlaybackEnabled(enabled: Boolean) {
        resumePlaybackEnabled = enabled
        syncResumeStateForCurrentMedia()
    }

    fun setTitle(title: String?) {
        playerTitle = title?.trim()?.takeIf { it.isNotEmpty() }
        val currentEntry = videoQueue.getOrNull(currentIndex)
        if (currentEntry != null) {
            updateDisplayedTitle(currentEntry)
        } else {
            fileNameText.text = playerTitle ?: "Now Playing"
        }
    }

    fun setControlsEnabled(enabled: Boolean) {
        controlsEnabled = enabled
        updateControlsToolVisibility()
    }

    fun setEnableSubtitle(enabled: Boolean) {
        enableSubtitle = enabled
        updateControlsToolVisibility()
    }

    fun setProgressColor(color: Int) {

        seekBar.progressTintList = ColorStateList.valueOf(color)
    }

    fun setTrackColor(color: Int) {

        seekBar.progressBackgroundTintList = ColorStateList.valueOf(color)
    }

    override fun onDetachedFromWindow() {
        resetLockUiState()
        subtitleDrawerDialog?.dismiss()
        subtitleSearchDialog?.dismiss()
        hideSubtitleCuePopup()
        if (pendingSubtitlePickerView?.get() === this) {
            pendingSubtitlePickerView = null
        }
        if (activePlaybackView?.get() === this) {
            activePlaybackView = null
        }
        isAwaitingSubtitlePickerResult = false
        uiScope.cancel()
        super.onDetachedFromWindow()
    }

    fun setThumbColor(color: Int) {

        seekBar.thumbTintList = ColorStateList.valueOf(color)
    }

    fun setButtonTintColor(color: Int) {
        buttonTintColor = color
        refreshButtonTintUi()
        bufferLoader.indeterminateTintList = ColorStateList.valueOf(color)
    }

    fun setDurationColor(color: Int) {
        currentText.setTextColor(Color.WHITE)
        durationText.setTextColor(Color.WHITE)
    }

    fun setSubtitleColor(color: Int) {
        subtitleTextColor = color
        applySubtitleAppearance()
        if (activeSubtitleText.isNotBlank()) {
            subtitleCuePopupText.text = activeSubtitleText
            subtitleFallbackText.text = activeSubtitleText
        }
    }

    fun setSubtitleCheckboxColor(color: Int) {
        subtitleCheckboxColor = color
        subtitleSelectedCheck.buttonTintList = ColorStateList.valueOf(color)
        updateSubtitleDrawerUi()
    }

    fun setSubtitleDescriptionColor(color: Int) {
        subtitleDescriptionColor = color
        subtitleSelectedMeta.setTextColor(
            currentSubtitleDescriptionColor(
                subtitleSelectedCheck.isChecked && subtitleSelectedCard.isVisible
            )
        )
        updateSubtitleDrawerUi()
    }

    fun setSource(list: List<VideoSourceEntry>) {

        val playerUri =
            player.currentMediaItem?.localConfiguration?.uri?.toString()

        val previousUri =
            if (currentIndex in videoQueue.indices) videoQueue[currentIndex].uri else playerUri

        videoQueue.clear()
        shuffledQueue.clear()
        shuffledQueuePosition = -1

        list.forEach { entry ->
            if (entry.uri.isNotBlank()) {
                videoQueue.add(entry)
            }
        }

        if (pendingIndex != null) {
            currentIndex = pendingIndex!!.coerceIn(0, videoQueue.size - 1)
            pendingIndex = null
        } else {
            val savedUri = playbackPrefs.getString("last_uri", null)
            val savedIndex = playbackPrefs.getInt("last_index", -1)
            currentIndex = when {
                savedUri != null && videoQueue.any { it.uri == savedUri } ->
                    videoQueue.indexOfFirst { it.uri == savedUri }

                savedIndex in videoQueue.indices ->
                    savedIndex

                previousUri != null && videoQueue.any { it.uri == previousUri } ->
                    videoQueue.indexOfFirst { it.uri == previousUri }

                currentIndex in videoQueue.indices ->
                    currentIndex

                else -> 0
            }
        }

        if (videoQueue.isNotEmpty()) {
            if (isShuffleEnabled) {
                rebuildShuffledQueue(currentIndex)
            }
            updateDisplayedTitle(videoQueue[currentIndex])
            playCurrent()
        } else {
            currentIndex = 0
            fileNameText.text = playerTitle ?: "Now Playing"
        }
    }

    fun setIndex(index: Int) {

        pendingIndex = index

        if (videoQueue.isNotEmpty()) {
            currentIndex = index.coerceIn(0, videoQueue.size - 1)
            pendingIndex = null
            if (isShuffleEnabled) {
                rebuildShuffledQueue(currentIndex)
            }
            playCurrent()
        }
    }

    private fun playCurrent() {

        if (currentIndex in videoQueue.indices) {
            loadMedia(videoQueue[currentIndex], currentIndex)
        }
    }

    private fun updateDisplayedTitle(entry: VideoSourceEntry) {
        val resolvedTitle = playerTitle
            ?.takeIf { it.isNotBlank() }
            ?: entry.title?.takeIf { it.isNotBlank() }
            ?: Uri.parse(entry.uri).lastPathSegment?.let { Uri.decode(it) }
            ?: "Now Playing"
        fileNameText.text = resolvedTitle
    }

    private fun sendEvent(name: String, map: WritableMap) {

        val dispatcher =
            UIManagerHelper.getEventDispatcherForReactTag(reactContext, id)
        val surfaceId = UIManagerHelper.getSurfaceId(this)

        dispatcher?.dispatchEvent(object : Event<Nothing>(surfaceId, id) {

            override fun getEventName() = name

            override fun getEventData() = map
        })
    }
}
