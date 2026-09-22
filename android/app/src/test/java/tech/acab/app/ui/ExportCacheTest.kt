package tech.acab.app.ui

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportCacheTest {
    @Test
    fun allocatesUniquePackagesAndPrunesOnlyOldUuidPackages() {
        val cache = Files.createTempDirectory("acab-export-cache").toFile()
        try {
            val now = 2_000_000_000L
            val root = cache.resolve("log-exports").apply { mkdirs() }
            val old = root.resolve("00000000-0000-0000-0000-000000000001").apply {
                mkdir(); resolve("acab-detections.csv").writeText("old")
                setLastModified(now - EXPORT_PACKAGE_MAX_AGE_MS - 1)
            }
            val recent = root.resolve("00000000-0000-0000-0000-000000000002").apply {
                mkdir(); resolve("acab-detections.csv").writeText("recent")
                setLastModified(now - EXPORT_PACKAGE_MAX_AGE_MS + 1)
            }
            val unrelated = root.resolve("do-not-touch").apply {
                mkdir(); setLastModified(0L)
            }

            val first = createExportPackage(cache, "log-exports", now)
            val second = createExportPackage(cache, "log-exports", now)

            assertFalse(old.exists())
            assertTrue(recent.exists())
            assertTrue(unrelated.exists())
            assertTrue(first.isDirectory)
            assertTrue(second.isDirectory)
            assertNotEquals(first, second)
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun retentionIsOneHourMatchingIos() {
        // iOS twin: ExportTempCache.maxAge = 60 * 60 seconds.
        assertEquals(60L * 60L * 1000L, EXPORT_PACKAGE_MAX_AGE_MS)
    }

    @Test
    fun clearFormDeletesEveryPackageInBothFamiliesButNothingElse() {
        val cache = Files.createTempDirectory("acab-export-clear").toFile()
        try {
            val now = System.currentTimeMillis()
            // Fresh packages (created "now") in both families: the Clear form ignores age.
            val log = createExportPackage(cache, "log-exports", now)
                .apply { resolve("acab-detections.csv").writeText("mac,lat,lon") }
            val share = createExportPackage(cache, "contribution-shares", now)
                .apply { resolve("beacons-observation.csv").writeText("mac,lat,lon") }
            val foreignInFamily = cache.resolve("log-exports/do-not-touch").apply { mkdir() }
            val otherCacheFile = cache.resolve("beacon-nrf-dfu.zip").apply { writeText("zip") }
            val otherFamilyLike = cache.resolve("other/00000000-0000-0000-0000-000000000003")
                .apply { mkdirs() }

            val removed = sweepExportPackages(cache, olderThanMs = null, nowMs = now)

            assertEquals(setOf(log, share), removed.toSet())
            assertFalse(log.exists())
            assertFalse(share.exists())
            // The family roots stay so a racing export fails on its own write, not its parent.
            assertTrue(cache.resolve("log-exports").isDirectory)
            assertTrue(cache.resolve("contribution-shares").isDirectory)
            assertTrue(foreignInFamily.exists())
            assertTrue(otherCacheFile.exists())
            assertTrue(otherFamilyLike.exists())
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun startupFormDeletesOnlyPackagesOlderThanTheBound() {
        val cache = Files.createTempDirectory("acab-export-sweep").toFile()
        try {
            val now = 2_000_000_000L
            fun pkg(family: String, id: Int, ageMs: Long) =
                cache.resolve("$family/00000000-0000-0000-0000-00000000000$id").apply {
                    mkdirs(); setLastModified(now - ageMs)
                }
            val oldLog = pkg("log-exports", 1, EXPORT_PACKAGE_MAX_AGE_MS + 1)
            val freshLog = pkg("log-exports", 2, EXPORT_PACKAGE_MAX_AGE_MS - 1_000)
            val oldShare = pkg("contribution-shares", 3, EXPORT_PACKAGE_MAX_AGE_MS + 60_000)
            val freshShare = pkg("contribution-shares", 4, 0L)

            val removed = sweepExportPackages(cache, EXPORT_PACKAGE_MAX_AGE_MS, now)

            assertEquals(setOf(oldLog, oldShare), removed.toSet())
            assertFalse(oldLog.exists())
            assertFalse(oldShare.exists())
            assertTrue(freshLog.exists())
            assertTrue(freshShare.exists())
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun sweepToleratesAMissingCache() {
        val cache = Files.createTempDirectory("acab-export-missing").toFile()
        cache.deleteRecursively()
        assertTrue(sweepExportPackages(cache, olderThanMs = null).isEmpty())
        assertFalse(cache.exists())   // a sweep never creates the folders it cleans
    }

    /** The FileProvider exposes exactly the export families, and nothing broader: a
     *  `path="."` (the old whole-cacheDir grant) or a missing family fails here. */
    @Test
    fun fileProviderPathsAreExactlyTheExportFamilies() {
        val xml = File("src/main/res/xml/file_paths.xml")
        assertTrue("run from the android/app module dir: ${xml.absolutePath}", xml.isFile)
        val entries = Regex("""<([a-z-]+-path)\s+([^>]*)/>""").findAll(xml.readText()).map { m ->
            val path = Regex("""path="([^"]*)"""").find(m.groupValues[2])?.groupValues?.get(1)
            m.groupValues[1] to path
        }.toList()
        assertEquals(
            EXPORT_PACKAGE_FAMILIES.map { "cache-path" to "$it/" }.toSet(),
            entries.toSet(),
        )
        assertEquals(EXPORT_PACKAGE_FAMILIES.size, entries.size)
    }

    @Test
    fun concurrentFirstAllocationsShareTheRootWithoutFailing() {
        val cache = Files.createTempDirectory("acab-export-cache-race").toFile()
        val workers = 12
        val ready = CountDownLatch(workers)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(workers)
        try {
            val futures = (0 until workers).map {
                pool.submit<File> {
                    ready.countDown()
                    start.await()
                    createExportPackage(cache, "log-exports")
                }
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            start.countDown()
            val packages = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(workers, packages.toSet().size)
            assertTrue(packages.all { it.isDirectory })
        } finally {
            start.countDown()
            pool.shutdownNow()
            cache.deleteRecursively()
        }
    }
}
