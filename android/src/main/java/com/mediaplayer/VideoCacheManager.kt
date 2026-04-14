package com.nyjs.nativeplayer

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

data class VideoCacheStats(
    val cachedBytes: Long = 0L,
    val contentLength: Long = C.LENGTH_UNSET.toLong(),
    val cachedPercent: Int = 0
)

@UnstableApi
object VideoCacheManager {
    private const val CACHE_DIR_NAME = "streaming-video-cache"
    private const val MAX_CACHE_SIZE_BYTES = 768L * 1024L * 1024L
    private const val CACHE_FRAGMENT_SIZE_BYTES = 2L * 1024L * 1024L
    private const val CACHE_WRITE_BUFFER_BYTES = 256 * 1024
    private const val CONNECT_TIMEOUT_MS = 12_000
    private const val READ_TIMEOUT_MS = 30_000
    private const val USER_AGENT = "MediaPlayer/1.0 (Android Media3 Cache)"

    @Volatile
    private var simpleCache: SimpleCache? = null

    @Volatile
    private var databaseProvider: StandaloneDatabaseProvider? = null

    fun buildCacheDataSourceFactory(context: Context): CacheDataSource.Factory {
        val appContext = context.applicationContext
        val cache = getCache(appContext)
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(CONNECT_TIMEOUT_MS)
            .setReadTimeoutMs(READ_TIMEOUT_MS)
        val upstreamFactory = DefaultDataSource.Factory(appContext, httpFactory)
        val cacheWriteFactory = CacheDataSink.Factory()
            .setCache(cache)
            .setFragmentSize(CACHE_FRAGMENT_SIZE_BYTES)
            .setBufferSize(CACHE_WRITE_BUFFER_BYTES)

        return CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheWriteDataSinkFactory(cacheWriteFactory)
            .setCacheKeyFactory { dataSpec -> normalizeCacheKey(dataSpec.uri) }
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    fun getCacheStats(context: Context, uriString: String?): VideoCacheStats {
        if (uriString.isNullOrBlank() || !isRemoteUri(uriString)) {
            return VideoCacheStats()
        }

        val cache = getCache(context.applicationContext)
        val cacheKey = normalizeCacheKey(Uri.parse(uriString))
        val metadata = cache.getContentMetadata(cacheKey)
        val contentLength = ContentMetadata.getContentLength(metadata)
        val cachedBytes = cache.getCachedBytes(cacheKey, 0L, C.LENGTH_UNSET.toLong())
        val cachedPercent =
            if (contentLength > 0L) {
                ((cachedBytes * 100L) / contentLength).toInt().coerceIn(0, 100)
            } else {
                0
            }

        return VideoCacheStats(
            cachedBytes = cachedBytes.coerceAtLeast(0L),
            contentLength = contentLength,
            cachedPercent = cachedPercent
        )
    }

    fun isRemoteUri(uriString: String?): Boolean {
        if (uriString.isNullOrBlank()) {
            return false
        }
        val scheme = Uri.parse(uriString).scheme?.lowercase()
        return scheme == "http" || scheme == "https"
    }

    private fun getCache(context: Context): SimpleCache {
        simpleCache?.let { return it }

        return synchronized(this) {
            simpleCache?.let { return@synchronized it }

            val provider =
                databaseProvider ?: StandaloneDatabaseProvider(context).also {
                    databaseProvider = it
                }
            val cacheDirectory = File(context.cacheDir, CACHE_DIR_NAME)
            if (!cacheDirectory.exists()) {
                cacheDirectory.mkdirs()
            }

            SimpleCache(
                cacheDirectory,
                LeastRecentlyUsedCacheEvictor(MAX_CACHE_SIZE_BYTES),
                provider
            ).also { simpleCache = it }
        }
    }

    private fun normalizeCacheKey(uri: Uri): String {
        val builder = uri.buildUpon().fragment(null)
        return builder.build().toString()
    }
}
