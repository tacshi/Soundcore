package com.anker.anker_recorder

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.anker.anker_recorder/background_sync",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        RecordingSyncService.start(applicationContext)
                        result.success(null)
                    }
                    "stop" -> {
                        RecordingSyncService.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error(
                    "background_sync_error",
                    error.message ?: "Background sync service failed",
                    null,
                )
            }
        }
    }
}
