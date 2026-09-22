package tech.acab.app.ui

import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * How long a share package may outlive its export. Packages are NOT deleted when the chooser
 * closes, because the receiving app (an email draft, a file manager, a slow upload) can keep
 * reading the granted content URI after our chooser returns. They hold plaintext history (MACs,
 * capture GPS, times), so the window is short: the export-time prune and the app-start sweep
 * ([sweepExportPackages] from AcabBleManager's init) both use this bound, and the real Clear log
 * deletes every package regardless of age.
 *
 * iOS twin: ios/Beacons/BLE/BLEManager.swift ExportTempCache.maxAge (the same 1 hour; its
 * clearDetections sweeps tmp the same way). Keep the two identical.
 */
internal const val EXPORT_PACKAGE_MAX_AGE_MS = 60L * 60L * 1000L

/** The cacheDir families [createExportPackage] writes. res/xml/file_paths.xml exposes exactly
 *  these two folders through the FileProvider; a new family must be added in both places. */
internal val EXPORT_PACKAGE_FAMILIES = listOf("log-exports", "contribution-shares")

/**
 * Allocate an immutable, per-export cache package and opportunistically remove only packages
 * old enough that no chooser or receiving app should still be reading them. Recent packages are
 * deliberately retained: a share target may keep using a granted URI after our chooser closes.
 */
internal fun createExportPackage(
    cacheDir: File,
    family: String,
    nowMs: Long = System.currentTimeMillis(),
    maxAgeMs: Long = EXPORT_PACKAGE_MAX_AGE_MS,
): File {
    require(family.matches(Regex("[a-z0-9-]+"))) { "invalid export family" }
    val root = File(cacheDir, family)
    // Two exports can start together. If the other one creates [root] between our isDirectory
    // check and mkdirs(), mkdirs() returns false even though the postcondition is satisfied.
    if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) {
        throw IOException("could not create the export cache")
    }

    prunePackages(root, cutoffMs = nowMs - maxAgeMs)

    repeat(4) {
        val packageDir = File(root, UUID.randomUUID().toString())
        if (packageDir.mkdir()) return packageDir
    }
    throw IOException("could not create the export package")
}

/**
 * Delete export packages in every [EXPORT_PACKAGE_FAMILIES] folder under [cacheDir]. With
 * [olderThanMs] null this is the Clear-log form: every package, whatever its age. With a value it
 * is the app-start form: only packages whose directory mtime is older than that. Returns the
 * packages it removed. Does file I/O: never call it on the main thread or in composition.
 *
 * The family folders themselves are kept, so an export racing a Clear fails on its own write
 * rather than on a vanished parent; an export written after this sweep is bounded by the next
 * export-time prune or app-start sweep.
 */
internal fun sweepExportPackages(
    cacheDir: File,
    olderThanMs: Long?,
    nowMs: Long = System.currentTimeMillis(),
): List<File> {
    val cutoff = if (olderThanMs == null) Long.MAX_VALUE else nowMs - olderThanMs
    return EXPORT_PACKAGE_FAMILIES.flatMap { prunePackages(File(cacheDir, it), cutoff) }
}

/** Remove UUID package directories under [root] last modified before [cutoffMs]. A package's
 *  directory mtime moves when its file is created, which is the moment of export. */
private fun prunePackages(root: File, cutoffMs: Long): List<File> {
    val removed = ArrayList<File>()
    root.listFiles()?.forEach { candidate ->
        // Only our UUID child directories are packages. Never let an unexpected file become
        // collateral damage. Age-based callers also spare a fresh in-flight package; only the
        // Clear-log form (cutoff Long.MAX_VALUE) takes it, because the user asked for it gone.
        val isPackage = candidate.isDirectory &&
            runCatching { UUID.fromString(candidate.name) }.isSuccess
        if (isPackage && candidate.lastModified() < cutoffMs &&
            runCatching { candidate.deleteRecursively() }.getOrDefault(false)) {
            removed += candidate
        }
    }
    return removed
}
