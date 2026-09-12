package com.limitless.pocket

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Spins up a long-lived FlutterEngine at process start so the first
 * frame is fast — no Dart isolate warm-up when MainActivity comes up.
 * The same engine is reused by MainActivity via FlutterEngineCache, so
 * Riverpod scopes and DB connections live for the lifetime of the
 * process.
 */
class PocketApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "pocket_engine"
    }
}
