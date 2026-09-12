package tech.acab.app.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The publish pump asks one question about the active projection on every emission, at about
 * 3 Hz: is this the same set of devices the map and the dossier were last given? A yes reuses the
 * cached geometry; a no bumps the spatial revision and everything keyed on it rebuilds.
 *
 * That makes both answers load bearing in opposite directions. A wrong yes HIDES a device: a pin
 * that should have appeared, or one that should have gone, stays as it was until something else
 * moves the revision. A wrong no costs a full projection rebuild at radio cadence, which is the
 * cost this signature exists to remove.
 *
 * The signature replaced a HashSet of up to FEED_CAP ids, allocated and compared per publish, so
 * these tests are the proof that the cheap form still answers exactly what the set answered.
 */
class MembershipSignatureTest {

    private fun sig(vararg ids: String) = MembershipSignature.of(ids.toList())

    private val feed = listOf(
        "9:aa:bb:cc:dd:01", "9:aa:bb:cc:dd:02", "10:44:19:b6:22:0a", "12:5a:2e:7c:41:08",
    )

    /** A sighting re-adds its row at the front of the insertion-ordered store, so the walk order
     *  changes several times a second while the membership does not. The set compare ignored
     *  order and so must this.
     *
     *  FAILS IF the fold is made order dependent (a rolling hash, a list compare, appending to a
     *  string), which would bump the revision on every ordinary packet and rebuild the whole map
     *  projection at radio cadence. */
    @Test
    fun reorderingTheFeedIsNotAMembershipChange() {
        val base = MembershipSignature.of(feed)
        assertTrue(base.sameAs(MembershipSignature.of(feed.reversed())))
        assertTrue(base.sameAs(MembershipSignature.of(feed.drop(1) + feed.first())))
        assertTrue(base.sameAs(MembershipSignature.of(feed.shuffled())))
        // The same walk twice with nothing changed is the common case, and it must be quiet.
        assertTrue(MembershipSignature.of(feed).sameAs(MembershipSignature.of(feed)))
    }

    /** Every path that can change active membership, in the shape it reaches this fold as. The
     *  store insert, the eviction and the clear arrive as an id appearing or leaving; the mute
     *  and watch list edits, mute expiry and the replay filing arrive the same way, because
     *  activeProjectionIncludes decides membership and the fold only ever sees the survivors.
     *
     *  FAILS IF the signature is reduced to a bare count. The LAST assertFalse here swaps one id
     *  for another at an unchanged count, and a count-only sameAs calls those two sets identical;
     *  that is the one assertion in this test the revert kills. Every other assertion here moves
     *  the count and survives it.
     *
     *  NOT pinned here: the SECOND accumulator. Its job is to make a count-preserving change of
     *  MORE than one row match the xor and the sum at once, and no assertion in this file needs
     *  both at the same time, so reducing sameAs to count plus either accumulator leaves the whole
     *  file green. Do not read this test as cover for halving the per-publish fold.
     *
     *  Each row here is a real product path: a first sighting, an eviction at STORE_CAP, Clear
     *  Log, a mute taking effect, that mute expiring, and a mute plus a star landing together
     *  from Log select mode. */
    @Test
    fun everyKindOfMembershipChangeMovesTheSignature() {
        val base = MembershipSignature.of(feed)
        // A first sighting, or a replayed record filed under an id not in the store yet.
        assertFalse(base.sameAs(MembershipSignature.of(feed + "9:aa:bb:cc:dd:03")))
        // Eviction at the store cap, and a mute that takes a row out of the active projection.
        assertFalse(base.sameAs(MembershipSignature.of(feed.dropLast(1))))
        assertFalse(base.sameAs(MembershipSignature.of(feed.drop(1))))
        // Clear Log, and the demo seed replacing the store wholesale.
        assertFalse(base.sameAs(MembershipSignature()))
        assertFalse(MembershipSignature().sameAs(base))
        // A mute expiring: the row comes back, and the projection must be rebuilt to show it.
        val muted = MembershipSignature.of(feed.drop(1))
        assertFalse(muted.sameAs(base))
        // One muted and one starred in the same select-mode edit: the count is unchanged and only
        // the accumulators can tell. Same shape as an eviction that races a new first sighting.
        assertFalse(base.sameAs(MembershipSignature.of(feed.drop(1) + "12:00:11:22:33:44")))
    }

    /** Two different sets of the same size, built from ids one hex digit apart, which is what a
     *  real feed looks like. A weak fold collides here and the map silently keeps the old set.
     *
     *  FAILS IF membershipHash64 is replaced by String.hashCode: "9:Aa" and "9:BB" have the same
     *  Java string hash (both 1755937), so a hashCode-based xor and sum would call these two
     *  one-device sets identical. That revert kills the first assertFalse and the assertNotEquals
     *  on the raw folds; every other assertion here survives it.
     *
     *  NOT pinned here: the murmur3 finalizer. Its job is to avalanche ids that share a long
     *  prefix, so that a later xor or sum cannot cluster them, but FNV-1a alone already separates
     *  every input this test uses, including all 207 substitutions of the dense loop. Dropping the
     *  finalizer leaves this test green, so do not read it as cover for that change. */
    @Test
    fun nearIdenticalIdsDoNotCollide() {
        assertFalse(sig("9:Aa").sameAs(sig("9:BB")))
        assertNotEquals(membershipHash64("9:Aa"), membershipHash64("9:BB"))
        assertFalse(sig("9:aa:bb:cc:dd:e1").sameAs(sig("9:aa:bb:cc:dd:e2")))
        assertFalse(
            sig("9:aa:bb:cc:dd:e1", "9:aa:bb:cc:dd:e2")
                .sameAs(sig("9:aa:bb:cc:dd:e3", "9:aa:bb:cc:dd:e4")),
        )
        // A dense drive: every single-device substitution over a large id space stays distinct.
        val dense = (0 until 20_000).map { "9:aa:bb:cc:${it / 256}:${it % 256}" }
        val denseSig = MembershipSignature.of(dense)
        for (i in 0 until 20_000 step 97) {
            val swapped = dense.toMutableList().also { it[i] = "9:ff:ff:ff:ff:$i" }
            assertFalse("substitution at $i collided", denseSig.sameAs(MembershipSignature.of(swapped)))
        }
    }

    /** The state every teardown resets to. resetInMemoryLog and the demo seed both clear the
     *  store and install a fresh signature, and the next publish has to bump the revision for any
     *  row at all, including the same rows coming back off the persisted log.
     *
     *  FAILS IF a signature with nothing added stops equalling the empty projection, or stops
     *  differing from a non-empty one in either direction. Those three comparisons are all this
     *  test makes.
     *
     *  NOT pinned here: the manager-side reset. This test never builds an AcabBleManager, so
     *  deleting `lastPublishedMembership = MembershipSignature()` from resetInMemoryLog or from
     *  the demo seed fails nothing here, and no other test in the tree names either symbol. That
     *  reset is belt and braces today, because resetInMemoryLog, the demo seed and
     *  loadPersistedDetections each bump spatialEvidenceGeneration themselves. A real guard needs
     *  a manager-level test that a clear followed by reloading the same rows moves
     *  spatialEvidenceRev; that one fails if either the reset or the bump is removed. */
    @Test
    fun theEmptySignatureIsTheClearedProjection() {
        assertTrue(MembershipSignature().sameAs(MembershipSignature.of(emptyList())))
        assertFalse(MembershipSignature().sameAs(sig("9:aa:bb:cc:dd:01")))
        assertFalse(sig("9:aa:bb:cc:dd:01").sameAs(MembershipSignature()))
    }
}
