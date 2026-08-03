package com.psmjewellers.psm_jewellers_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val pdfFileSaverChannel = "psm_jewellers_app/pdf_file_saver"
    private val createPdfRequestCode = 7310
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingPdfBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            pdfFileSaverChannel
        ).setMethodCallHandler { call, result ->
            if (call.method != "savePdfFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (pendingSaveResult != null) {
                result.error("busy", "Another PDF save is already open", null)
                return@setMethodCallHandler
            }

            val bytes = call.argument<ByteArray>("bytes")
            val fileName = call.argument<String>("fileName") ?: "psm_jewellers_register.pdf"
            if (bytes == null || bytes.isEmpty()) {
                result.error("invalid_pdf", "PDF data is missing", null)
                return@setMethodCallHandler
            }

            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                putExtra(Intent.EXTRA_TITLE, fileName)
            }

            pendingSaveResult = result
            pendingPdfBytes = bytes

            try {
                startActivityForResult(intent, createPdfRequestCode)
            } catch (error: ActivityNotFoundException) {
                clearPendingPdfSave()
                result.error("no_file_app", "No Files app found to save PDF", null)
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != createPdfRequestCode) {
            return
        }

        val result = pendingSaveResult ?: return
        val bytes = pendingPdfBytes
        val uri = data?.data

        if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) {
            clearPendingPdfSave()
            result.success(false)
            return
        }

        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IllegalStateException("Unable to open selected file")
            result.success(true)
        } catch (error: Exception) {
            result.error("save_failed", error.localizedMessage ?: "Unable to save PDF", null)
        } finally {
            clearPendingPdfSave()
        }
    }

    private fun clearPendingPdfSave() {
        pendingSaveResult = null
        pendingPdfBytes = null
    }
}
