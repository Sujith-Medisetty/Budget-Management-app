package com.limitless.pocket

import io.flutter.embedding.android.FlutterActivity

/**
 * Reuses the long-lived FlutterEngine created in [PocketApplication].
 * Because we use the cached engine, configureFlutterEngine is not
 * invoked here — MethodChannel handlers are registered in
 * PocketApplication so they exist from process start.
 */
class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = PocketApplication.ENGINE_ID
}