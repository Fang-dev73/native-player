package com.nyjs.nativeplayer

import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager
import androidx.media3.common.util.UnstableApi

@OptIn(UnstableApi::class)
class NativePlayerPackage : ReactPackage {
    override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> =
        listOf(VideoPlayerManager())

    override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> =
        listOf(MediaScannerModule(reactContext))
}