package com.nyjs.nativeplayer

import androidx.media3.common.util.UnstableApi
import com.facebook.react.bridge.Dynamic
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

@OptIn(UnstableApi::class)
class VideoPlayerManager : SimpleViewManager<VideoPlayerView>() {

    override fun getName() = "RNVideoPlayer"

    override fun createViewInstance(reactContext: ThemedReactContext): VideoPlayerView =
        VideoPlayerView(reactContext)

    override fun onDropViewInstance(view: VideoPlayerView) {
        super.onDropViewInstance(view)
        view.cleanup()
    }

    @ReactProp(name = "paused")
    fun setPaused(view: VideoPlayerView, paused: Boolean) {
        if (paused) view.pause() else view.play()
    }

    @ReactProp(name = "controls", defaultBoolean = true)
    fun setControls(view: VideoPlayerView, enabled: Boolean) {
        view.setControlsEnabled(enabled)
    }

    @ReactProp(name = "enableSubtitle", defaultBoolean = false)
    fun setEnableSubtitle(view: VideoPlayerView, enabled: Boolean) {
        view.setEnableSubtitle(enabled)
    }

    @ReactProp(name = "progressColor", customType = "Color")
    fun setProgressColor(view: VideoPlayerView, color: Int) {
        view.setProgressColor(color)
    }

    @ReactProp(name = "trackColor", customType = "Color")
    fun setTrackColor(view: VideoPlayerView, color: Int) {
        view.setTrackColor(color)
    }

    @ReactProp(name = "thumbColor", customType = "Color")
    fun setThumbColor(view: VideoPlayerView, color: Int) {
        view.setThumbColor(color)
    }

    @ReactProp(name = "buttonTintColor", customType = "Color")
    fun setButtonTintColor(view: VideoPlayerView, color: Int) {
        view.setButtonTintColor(color)
    }

    @ReactProp(name = "durationColor", customType = "Color")
    fun setDurationColor(view: VideoPlayerView, color: Int) {
        view.setDurationColor(color)
    }

    @ReactProp(name = "subtitleColor", customType = "Color")
    fun setSubtitleColor(view: VideoPlayerView, color: Int) {
        view.setSubtitleColor(color)
    }

    @ReactProp(name = "subtitleCheckboxColor", customType = "Color")
    fun setSubtitleCheckboxColor(view: VideoPlayerView, color: Int) {
        view.setSubtitleCheckboxColor(color)
    }

    @ReactProp(name = "subtitleDescriptionColor", customType = "Color")
    fun setSubtitleDescriptionColor(view: VideoPlayerView, color: Int) {
        view.setSubtitleDescriptionColor(color)
    }

    @ReactProp(name = "source")
    fun setSource(view: VideoPlayerView, source: Dynamic?) {
        view.setSource(parseSourceList(source))
    }

    @ReactProp(name = "index")
    fun setIndex(view: VideoPlayerView, index: Int) {
        view.setIndex(index)
    }

    @ReactProp(name = "title")
    fun setTitle(view: VideoPlayerView, title: String?) {
        view.setTitle(title)
    }

    @ReactProp(name = "resumePlaybackEnabled")
    fun setResumePlaybackEnabled(view: VideoPlayerView, enabled: Boolean) {
        view.setResumePlaybackEnabled(enabled)
    }

    override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> {
        return mutableMapOf(
            "onLoad"     to mutableMapOf("registrationName" to "onLoad"),
            "onProgress" to mutableMapOf("registrationName" to "onProgress"),
            "onVideoEnd" to mutableMapOf("registrationName" to "onVideoEnd"),
            "onBack"     to mutableMapOf("registrationName" to "onBack"),  // ← was missing
        )
    }

    private fun parseSourceList(source: Dynamic?): List<VideoSourceEntry> {
        if (source == null || source.isNull) return emptyList()
        return when (source.type) {
            ReadableType.Array  -> parseSourceArray(source.asArray())
            ReadableType.Map    -> parseSourceMap(source.asMap())?.let(::listOf) ?: emptyList()
            ReadableType.String -> parseSourceString(source.asString())?.let(::listOf) ?: emptyList()
            else -> emptyList()
        }
    }

    private fun parseSourceArray(array: ReadableArray?): List<VideoSourceEntry> {
        if (array == null) return emptyList()
        val items = mutableListOf<VideoSourceEntry>()
        for (i in 0 until array.size()) {
            when (array.getType(i)) {
                ReadableType.String -> parseSourceString(array.getString(i))?.let(items::add)
                ReadableType.Map    -> parseSourceMap(array.getMap(i))?.let(items::add)
                else -> Unit
            }
        }
        return items
    }

    private fun parseSourceMap(map: ReadableMap?): VideoSourceEntry? {
        if (map == null || !map.hasKey("uri") || map.isNull("uri")) return null
        val uri = map.getString("uri")?.trim().orEmpty().takeIf { it.isNotEmpty() } ?: return null
        val title = if (map.hasKey("title") && !map.isNull("title"))
            map.getString("title")?.trim()?.takeIf { it.isNotEmpty() } else null
        return VideoSourceEntry(uri = uri, title = title)
    }

    private fun parseSourceString(value: String?): VideoSourceEntry? {
        val uri = value?.trim().orEmpty()
        return uri.takeIf { it.isNotEmpty() }?.let { VideoSourceEntry(uri = it) }
    }
}