package com.nyjs.nativeplayer

import android.content.ContentUris
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File

class MediaScannerModule(private val reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    private var contentObserver: ContentObserver? = null

    override fun getName(): String {
        return "MediaScanner"
    }

    @ReactMethod
    fun getVideos(promise: Promise) {
        try {
            val videoList = Arguments.createArray()

            val projection = mutableListOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Video.Media.DATE_ADDED
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                projection.add(MediaStore.Video.Media.RELATIVE_PATH)
            } else {
                @Suppress("DEPRECATION")
                projection.add(MediaStore.Video.Media.DATA)
            }

            val cursor = reactContext.contentResolver.query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                projection.toTypedArray(),
                null,
                null,
                "${MediaStore.Video.Media.DATE_ADDED} DESC"
            )

            cursor?.use {
                val idIndex = it.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val nameIndex = it.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
                val durationIndex = it.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
                val bucketIndex = it.getColumnIndexOrThrow(MediaStore.Video.Media.BUCKET_DISPLAY_NAME)
                val dateAddedIndex = it.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
                val relativePathIndex =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        it.getColumnIndex(MediaStore.Video.Media.RELATIVE_PATH)
                    } else {
                        -1
                    }
                val filePathIndex =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        -1
                    } else {
                        @Suppress("DEPRECATION")
                        it.getColumnIndex(MediaStore.Video.Media.DATA)
                    }

                while (it.moveToNext()) {

                    val id = it.getLong(idIndex)
                    val name = it.getString(nameIndex)
                    val duration = it.getLong(durationIndex)
                    val bucketName = it.getString(bucketIndex)
                    val dateAdded = it.getLong(dateAddedIndex)
                    val relativePath =
                        if (relativePathIndex >= 0) it.getString(relativePathIndex) else null
                    val filePath =
                        if (filePathIndex >= 0) it.getString(filePathIndex) else null
                    val folderPath = resolveFolderPath(relativePath, filePath, bucketName)
                    val folderName = resolveFolderName(folderPath, bucketName)

                    val contentUri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    val uri = ContentUris.withAppendedId(contentUri, id)

                    val thumbnailPath = uri.toString()

                    val video = Arguments.createMap()
                    video.putString("id", id.toString())
                    video.putString("name", name)
                    video.putDouble("duration", duration.toDouble())
                    video.putString("folder", folderName)
                    video.putString("folderPath", folderPath)
                    video.putString("uri", uri.toString())
                    video.putString("thumbnail", thumbnailPath)
                    video.putDouble("dateAdded", dateAdded.toDouble())

                    videoList.pushMap(video)
                }
            }

            promise.resolve(videoList)

        } catch (e: Exception) {
            promise.reject("VIDEO_ERROR", e.message)
        }
    }

    @ReactMethod
    fun startObserving() {
        if (contentObserver != null) return

        contentObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                sendEvent("mediaUpdated")
            }
        }

        reactContext.contentResolver.registerContentObserver(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            true,
            contentObserver!!
        )
    }

    @ReactMethod
    fun stopObserving() {
        contentObserver?.let {
            reactContext.contentResolver.unregisterContentObserver(it)
        }
        contentObserver = null
    }

    private fun sendEvent(eventName: String) {
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, null)
    }

    private fun resolveFolderPath(
        relativePath: String?,
        filePath: String?,
        bucketName: String?
    ): String {
        val sanitizedRelativePath = relativePath
            ?.trim()
            ?.trim('/')
            ?.takeIf { it.isNotEmpty() }

        if (sanitizedRelativePath != null) {
            return sanitizedRelativePath
        }

        val absoluteParentPath = filePath
            ?.let { File(it).parentFile?.absolutePath }
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

        if (absoluteParentPath != null) {
            return absoluteParentPath
        }

        return bucketName?.takeIf { it.isNotBlank() } ?: "Unknown"
    }

    private fun resolveFolderName(folderPath: String, bucketName: String?): String {
        val normalized = folderPath.trim().trim('/').takeIf { it.isNotEmpty() }
        if (normalized != null) {
            return normalized.substringAfterLast('/')
        }

        return bucketName?.takeIf { it.isNotBlank() } ?: "Unknown"
    }
}
