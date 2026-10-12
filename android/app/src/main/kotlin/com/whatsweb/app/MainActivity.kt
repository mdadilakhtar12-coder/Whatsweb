package com.whatsweb.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CallLog
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "whatsweb/phone")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "call" -> placeCall(call, result)
                    "hasCallLog" -> result.success(canReadCallLog())
                    "callLog" -> readCallLog(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun canReadCallLog(): Boolean =
        checkSelfPermission(Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED

    private fun placeCall(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("number")
        if (number.isNullOrBlank()) {
            result.error("NO_NUMBER", "Phone number missing", null)
            return
        }
        // Call straight away when allowed; otherwise open the dialer with the number.
        val canCall = checkSelfPermission(Manifest.permission.CALL_PHONE) ==
            PackageManager.PERMISSION_GRANTED
        val action = if (canCall) Intent.ACTION_CALL else Intent.ACTION_DIAL
        try {
            startActivity(Intent(action, Uri.parse("tel:" + Uri.encode(number))))
            result.success(canCall)
        } catch (e: Exception) {
            result.error("CALL_FAILED", e.message, null)
        }
    }

    /** Calls newer than `since` (ms), oldest first. null = no permission to read the call log. */
    private fun readCallLog(call: MethodCall, result: MethodChannel.Result) {
        if (!canReadCallLog()) {
            result.success(null)
            return
        }
        val since = call.argument<Number>("since")?.toLong() ?: 0L
        val calls = ArrayList<Map<String, Any?>>()
        try {
            contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DURATION, CallLog.Calls.DATE),
                "${CallLog.Calls.DATE} > ?",
                arrayOf(since.toString()),
                "${CallLog.Calls.DATE} ASC",
            )?.use { cursor ->
                while (cursor.moveToNext() && calls.size < 500) {
                    val direction = when (cursor.getInt(1)) {
                        CallLog.Calls.OUTGOING_TYPE -> "out"
                        CallLog.Calls.INCOMING_TYPE -> "in"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE -> "rejected"
                        else -> null
                    }
                    if (direction != null) {
                        calls.add(
                            mapOf(
                                "number" to cursor.getString(0),
                                "direction" to direction,
                                "duration" to cursor.getLong(2),
                                "at" to cursor.getLong(3),
                            ),
                        )
                    }
                }
            }
            result.success(calls)
        } catch (e: Exception) {
            result.error("CALL_LOG_FAILED", e.message, null)
        }
    }
}
