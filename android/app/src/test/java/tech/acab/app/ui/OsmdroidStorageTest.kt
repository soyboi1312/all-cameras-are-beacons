package tech.acab.app.ui

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OsmdroidStorageTest {
    @Test
    fun staleStoresAreEveryRootsOsmdroidDirExceptThePinnedOne() {
        val data = Files.createTempDirectory("acab-osm-roots").toFile()
        try {
            val filesDir = data.resolve("files")
            val noBackup = data.resolve("no_backup")
            val external = data.resolve("sdcard/Android/data/tech.acab.app/files")
            val pinned = File(noBackup, "osmdroid")

            val stale = staleOsmdroidStores(
                listOf(filesDir, null, external, external, noBackup), pinned)

            assertEquals(
                listOf(File(filesDir, "osmdroid"), File(external, "osmdroid"))
                    .map { it.absoluteFile },
                stale,
            )
        } finally {
            data.deleteRecursively()
        }
    }

    @Test
    fun deleteRemovesOnlyExistingOsmdroidNamedDirs() {
        val data = Files.createTempDirectory("acab-osm-delete").toFile()
        try {
            val staleExternal = data.resolve("ext/osmdroid").apply {
                resolve("tiles").mkdirs(); resolve("tiles/cache.db").writeText("viewed areas")
            }
            val pinnedTiles = data.resolve("no_backup/osmdroid/tiles").apply {
                mkdirs(); resolve("cache.db").writeText("viewed areas")
            }
            val wrongName = data.resolve("files").apply {
                mkdirs(); resolve("detections.json").writeText("sealed log")
            }
            val missing = data.resolve("gone/osmdroid")

            val removed = deleteOsmdroidStores(listOf(staleExternal, pinnedTiles, wrongName, missing))

            assertEquals(listOf(staleExternal, pinnedTiles), removed)
            assertFalse(staleExternal.exists())
            assertFalse(pinnedTiles.exists())
            // The pinned base survives a tile wipe; only its tiles subdir goes.
            assertTrue(data.resolve("no_backup/osmdroid").isDirectory)
            // A root passed by mistake is never wiped: the name gate refuses it.
            assertTrue(wrongName.resolve("detections.json").isFile)
            assertFalse(missing.exists())
        } finally {
            data.deleteRecursively()
        }
    }

    @Test
    fun tileDirIsTheSqlTileWriterSubdirOfTheBase() {
        val base = File("/data/user/0/tech.acab.app/no_backup/osmdroid")
        assertEquals(File(base, "tiles"), osmdroidTileDir(base))
    }
}
