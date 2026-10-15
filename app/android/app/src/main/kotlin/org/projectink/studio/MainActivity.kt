package org.projectink.studio

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Debug
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val pointerAdapter = InkPointerAdapter()
    private var stylusButtonDown = false
    private var providerResult: MethodChannel.Result? = null
    private var liveTextureRegistry: InkLiveTextureRegistry? = null
    // Session-local capabilities: a rejected Open must not retire the current source.
    private val providerImports = mutableMapOf<String, ProviderImport>()
    private var activeProviderPngExport: ProviderPngExport? = null

    private companion object {
        const val PROVIDER_CHANNEL = "org.projectink.studio/provider_documents_v1"
        const val OPEN_PROVIDER_PROJECT = 1901
        const val MAX_PROVIDER_ENTRIES = 100_000
        const val MAX_PROVIDER_BYTES = 1L shl 30
        const val MAX_PROVIDER_DEPTH = 64
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.projectink.studio/pointer_packets_v1",
        ).setStreamHandler(InkPointerEventStream)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.projectink.studio/pointer_status_v1",
        ).setStreamHandler(InkPointerStatusEventStream)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.projectink.studio/pencil_commands_v1",
        ).setStreamHandler(InkPencilCommandEventStream)
        val liveTextures = InkLiveTextureRegistry(flutterEngine.renderer)
        liveTextureRegistry = liveTextures
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.projectink.studio/live_texture_v1",
        ).setMethodCallHandler { call, result ->
            liveTextures.handle(call, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROVIDER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openProject" -> openProviderProject(result)
                "commitProject" -> commitProviderProject(call.argument("localPath"), result)
                "preparePngExport" -> prepareProviderPngExport(
                    call.argument("suggestedName"),
                    call.argument("localProjectPath"),
                    result,
                )
                "commitPng" -> commitProviderPng(call.argument("localPath"), result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.projectink.studio/performance_v1",
        ).setMethodCallHandler { call, result ->
            if (call.method == "readRssBytes") {
                // Android exposes proportional set size (PSS) reliably to an
                // app. It is a useful process-memory estimate, while the
                // acceptance runbook still treats dumpsys meminfo as the
                // authoritative RSS measurement.
                result.success(Debug.getPss() * 1024L)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        liveTextureRegistry?.close()
        liveTextureRegistry = null
        super.onDestroy()
    }

    private fun openProviderProject(result: MethodChannel.Result) {
        if (providerResult != null) {
            result.error("busy", "A provider picker is already open.", null)
            return
        }
        providerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        try {
            startActivityForResult(intent, OPEN_PROVIDER_PROJECT)
        } catch (error: Exception) {
            providerResult = null
            result.error("unavailable", error.message, null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != OPEN_PROVIDER_PROJECT) return
        val result = providerResult ?: return
        providerResult = null
        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // Some providers grant a temporary read permission only; the copy
            // below still runs while the activity grant is alive.
        }
        Thread {
            try {
                val imported = copyProviderProject(treeUri)
                runOnUiThread {
                    providerImports[imported.localPath.canonicalPath] = imported
                    activeProviderPngExport = null
                    result.success(
                        mapOf(
                            "path" to imported.localPath.absolutePath,
                            "canWriteBack" to (imported.parentDocumentId != null),
                        ),
                    )
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("copy_failed", error.message, null)
                }
            }
        }.start()
    }

    private data class ProviderEntry(
        val documentId: String,
        val displayName: String,
        val mimeType: String,
    )

    private data class CopyBudget(var entries: Int = 0, var bytes: Long = 0)

    private data class ProviderImport(
        val localPath: File,
        val treeUri: Uri,
        val parentDocumentId: String?,
        val sourceDocumentId: String,
        val sourceName: String,
    )

    private data class ProviderPngExport(
        val localPath: File,
        val treeUri: Uri,
        val parentDocumentId: String,
        val fileName: String,
    )

    private fun copyProviderProject(treeUri: Uri): ProviderImport {
        val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val root = documentInfo(treeUri, rootDocumentId)
        val source = if (isProjectName(root.displayName)) {
            root
        } else {
            val projects = children(treeUri, rootDocumentId).filter {
                it.mimeType == DocumentsContract.Document.MIME_TYPE_DIR &&
                    isProjectName(it.displayName)
            }
            if (projects.size != 1) {
                throw IOException("Select one .inkproj project folder.")
            }
            projects.single()
        }
        val imports = File(filesDir, "ProviderImports")
        if (!imports.exists() && !imports.mkdirs()) {
            throw IOException("Unable to create the provider import directory.")
        }
        val destination = uniqueSibling(imports, projectName(source.displayName), true)
        try {
            if (!destination.mkdirs()) {
                throw IOException("Unable to create the staged project directory.")
            }
            copyTree(treeUri, source.documentId, destination, CopyBudget(), 0)
            return ProviderImport(
                localPath = destination,
                treeUri = treeUri,
                parentDocumentId = if (source.documentId == rootDocumentId) null else rootDocumentId,
                sourceDocumentId = source.documentId,
                sourceName = source.displayName,
            )
        } catch (error: Exception) {
            destination.deleteRecursively()
            throw error
        }
    }

    private fun commitProviderProject(localPath: String?, result: MethodChannel.Result) {
        val imported = try {
            localPath?.let { providerImports[File(it).canonicalPath] }
        } catch (error: IOException) {
            result.error("invalid_path", error.message, null)
            return
        }
        activeProviderPngExport = null
        if (localPath == null || imported == null) {
            result.error("invalid_path", "No provider source is bound to this staged project.", null)
            return
        }
        if (imported.parentDocumentId == null) {
            result.success(null)
            return
        }
        val local = File(localPath)
        try {
            if (local.canonicalFile != imported.localPath.canonicalFile) {
                result.error("invalid_path", "The staged project path does not match.", null)
                return
            }
        } catch (error: IOException) {
            result.error("invalid_path", error.message, null)
            return
        }
        Thread {
            try {
                val updated = replaceProviderProject(imported, local)
                runOnUiThread {
                    providerImports[updated.localPath.canonicalPath] = updated
                    result.success(null)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("writeback_failed", error.message, null)
                }
            }
        }.start()
    }

    private fun prepareProviderPngExport(
        suggestedName: String?,
        localProjectPath: String?,
        result: MethodChannel.Result,
    ) {
        val imported = try {
            localProjectPath?.let { providerImports[File(it).canonicalPath] }
        } catch (error: IOException) {
            result.error("invalid_path", error.message, null)
            return
        }
        val parentDocumentId = imported?.parentDocumentId
        if (imported == null || parentDocumentId == null) {
            result.success(null)
            return
        }
        val requestedName = pngName(suggestedName ?: "untitled.png")
        val exports = File(filesDir, "ProviderExports")
        try {
            if (!exports.exists() && !exports.mkdirs()) {
                throw IOException("Unable to create the provider export directory.")
            }
            val local = uniqueSibling(exports, requestedName, false)
            if (!local.createNewFile()) {
                throw IOException("Unable to create a local PNG export.")
            }
            activeProviderPngExport = ProviderPngExport(
                localPath = local,
                treeUri = imported.treeUri,
                parentDocumentId = parentDocumentId,
                fileName = local.name,
            )
            result.success(
                mapOf(
                    "path" to local.absolutePath,
                    "canWriteBack" to true,
                ),
            )
        } catch (error: Exception) {
            result.error("export_unavailable", error.message, null)
        }
    }

    private fun commitProviderPng(localPath: String?, result: MethodChannel.Result) {
        val export = activeProviderPngExport
        if (localPath == null || export == null) {
            result.success(null)
            return
        }
        val local = File(localPath)
        try {
            if (local.canonicalFile != export.localPath.canonicalFile) {
                result.error("invalid_path", "The staged PNG path does not match.", null)
                return
            }
        } catch (error: IOException) {
            result.error("invalid_path", error.message, null)
            return
        }
        Thread {
            try {
                publishProviderPng(export, local)
                runOnUiThread {
                    activeProviderPngExport = null
                    result.success(null)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("writeback_failed", error.message, null)
                }
            }
        }.start()
    }

    private fun publishProviderPng(export: ProviderPngExport, local: File) {
        if (!local.isFile) throw IOException("The staged PNG is missing.")
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(
            export.treeUri,
            export.parentDocumentId,
        )
        val destinationName = nextProviderFileName(
            export.treeUri,
            export.parentDocumentId,
            export.fileName,
        )
        val tempName = ".${destinationName}.tmp-${System.nanoTime()}.png"
        val tempUri = DocumentsContract.createDocument(
            contentResolver,
            parentUri,
            "image/png",
            tempName,
        ) ?: throw IOException("The provider cannot create a PNG export.")
        try {
            local.inputStream().use { input ->
                contentResolver.openOutputStream(tempUri)?.use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var bytes = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        bytes += count
                        if (bytes > MAX_PROVIDER_BYTES) {
                            throw IOException("The PNG export exceeds the write limit.")
                        }
                        output.write(buffer, 0, count)
                    }
                } ?: throw IOException("The provider cannot open the PNG destination.")
            }
            DocumentsContract.renameDocument(contentResolver, tempUri, destinationName)
                ?: throw IOException("The provider cannot publish the PNG export.")
            local.delete()
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(contentResolver, tempUri) }
            throw error
        }
    }

    private fun nextProviderFileName(
        treeUri: Uri,
        parentDocumentId: String,
        requested: String,
    ): String {
        val existing = children(treeUri, parentDocumentId).map { it.displayName }.toHashSet()
        if (requested !in existing) return requested
        val extension = extensionOf(requested)
        val base = requested.removeSuffix(extension)
        var index = 2
        while ("$base-$index$extension" in existing) index++
        return "$base-$index$extension"
    }

    private fun replaceProviderProject(imported: ProviderImport, local: File): ProviderImport {
        val parentDocumentId = imported.parentDocumentId
            ?: throw IOException("The selected provider folder cannot be written.")
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(
            imported.treeUri,
            parentDocumentId,
        )
        val tempName = "${safeName(imported.sourceName)}.tmp-${System.nanoTime()}"
        val tempUri = DocumentsContract.createDocument(
            contentResolver,
            parentUri,
            DocumentsContract.Document.MIME_TYPE_DIR,
            tempName,
        ) ?: throw IOException("The provider cannot create a transactional folder.")
        var backupUri: Uri? = null
        try {
            copyLocalTree(
                local,
                tempUri,
                CopyBudget(),
                0,
            )
            val sourceUri = DocumentsContract.buildDocumentUriUsingTree(
                imported.treeUri,
                imported.sourceDocumentId,
            )
            val backupName = "${safeName(imported.sourceName)}.backup-${System.nanoTime()}"
            backupUri = DocumentsContract.renameDocument(contentResolver, sourceUri, backupName)
                ?: throw IOException("The provider cannot stage the original project.")
            try {
                val promoted = DocumentsContract.renameDocument(
                    contentResolver,
                    tempUri,
                    imported.sourceName,
                ) ?: throw IOException("The provider cannot publish the new project.")
                val promotedSourceId = DocumentsContract.getDocumentId(promoted)
                runCatching { DocumentsContract.deleteDocument(contentResolver, backupUri) }
                return imported.copy(sourceDocumentId = promotedSourceId)
            } catch (error: Exception) {
                DocumentsContract.renameDocument(contentResolver, backupUri, imported.sourceName)
                throw error
            }
        } catch (error: Exception) {
            // If the temp folder still exists, it is safe to remove; the
            // original remains present unless the guarded promotion began.
            runCatching { DocumentsContract.deleteDocument(contentResolver, tempUri) }
            throw error
        }
    }

    private fun copyLocalTree(
        local: File,
        providerParent: Uri,
        budget: CopyBudget,
        depth: Int,
    ) {
        if (depth > MAX_PROVIDER_DEPTH) {
            throw IOException("The staged project directory nesting is too deep.")
        }
        val children = local.listFiles()?.sortedBy { it.name }
            ?: throw IOException("The staged project cannot be enumerated.")
        for (child in children) {
            budget.entries++
            if (budget.entries > MAX_PROVIDER_ENTRIES) {
                throw IOException("The staged project contains too many entries.")
            }
            if (Files.isSymbolicLink(child.toPath())) {
                throw IOException("The staged project cannot contain symbolic links.")
            }
            val name = safeName(child.name)
            val mime = if (child.isDirectory) {
                DocumentsContract.Document.MIME_TYPE_DIR
            } else {
                mimeTypeFor(child.name)
            }
            val target = DocumentsContract.createDocument(contentResolver, providerParent, mime, name)
                ?: throw IOException("The provider cannot create $name.")
            if (child.isDirectory) {
                copyLocalTree(child, target, budget, depth + 1)
            } else {
                writeProviderFile(child, target, budget)
            }
        }
    }

    private fun writeProviderFile(local: File, target: Uri, budget: CopyBudget) {
        local.inputStream().use { input ->
            contentResolver.openOutputStream(target)?.use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    budget.bytes += count
                    if (budget.bytes > MAX_PROVIDER_BYTES) {
                        throw IOException("The staged project exceeds the write limit.")
                    }
                    output.write(buffer, 0, count)
                }
            } ?: throw IOException("The provider cannot open the destination file.")
        }
    }

    private fun mimeTypeFor(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            name.substringAfterLast('.', "").lowercase(Locale.ROOT),
        ) ?: "application/octet-stream"

    private fun pngName(value: String): String {
        val safe = safeName(value)
        return if (safe.lowercase(Locale.ROOT).endsWith(".png")) safe else "$safe.png"
    }

    private fun documentInfo(treeUri: Uri, documentId: String): ProviderEntry {
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        contentResolver.query(documentUri, columns, null, null, null).use { cursor ->
            if (cursor == null || !cursor.moveToFirst()) {
                throw IOException("The provider did not return the selected folder.")
            }
            return ProviderEntry(
                documentId = cursor.getString(0),
                displayName = cursor.getString(1) ?: "imported",
                mimeType = cursor.getString(2) ?: "",
            )
        }
    }

    private fun children(treeUri: Uri, parentDocumentId: String): List<ProviderEntry> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId,
        )
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val entries = mutableListOf<ProviderEntry>()
        contentResolver.query(childrenUri, columns, null, null, null).use { cursor ->
            if (cursor == null) throw IOException("The provider cannot enumerate the folder.")
            while (cursor.moveToNext()) {
                if (entries.size >= MAX_PROVIDER_ENTRIES) {
                    throw IOException("The provider folder contains too many entries.")
                }
                entries += ProviderEntry(
                    documentId = cursor.getString(0),
                    displayName = cursor.getString(1) ?: "unnamed",
                    mimeType = cursor.getString(2) ?: "",
                )
            }
        }
        return entries
    }

    private fun copyTree(
        treeUri: Uri,
        sourceDocumentId: String,
        destination: File,
        budget: CopyBudget,
        depth: Int,
    ) {
        if (depth > MAX_PROVIDER_DEPTH) {
            throw IOException("The provider project directory nesting is too deep.")
        }
        for (entry in children(treeUri, sourceDocumentId)) {
            budget.entries++
            if (budget.entries > MAX_PROVIDER_ENTRIES) {
                throw IOException("The provider project contains too many entries.")
            }
            val target = uniqueSibling(destination, safeName(entry.displayName),
                entry.mimeType == DocumentsContract.Document.MIME_TYPE_DIR)
            if (entry.mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                if (!target.mkdirs()) throw IOException("Unable to create staged folder.")
                copyTree(treeUri, entry.documentId, target, budget, depth + 1)
            } else {
                copyFile(treeUri, entry.documentId, target, budget)
            }
        }
    }

    private fun copyFile(treeUri: Uri, documentId: String, target: File, budget: CopyBudget) {
        if (Files.isSymbolicLink(target.toPath()) || target.exists()) {
            throw IOException("The staged destination already exists.")
        }
        if (!target.createNewFile()) {
            throw IOException("Unable to create staged file.")
        }
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        val input = contentResolver.openInputStream(documentUri)
            ?: throw IOException("The provider did not expose a readable file.")
        input.use { source ->
            target.outputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = source.read(buffer)
                    if (count < 0) break
                    budget.bytes += count
                    if (budget.bytes > MAX_PROVIDER_BYTES) {
                        throw IOException("The provider project exceeds the import limit.")
                    }
                    output.write(buffer, 0, count)
                }
            }
        }
    }

    private fun uniqueSibling(parent: File, requested: String, directory: Boolean): File {
        val extension = if (directory) "" else extensionOf(requested)
        val base = if (directory) requested else requested.removeSuffix(extension)
        var candidate = File(parent, requested)
        var index = 2
        while (candidate.exists()) {
            candidate = File(parent, "$base-$index$extension")
            index++
        }
        return candidate
    }

    private fun projectName(value: String): String {
        val safe = safeName(value)
        return if (isProjectName(safe)) safe else "$safe.inkproj"
    }

    private fun isProjectName(value: String): Boolean =
        value.lowercase(Locale.ROOT).endsWith(".inkproj")

    private fun extensionOf(value: String): String {
        val index = value.lastIndexOf('.')
        return if (index >= 0) value.substring(index) else ""
    }

    private fun safeName(value: String): String {
        val cleaned = value
            .trim()
            .replace(Regex("[^A-Za-z0-9._ -]"), "_")
            .replace(Regex("\\.{2,}"), "_")
            .take(240)
        return if (cleaned.isBlank() || cleaned == "." || cleaned == "..") {
            "imported"
        } else {
            cleaned
        }
    }

    override fun dispatchTouchEvent(event: android.view.MotionEvent): Boolean {
        val buttonDown = pointerAdapter.isPrimaryButtonPressed(event)
        if (buttonDown && !stylusButtonDown) {
            InkPencilCommandEventStream.publish("toggleEraser")
        }
        stylusButtonDown = buttonDown
        // Let Flutter hit-test every S Pen contact so toolbar and layer-panel
        // controls receive stylus taps. Activity-level dispatch cannot tell
        // whether a contact landed on a canvas control or the drawing surface.
        return super.dispatchTouchEvent(event)
    }
}
