package tech.acab.app.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.DashPathEffect
import androidx.core.content.ContextCompat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import android.view.MotionEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.MuteRuleStatus
import tech.acab.app.ble.MuteScope
import tech.acab.app.model.Detection
import tech.acab.app.model.FaqContent
import tech.acab.app.model.DeviceType
import tech.acab.app.model.FollowEvidence
import tech.acab.app.net.AlprStore
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.isOuiMatch
import tech.acab.app.model.companyIdText
import tech.acab.app.model.wifiChannelText
import tech.acab.app.model.methodLabel
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.sourceLabel
import tech.acab.app.model.titleName
import tech.acab.app.model.validCoord
import tech.acab.app.model.vendor
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.telemetry
import tech.acab.app.ui.theme.textTone
import tech.acab.app.ui.theme.tone
import tech.acab.app.model.maker
import tech.acab.app.model.isChipsetRegistrant

/** Detection dossier: small top app bar, hero, Watch and Mute, match quality, confirm-it
 *  checklist for weak hits, live signal, sightings, location, Seen with you, related help,
 *  technical details, Copy MAC Address last. Same sequence as iOS DetectionDetailView.body.
 *  [overlay] is true where the dossier covers the whole shell (MainScreen's compact overlay and
 *  the saved log's dossier in AcabApp's SavedLogScreen):
 *  its bar title is then also the pane title TalkBack announces when it opens, the pattern
 *  DeviceScreen's SubScreen set. An inline pane beside the list or map is not a new pane. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(
    detection: Detection,
    ble: AcabBleManager,
    onBack: () -> Unit,
    onOpenInMap: (Double, Double) -> Unit,
    locationGranted: Boolean = false,
    onRequestLocation: () -> Unit = {},
    // Help's "Improve detection" support row, passed down to the Related help overlay. Pass it only
    // for a ready, non-demo session (improveDetectionAvailable); null hides the row.
    onImproveDetection: (() -> Unit)? = null,
    overlay: Boolean = false,
    // The wide two-pane detail pane beside the Log or Map list (MainScreen `wide`): the bar's
    // leading icon is Close, because [onBack] there deselects the row and empties the pane, it
    // does not go back anywhere (2026-09-26 review P3-6). Compact and overlay dossiers keep
    // Back and the shell's BackHandler.
    inPane: Boolean = false,
) {
    // Which FAQ answer a RELATED HELP row asked for; non-null opens the Help sheet on it.
    var helpDeepLink by remember { mutableStateOf<String?>(null) }
    // The pushed-in dossier is a frozen snapshot, so shadow it with the live record
    // from the feed; "seen N×" and friends keep updating while the screen is open.
    // The id is hoisted once so the ~3 Hz scan below compares against a local rather than
    // re-reading detection.id each pass.
    val detections by ble.detections.collectAsState()
    val targetId = remember(detection) { detection.id }
    val d = detections.firstOrNull { it.id == targetId } ?: detection
    // Closest pins and tracker crumbs live in side maps and can change while the immutable row is
    // equal (notably when a stronger history record loses timestamp-row selection). This revision
    // is what wakes the dossier for that, independently of the Detection StateFlow. It is the
    // wake-up and not the key: it moves for any device, so what it re-reads is the cheap per-row
    // rowMapEvidence below, and that value decides whether the pin and the trail are read again.
    val spatialEvidenceRev by ble.spatialEvidenceRev.collectAsState()
    val tone = d.type.tone()
    val trend = ble.rssiTrend(d.id)
    // Staleness and every "ago" on this dossier move with the clock, not with any flow collected
    // here, so once this device stops being heard and nothing else publishes, nothing recomposes:
    // the header held LIVE and Last seen held its last age indefinitely, at exactly the
    // moment someone checks whether a device really went quiet. 1 s, the same cadence as
    // StatusScreen's staleness `tick`. TWIN: iOS DetectionDetailView `staleTick` drives the same
    // readings at the same cadence. nowMs is PASSED to every clock reading on this screen, not
    // merely read here: a child composable is skipped while its parameters are unchanged, so a
    // wall-clock read inside one (ConfirmItPanel's span did this) stayed at its last composition
    // even when this scope recomposed.
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            nowMs = System.currentTimeMillis()
        }
    }
    // Sample data is always active (C10): Log lists these rows under Active,
    // Status counts them nearby and Map keeps them in "active", so the dossier never reads STALE
    // for them on the one page that describes the row (its header word is SAMPLE,
    // dossierSignalWord, and the sparkline keeps its category hue). Kept here, not in isStale, so
    // the store's own staleness answer stays a plain clock reading for every other caller.
    // TWIN: iOS DetectionDetailView signalPanel `stale`, via dossierSignalIsStale.
    val demo by ble.demoMode.collectAsState()
    val stale = !demo && ble.isStale(d.id, nowMs = nowMs)
    // Buffered rows the board had no clock for carry an ordering key, not a time. Rendering that
    // as an age reads "24 years ago" with total confidence, so say what we actually know instead.
    val firstSeen = ble.firstSeen(d.id)
    val lastSeen = ble.lastSeen(d.id)
    val approxFirst = ble.isApproxTime(firstSeen)
    // How this row's first-seen stamp was arrived at. Exact for a live sighting, in which case
    // nothing below changes. The revision key is what makes a screen already open when a drain
    // finishes pick up the bracketing it just did (see AcabBleManager.timeBasisRev).
    val timeRev by ble.timeBasisRev.collectAsState()
    val timeBasis = remember(d.id, timeRev) { ble.timeBasis(d.id) }
    // The reconstructed / bracketed / unknown line, or null when the stamp is a plain clock
    // reading and the existing relative age is the honest thing to show.
    val firstSeenText = timeBasis.primaryText()
        ?: if (approxFirst) APPROX_TIME else relativeAgo(firstSeen, nowMs)
    val watchedList by ble.watched.collectAsState()
    val isWatched = watchedList.any { it.mac == d.mac.lowercase() }
    val ignoredList by ble.ignored.collectAsState()
    val muteRule = ignoredList.firstOrNull { it.mac == d.mac.lowercase() }
    val connectionState by ble.state.collectAsState()
    // Confirm before starring a randomized address: it rotates, so the star may stop matching.
    var showRandomWarn by remember { mutableStateOf(false) }
    // A star refused at the firmware's 256-entry cap: surface it instead of the Watch tap
    // silently doing nothing (the manager's watchDevice returns without adding at the cap).
    var showWatchlistFull by remember { mutableStateOf(false) }
    var showMuteOptions by remember { mutableStateOf(false) }
    var muteError by remember { mutableStateOf<String?>(null) }
    var locationRefreshTick by remember { mutableStateOf(0L) }
    // A fix can arrive or age out without changing a Compose StateFlow. Poll only while the HERE
    // affordance or a configured place rule is visible, so availability and the active label stay
    // honest without putting a permanent timer behind every dossier.
    LaunchedEffect(showMuteOptions, muteRule?.isPlaceRule, locationGranted, connectionState) {
        if (!showMuteOptions && muteRule?.isPlaceRule != true) return@LaunchedEffect
        while (true) {
            locationRefreshTick++
            delay(2_000L)
        }
    }
    val freshLocationAvailable = remember(
        locationRefreshTick, showMuteOptions, muteRule?.isPlaceRule, locationGranted, connectionState,
    ) { ble.currentSelfCoord() != null }
    val muteStatus = remember(locationRefreshTick, muteRule, connectionState) {
        muteRule?.let { ble.muteRuleStatus(it) }
    }
    var showRssiInfo by remember { mutableStateOf(false) }   // info button in SIGNAL explains the RSSI graph
    val actionsStacked = dossierActionsStacked(LocalDensity.current.fontScale)
    // The bar title is hoisted as a String: a title lambda that captured d would be rebuilt on
    // every ~3 Hz publish (d is a new Detection each time), and the bar would recompose with it.
    val barTitle = d.type.inlineCategory
    var identityExpanded by remember(d.id) { mutableStateOf(false) }
    // One watch/star toggle shared by the CONFIRM IT chip and the Watch button.
    val toggleWatch: () -> Unit = {
        if (isWatched) {
            ble.unwatch(d.mac)
        } else if (watchedList.size >= WATCH_CAP) {
            showWatchlistFull = true   // cap first, like the manager: say so rather than no-op
        } else if (d.isRandomAddr) {
            showRandomWarn = true   // confirm first: a rotating address may stop matching
        } else {
            ble.watchDevice(d)
        }
    }
    // What THIS row's map evidence is right now: its pin, how long its trail is and when its last
    // crumb landed, and demo mode. Recomputed on every revision bump, which is one storeLock take
    // and three lookups, and used as the key for the two expensive reads below so that they run
    // when this device's own evidence moved rather than whenever the global revision moved. The
    // revision moves on any device's pin and on every active-membership change, which under Desert
    // density is most publishes, so the open dossier was copying a crumb list and retaking the
    // lock because an unrelated device entered the feed. Reading spatialEvidenceRev HERE is also
    // what subscribes this screen to it: a pin or crumb can change while every visible row stays
    // equal, and StateFlow conflates that away, so the revision is the only thing that wakes us.
    val rowMapEvidence = remember(d.id, spatialEvidenceRev) { ble.rowMapEvidence(d.id) }
    val breadcrumbTrail = remember(d.id, d.type, rowMapEvidence) {
        if (d.type == DeviceType.TRACKER) ble.crumbs(d.id) else emptyList()
    }
    // gpsAgeSec is a key because mapCoord's live-wire fallback is gated on it: a row whose board
    // fix has aged past the freshness window stops resolving to a coordinate. offline is a key for
    // the other half of the same gate, mapWireFallbackAllowed, which the revision did not reliably
    // cover: file() bumps nothing when a row arrives again with the lat/lon it already had.
    val mapCoordinate = remember(d.id, d.lat, d.lon, d.gpsAgeSec, d.offline, rowMapEvidence) {
        ble.mapCoord(d)
    }

    // T2: cap the readable dossier width so tablets/landscape stop stretching one column edge to
    // edge; at phone width the 640 cap is a no-op. The root Column centers the capped content; the
    // top app bar stays full-bleed. The map thumbnail rides inside the capped column.
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface)
            .then(
                when {
                    helpDeepLink != null -> Modifier.clearAndSetSemantics { }
                    overlay -> Modifier.semantics { paneTitle = barTitle }
                    else -> Modifier
                },
            )
            // Compact dossiers are siblings of Scaffold and otherwise draw under the navigation
            // and cutout insets; the top app bar pads the status bar itself. In wide panes the
            // parent already consumes these, so Compose applies zero here rather than
            // double-padding.
            .windowInsetsPadding(
                WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Small top app bar: Back (Close in a wide pane, [inPane]) and the category. No star and
        // no overflow: Watch and Mute live in the body. The dossier draws its own bar and never
        // writes the tab's top-bar slot, which belongs to the tab it sits in (in a wide pane it
        // would replace that tab's bar).
        TopAppBar(
            title = { Text(barTitle) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    if (inPane) {
                        Icon(Icons.Filled.Close, contentDescription = "Close")
                    } else {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            },
        )
        // No horizontal padding: every row and section owns its own 16dp.
        Column(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // ---- hero: glyph, name, node handle (the top app bar names the category) ----
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CatGlyph(d.type, size = 56, filled = true)
                Column(Modifier.weight(1f)) {
                    // The headline is the same user/device name the Log row and the Status hero
                    // lead with (titleName: a nameless row reads "body cam", "network camera");
                    // the node handle sits in the subtitle. TWIN: iOS DetectionDetailView
                    // `titleBlock`: the titleName headline over dossierHeroSubtitle, one dossier
                    // header on both phones.
                    val headline = d.titleName
                    Text(headline, Modifier.semantics { heading() },
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.onSurface)
                    // NEITHER branch may consult the OUI lookup: the OUI resolves a Flock
                    // Falcon to its Liteon WiFi module and would head the ALPR dossier with
                    // "Liteon" instead of "Flock Safety". The OUI reading still shows in the
                    // identity panel below, where it is labelled as such. maker is null for
                    // Flock, so the ALPR case is unaffected by the new first branch.
                    Text(dossierHeroSubtitle(nodeName(d.mac), d.maker ?: d.vendor, headline),
                        style = DossierLineStyle,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            // Primary decisions live directly under the identity instead of below every graph and
            // raw field. Existing confirmation/cap/scoped-mute behavior remains unchanged.
            // ONE child, as in iOS DetectionDetailView.primaryActions: Watch beside Mute (Unmute
            // once a rule exists), stacked from font scale 1.5 (dossierActionsStacked), then an
            // existing rule's state and Change under them (MutedStateRows, iOS mutedStateSection).
            // Both dossiers run the same panels as the same number of children, so moving either
            // action is still a two-file edit.
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val onUnmute: () -> Unit = { ble.unignore(d.mac) }
                val onMuteOptions: () -> Unit = { showMuteOptions = true }
                if (actionsStacked) {
                    WatchButton(watched = isWatched, onToggle = toggleWatch, modifier = Modifier.fillMaxWidth())
                    MuteButton(muted = muteRule != null, onUnmute = onUnmute, onOptions = onMuteOptions,
                        modifier = Modifier.fillMaxWidth())
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        WatchButton(watched = isWatched, onToggle = toggleWatch, modifier = Modifier.weight(1f))
                        MuteButton(muted = muteRule != null, onUnmute = onUnmute, onOptions = onMuteOptions,
                            modifier = Modifier.weight(1f))
                    }
                }
                muteRule?.let { rule ->
                    MutedStateRows(mutedScope = rule.scopeLabel, muteStatus = muteStatus,
                        onOptions = onMuteOptions)
                }
            }

            // ---- how good the match is: what matched, the verdict and percent, a plain-language
            // explainer, and the firmware's own hedge string verbatim at the foot of the section ----
            MatchQualityPanel(d)

            // ---- heads-up that THIS category's signatures aren't field-verified ----
            if (d.type.isExperimental) ExperimentalNote(d.type)

            // ---- weak / chipset-only hits get a field checklist instead of a shrug ----
            // Directly under match quality and the experimental note: the checklist acts on the
            // doubt those two raise. Its second question reads the count and span it prints
            // itself (seenSpan). iOS DetectionDetailView.body runs the same sequence.
            if (d.isOuiMatch || d.confidence < 50) {
                ConfirmItPanel(d, firstSeen = if (approxFirst) null else firstSeen, nowMs = nowMs,
                    watched = isWatched, onWatch = toggleWatch)
            }

            // ---- signal: bars + dBm + sparkline as the instrument, SAMPLE / LIVE / STALE trailing ----
            Column(Modifier.fillMaxWidth()) {
                // One heading node, spoken as the old header read ("SIGNAL · LIVE"), which is also
                // what the iOS header says aloud.
                val signalWord = dossierSignalWord(demo = demo, stale = stale)
                Row(Modifier.fillMaxWidth().clearAndSetSemantics {
                    heading()
                    contentDescription = "SIGNAL · $signalWord"
                }) {
                    SectionLabel("SIGNAL", Modifier.weight(1f))
                    Text(signalWord,
                        Modifier.padding(top = 16.dp, bottom = 8.dp, end = 16.dp),
                        style = DossierSignalWordStyle,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                // The instrument, the band and the sparkline share one card ([DossierCard]); the
                // header row above and the RSSI explainer below stay bare, the iOS signalPanel
                // section with its header and footer.
                DossierCard {
                    Column(Modifier.padding(top = 4.dp, bottom = 12.dp)) {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            // The instrument is one node with the unit spoken, the Log row's wording.
                            Row(Modifier.weight(1f).clearAndSetSemantics {
                                contentDescription = "Signal strength ${d.rssi} decibels relative to one milliwatt"
                            }, verticalAlignment = Alignment.CenterVertically) {
                                SignalBars(rssiBars(d.rssi), tint = tone)
                                Spacer(Modifier.width(12.dp))
                                Text("${d.rssi}", style = DossierRssiStyle, color = MaterialTheme.colorScheme.onSurface)
                                Spacer(Modifier.width(4.dp))
                                Text("dBm", style = DossierLineStyle,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            // The band trails the instrument, as on iOS signalPanel; the sightings row
                            // below no longer repeats the dBm reading. At large text it drops to its own
                            // line under the instrument (below), as iOS signalPanel switches to a VStack,
                            // so the band never squeezes the dBm unit into a wrap.
                            if (!actionsStacked) {
                                Text(d.sourceLabel, Modifier.padding(start = 8.dp),
                                    style = DossierLineStyle,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { showRssiInfo = !showRssiInfo },
                                modifier = Modifier.semantics {
                                    stateDescription = if (showRssiInfo) "expanded" else "collapsed"
                                }) {
                                Icon(Icons.Outlined.Info, contentDescription = "What the RSSI graph means")
                            }
                        }
                        if (actionsStacked) {
                            Text(d.sourceLabel, Modifier.padding(horizontal = 16.dp),
                                style = DossierLineStyle,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        SignalHistoryGraph(
                            values = trend,
                            currentRssi = d.rssi,
                            tone = tone,
                            stale = stale,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(46.dp),
                        )
                    }
                }
                if (showRssiInfo) {
                    Text("RSSI is signal strength, moment to moment. closer to 0 is stronger, so the line climbs as you get nearer the source and drops as you move away, use it to home in on a hit.",
                        Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            // ---- sightings row: the SIGHTINGS string verbatim as a title + trailing value row. The
            // live dBm and band sit in the signal section above, as on iOS statGrid. ----
            StatGrid(
                listOf(
                    // A reconstructed first-sighting still has a real age, but it is an age
                    // measured off a derived point, so it gets the "~" that marks it as one.
                    // A bracketed row has no point to measure from, so it says so.
                    "SIGHTINGS" to when {
                        timeBasis is TimeBasis.Reconstructed -> "${d.count} · first ~${relativeAgo(firstSeen, nowMs)}"
                        timeBasis is TimeBasis.Bracketed -> "${d.count} · time bounded"
                        approxFirst -> "${d.count} · time unknown"
                        else -> "${d.count} · first ${relativeAgo(firstSeen, nowMs)}"
                    },
                ),
            )

            // ---- location and session trail ----
            mapCoordinate?.let { (lat, lon) ->
                LocationPanel(d, lat, lon, breadcrumbTrail, onOpenInMap, headerStacked = actionsStacked)
            }
            if (d.type == DeviceType.TRACKER) FollowEvidencePanel(d.id, d.type, ble, timeBasis)

            // ---- related help ----
            RelatedHelpPanel(d) { helpDeepLink = it }

            // Raw radio/firmware identity is available on demand, after the evidence.
            // Title and summary are BYTE-IDENTICAL to iOS DetectionDetailView.identityDisclosure,
            // and docs/app-guide.md names this control for readers of both apps, so a support
            // answer or the guide cannot be right on one phone and wrong on the other.
            DisclosureSection(
                title = "Technical details",
                summary = "Identifiers, capture times and broadcast fields",
                expanded = identityExpanded,
                onToggle = { identityExpanded = !identityExpanded },
            ) {
                val rows = buildList {
                    // TWO ROWS, NOT ONE. The old single "Vendor" row rendered a union of a real
                    // IEEE registrant and a per-type constant, so it printed "Vendor: IP camera"
                    // and "Vendor: Unknown vendor": the category restated under a label that
                    // claims an identification the detector never made. Renaming it "Category"
                    // would have been worse, not better, since the same row also holds "Liteon"
                    // on a genuine Falcon and "Motorola Solutions" on a body cam.
                    //
                    // So: Maker = who built it (payload-derived, absorbing the old Brand row),
                    // OUI vendor = who owns the MAC block, annotated when that is only the radio
                    // module. When neither resolves NOTHING RENDERS, which is the actual fix.
                    // Row-for-row identical to iOS DetectionDetailView.identityPanel.
                    val mk = d.maker ?: d.type.brand
                    mk?.let { add("Maker" to it) }
                    d.ouiVendor?.takeIf { it != mk }?.let {
                        add("OUI vendor" to if (isChipsetRegistrant(it)) "$it · chipset" else it)
                    }
                    d.companyIdText?.let { add("Company ID" to it) }
                    d.wifiChannelText?.let { add("Wi-Fi channel" to it) }
                    add("Identifier" to d.mac)
                    add(FIRST_SEEN_LABEL to firstSeenText)
                    // isApproxTime alone is not enough here. It screens Bracketed and Unknown,
                    // which keep the pseudo stamp, but a Reconstructed row holds a REAL ms value,
                    // so it passed straight through and rendered a bare "3h ago" as if the phone
                    // had watched the clock. Qualify it: the instant is derived, and a device that
                    // exists purely from the offline buffer has no live last-seen at all.
                    // Asked per STAMP, not per row (iOS timeBasis(for:stamp:)): a device replayed
                    // from the buffer and THEN heard live has a derived First seen and a genuine
                    // Last seen, and each has to say so for itself. A live sighting advances
                    // lastSeenAt past the drained stamp, so equality with firstSeen is what "this
                    // stamp IS the reconstructed one" looks like from here.
                    add("Last seen" to dossierLastSeenValue(demo) {
                        when {
                            ble.isApproxTime(lastSeen) -> APPROX_TIME
                            timeBasis is TimeBasis.Reconstructed && lastSeen == firstSeen ->
                                "${relativeAgo(lastSeen, nowMs)} · reconstructed"
                            else -> relativeAgo(lastSeen, nowMs)
                        }
                    })
                    d.name?.takeIf { it.isNotEmpty() }?.let { add("Name" to it) }
                    d.rid?.takeIf { it.isNotEmpty() }?.let { add("UAS ID" to it) }
                    // No separate "Manufacturer" row: maker's step 2 IS ridManufacturer, so it
                    // now renders as Maker above. Keeping both printed the same company twice,
                    // rows apart, under two different labels.
                    //
                    // The Detail row stays VERBATIM and is load-bearing, not decoration. Every
                    // hedge the firmware authors wrote lives only here now that maker parses the
                    // same string: " on wifi" (a device on the network, not necessarily a camera
                    // pointed at you), "(offline)" (a separated tag, NOT buffer replay), "or
                    // Quest" (glasses_signatures.h says that caveat must be present), and "gear,
                    // no Remote ID" (may be a controller, not an aircraft). Do not condense it.
                    d.detail?.takeIf { it.isNotEmpty() }?.let { add("Detail" to it) }
                    // Numeric lat/lon alongside the mini-map: the coordinates are the actionable
                    // datum in an evidence export, and the operator (pilot) fix is the whole point
                    // of a drone detection, so show both as text, not only as a pin.
                    run { val la = d.lat; val lo = d.lon
                        if (la != null && lo != null && validCoord(la, lo)) add("Position" to coordText(la, lo)) }
                    d.altitude?.let { add("Altitude" to "$it m") }
                    d.speedH?.let { add("Speed" to "$it m/s") }
                    d.speedV?.takeIf { it != 0 }?.let { add("Vert. speed" to "$it m/s") }
                    d.heading?.let { add("Heading" to "$it°") }
                    d.heightAGL?.let { add("Height AGL" to "$it m") }
                    run { val pla = d.pilotLat; val plo = d.pilotLon
                        if (pla != null && plo != null && validCoord(pla, plo)) add("Operator pos" to coordText(pla, plo)) }
                    d.pilotAlt?.let { add("Operator alt" to "$it m") }
                    d.ridStatusLabel?.let { add("Status" to it) }
                }
                rows.forEach { (label, value) ->
                    // Only the first-seen row carries a derived time; its qualifier rides in the
                    // same value column, on its own line under the value, so it can never pair with
                    // the wrong number. It is a sentence, so GroupedValueRow sets it on the system
                    // face, not the value's instrument face (iOS dossierRowNote).
                    val note = if (label == FIRST_SEEN_LABEL) timeBasis.qualifierText() else null
                    GroupedValueRow(label, value, note = note)
                }
                WhyFlagged(d, tone)
            }

            // OUTSIDE the disclosure, where iOS DetectionDetailView.body already put its
            // `copyButton`. This was the last row INSIDE Technical details, so copying an
            // address meant expanding a collapsed section first, and an instruction that
            // named this button could not be true of both phones at once.
            CopyMacButton(d.mac)

        }

        // Randomized-address confirm sheet: star it anyway, but say plainly why it may lapse.
        // One dialog, one body, picked by type inside, so a tracker never stacks a second prompt.
        if (showRandomWarn) {
            RandomAddrWarnDialog(
                type = d.type,
                onDismiss = { showRandomWarn = false },
                // Re-check the cap on confirm: the list could have filled while the sheet sat open.
                onConfirm = {
                    showRandomWarn = false
                    if (watchedList.size >= WATCH_CAP) showWatchlistFull = true
                    else ble.watchDevice(d)
                },
            )
        }

        // Refused star at the cap, iOS "Watchlist full" alert word for word.
        if (showWatchlistFull) {
            WatchlistFullDialog { showWatchlistFull = false }
        }

        if (showMuteOptions) {
            ScopedMuteDialog(
                locationAvailable = freshLocationAvailable,
                locationPermissionGranted = locationGranted,
                locationCanRefresh = connectionState == ConnState.READY,
                addressRotates = d.isRandomAddr,
                error = muteError,
                onRequestLocation = onRequestLocation,
                onDismiss = { showMuteOptions = false },
                onChoose = { scope ->
                    if (ble.ignoreDevice(d, scope)) {
                        showMuteOptions = false
                        muteError = null
                    } else {
                        muteError = if (scope == MuteScope.HERE && ble.currentSelfCoord() == null) {
                            "A fresh location accurate to 50 meters is required for a place mute. " +
                                "Keep the beacon connected and try again."
                        } else {
                            "The muted-device list is full. Unmute another device and try again."
                        }
                    }
                },
            )
        }
    }

    // A RELATED HELP row opens the bundled FAQ ON that answer. Rendered as a full-bleed overlay
    // rather than a nav push because the dossier is itself already a pushed screen here, and
    // stacking a second push makes the back button ambiguous. BackHandler in the overlay takes
    // precedence, so back closes Help and leaves the dossier where it was.
    helpDeepLink?.let { id ->
        HelpOverlay(questionId = id, onClose = { helpDeepLink = null },
            onImproveDetection = onImproveDetection)
    }
}

/** Stack Watch over Mute from font scale 1.5, the stack threshold DeviceScreen and StatusScreen
 *  already use. The same flag drops the SIGNAL band word under the instrument and the LOCATION
 *  coordinate under its heading. A mute rule does not stack them: its state renders full width under the pair
 *  (MutedStateRows). TWIN of iOS DetectionDetailView.primaryActions, which stacks at an
 *  accessibility text size and keeps the pair two-up for a mute rule. */
internal fun dossierActionsStacked(fontScale: Float): Boolean =
    fontScale >= DOSSIER_ACTIONS_STACK_FONT_SCALE
private const val DOSSIER_ACTIONS_STACK_FONT_SCALE = 1.5f

// The dossier's numbers, identifiers and telemetry lines are the instrument face (R16, Theme.kt
// telemetry); its title, buttons and prose stay Roboto. The dossier values themselves come through
// GroupedValueRow, which sets every value in it. TWIN: iOS DetectionDetailView (dossierRowValue,
// the hero subtitle, the signal instrument, the graph words, the SIGNAL word, the coordinates).

/** The dossier's live dBm number: updates in place while visible, and JetBrains Mono's digits are
 *  all one width. Built once at file level, never per composition (the dossier recomposes on
 *  every ~3 Hz publish). */
private val DossierRssiStyle = AcabTypography.headlineMedium.telemetry()

/** The LOCATION header's coordinate pair, compared digit for digit; file level for the same reason. */
private val DossierCoordStyle = AcabTypography.bodyMedium.telemetry()

/** The hero subtitle (NODE 2A10 · Flock Safety), the "dBm" unit and the source band: telemetry
 *  lines, untracked. */
private val DossierLineStyle = AcabTypography.bodyMedium.telemetry()

/** The SIGNAL header's trailing word (SAMPLE / LIVE / STALE): an uppercase label, tracked. */
private val DossierSignalWordStyle = AcabTypography.labelLarge.telemetry(tracked = true)

/** One string for the Help overlay's bar title and its pane title, so the two cannot drift. The
 *  same name every other route to this content uses (the Status "?" overlay's HELP_OVER_TAB_TITLE
 *  in MainScreen.kt and the Beacon row's BeaconRowId.HELP_SUPPORT title in DeviceScreen.kt), so
 *  TalkBack announces one pane name for one screen. Pinned in DossierHelpTitleTest. TWIN: iOS
 *  HelpView's navigation title. */
internal const val DOSSIER_HELP_TITLE = "Help + support"

/** Full-bleed Help, opened on a specific answer from a dossier's RELATED HELP row. The bar title
 *  is also the pane title TalkBack announces when the overlay opens, the pattern DeviceScreen's
 *  SubScreen set. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HelpOverlay(questionId: String, onClose: () -> Unit, onImproveDetection: (() -> Unit)?) {
    BackHandler(enabled = true, onBack = onClose)
    Column(
        Modifier
            .fillMaxSize()
            .semantics { paneTitle = DOSSIER_HELP_TITLE }
            .background(MaterialTheme.colorScheme.surface)
            // A semantics-free touch shield: child controls and scrolling consume first; only
            // otherwise-unhandled events are stopped from reaching the dossier underneath.
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Final)
                        event.changes.filterNot { it.isConsumed }.forEach { it.consume() }
                    }
                }
            }
            // The bar pads the status bar; this pads the sides and the navigation bar.
            .windowInsetsPadding(
                WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        TopAppBar(
            title = { Text(DOSSIER_HELP_TITLE) },
            navigationIcon = {
                IconButton(onClick = onClose) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
        )
        Box(Modifier.widthIn(max = 640.dp).fillMaxWidth().weight(1f)) {
            HelpScreen(scrollToId = questionId, onImproveDetection = onImproveDetection,
                modifier = Modifier.fillMaxSize())
        }
    }
}

/**
 * RELATED HELP: the FAQ answers that speak to THIS category, deep-linked.
 *
 * Collapsed, and placed after the evidence (signal, sightings, location, Seen with you) and before
 * Technical details, the order both dossiers share since Route A. It is still the only route
 * from a dossier into Help, which is why the header shows its answer count.
 *
 * Renders nothing for categories with no mapped questions (nearby device and unknown, whose
 * faqKey is ""). Every real category has entries, glasses and body cam included, and the drift
 * check enforces that. Mirrors iOS relatedHelpPanel, which sits in the same slot.
 */
@Composable
private fun RelatedHelpPanel(d: Detection, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    val qs = remember(d.type) { FaqContent.get(context).related(d.type) }
    if (qs.isEmpty()) return
    // Keyed on the ROW, not the category, like identityExpanded: a dossier swapped to another row
    // starts collapsed even when both rows share a type. TWIN: iOS DetectionDetailView's
    // .onChange(of: d.id) reset (helpExpanded = false).
    var expanded by remember(d.id) { mutableStateOf(false) }
    DisclosureSection(
        title = "Related help",
        summary = "${qs.size} answer${if (qs.size == 1) "" else "s"} for ${d.type.inlineLabel}",
        expanded = expanded,
        onToggle = { expanded = !expanded },
    ) {
        qs.forEach { q ->
            GroupedRow(
                headline = q.q,
                trailing = {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null)
                },
                onClick = { onOpen(q.id) },
            )
        }
    }
}

/** Shared disclosure anatomy for long supporting material. Header is one merged row (at least
 * 56dp) and states expanded / collapsed for TalkBack rather than relying on the chevron alone.
 * The state rides in [GroupedRow]'s modifier, the same node its clickable sits on. The header
 * row and, once expanded, the content share one card ([DossierCard]), as iOS draws each
 * DisclosureGroup inside its own inset-grouped section. */
@Composable
private fun DisclosureSection(
    title: String,
    summary: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    content: @Composable () -> Unit,
) {
    DossierCard {
        GroupedRow(
            headline = title,
            modifier = Modifier.semantics { stateDescription = if (expanded) "expanded" else "collapsed" },
            supporting = { Kicker(summary) },
            trailing = {
                Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null)
            },
            onClick = onToggle,
        )
        if (expanded) content()
    }
}

/** MATCH QUALITY: what matched and how strongly, a plain-language explainer, then the firmware's
 *  own hedge string verbatim at the foot of the section. Weak matches keep the amber cue on the
 *  row glyphs, as iOS matchQualityPanel does; crimson stays reserved for the category, never for
 *  certainty. */
@Composable
private fun MatchQualityPanel(d: Detection) {
    // A Desert-mode row is confidence 0 because nothing matched, so it reads "Not a match"
    // (dossierConfidenceLine) beside the plain gauge, with no weak match to verify. TWIN: iOS
    // DetectionDetailView.confidenceIsWeak.
    val weak = d.confidence < 50 && d.type != DeviceType.NEARBY_DEVICE
    // maker parses the detail and ouiVendor lowercases the MAC, so neither runs per publish.
    val (matchedOn, explainer) = remember(d.type, d.method, d.detail, d.mac, d.rid) {
        methodChipLabel(d.type, d.method, d.maker, d.methodLabel) to plainMatchLine(d)
    }
    Column(Modifier.fillMaxWidth()) {
        SectionLabel("MATCH QUALITY")
        // The two rows sit in a card ([DossierCard]); the kicker above and the footers below stay
        // bare, the inset-grouped anatomy of iOS matchQualityPanel (header, rows, footer).
        DossierCard {
            // The weak-match cue sits on the two row glyphs, never on the values: an OUI match gets
            // the fingerprint in amber, and a confidence under 50 swaps the gauge for the amber Warning
            // (shape AND colour, so the cue does not ride colour alone). A gauge, not Info: the (i)
            // is this dossier's tap-for-help glyph (the SIGNAL help button), and this row is not
            // tappable (C12-09). TWIN: iOS matchQualityPanel's "gauge.medium".
            GroupedValueRow("matched on", matchedOn, leading = {
                Icon(Icons.Outlined.Fingerprint, contentDescription = null,
                    tint = if (d.isOuiMatch) Acab.warn else MaterialTheme.colorScheme.onSurfaceVariant)
            })
            GroupedValueRow("confidence", dossierConfidenceLine(d.type, d.confidence), leading = {
                Icon(if (weak) Icons.Filled.Warning else Icons.Outlined.Speed, contentDescription = null,
                    tint = if (weak) Acab.warn else MaterialTheme.colorScheme.onSurfaceVariant)
            })
        }
        // The explainer is the section's footer, drawn as a Text with SectionFooter's inset
        // because it carries bold maker / vendor / signature spans (an AnnotatedString).
        Text(explainer, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        // Keep the broadcast's qualifications visible when technical identity is collapsed:
        // strings such as "or Quest" / "gear, no Remote ID" must never turn into certainty.
        // Firmware authors put those hedges only in this raw string, so it renders verbatim.
        // TWIN: iOS DetectionDetailView.matchQualityPanel closes with the same string in this
        // same slot. It used to be a separate CAPTURE NOTE panel of its own here, which is one
        // panel iPhone never had and which pushed Related help a slot further down.
        d.detail?.takeIf { it.isNotEmpty() }?.let {
            Text(it, color = Acab.text, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
        }
        // App-owned gloss directly under the verbatim firmware line (C12-05). TWIN: iOS
        // matchQualityPanel draws trackerOfflineNote in the same slot.
        trackerOfflineNote(d.type, d.detail)?.let {
            Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp))
        }
    }
}

/** The "matched on" row value. Word for word iOS methodChipLabel(type:method:maker:) in
 *  DetectionDetailView.swift. The two OUI telegrams are the only rewrites (the FAQ quotes both);
 *  every other method reads its own label VERBATIM, keeping its casing ("device name",
 *  "manufacturer ID", "Remote ID"). No "NAME MATCH": "matched on NAME MATCH" said match twice.
 *
 *  Some OUI hits land on the maker's OWN registered block (Axon, Utility, Motorola Solutions, and
 *  every camera brand in netcam_signatures.h), not a chipset shared with unrelated gear, so
 *  "chipset only" would understate what we know. What's uncertain is which of the vendor's
 *  products this is, which is why it keeps the amber weak-match cue. Keyed on `maker` rather than
 *  bodyCamSigDetail so network cameras stop sitting on the wrong side of this exact distinction,
 *  and so this stops being a THIRD hardcoded copy of the body-cam wire contract.
 *
 *  A Desert-mode row (NEARBY_DEVICE) matched nothing, yet desert_detect.cpp stamps its WiFi rows
 *  with method SSID and its BLE rows with none, so the method label would read "SSID" or
 *  "unknown" on a row no signature claimed. It reads "no signature" instead, keyed on the type. */
internal fun methodChipLabel(type: DeviceType, method: Int, maker: String?, methodLabel: String): String = when {
    type == DeviceType.NEARBY_DEVICE -> "no signature"
    method == 1 && maker != null -> "OUI · VENDOR ONLY"
    method == 1 -> "OUI · CHIPSET ONLY"
    else -> methodLabel
}

/** The "confidence" row value: the verdict, then the percent ("<verdict> · <n>%").
 *  Same name and same output as iOS dossierConfidenceLine(type:confidence:) in DetectionDetailView.swift.
 *
 *  A Desert-mode row (NEARBY_DEVICE) is confidence 0 because nothing matched, not because a match
 *  is weak, so it reads "Not a match" with no percent (the Log hides that 0 for the same reason). */
internal fun dossierConfidenceLine(type: DeviceType, confidence: Int): String =
    if (type == DeviceType.NEARBY_DEVICE) "Not a match"
    else "${verdictLabel(confidence)} · $confidence%"

private fun verdictLabel(pct: Int): String = when {
    pct < 50 -> "Weak match, verify"
    pct < 80 -> "Partial match"
    else -> "Strong match"
}

/** What actually matched, in plain language, composed from the method and OUI vendor.
 *  Copy mirrors iOS matchExplainer word for word. */
private fun plainMatchLine(d: Detection): AnnotatedString = buildAnnotatedString {
    // Body cam covers five signatures of very different weight under one label, so the
    // generic per-method line is too vague here (and its "shared chipset" wording is
    // wrong for a vendor's own OUI block). Name the signature that fired instead.
    val sig = d.bodyCamSigDetail
    if (sig != null) {
        appendSignatureExplainer(d, sig)
        return@buildAnnotatedString
    }
    // Replayed from the offline buffer: the stored record (firmware det_log.h) has no detail
    // field, so the signature is gone for a buffered body-cam hit even though the method and
    // confidence survived. Do NOT fall through to the OUI branch below, which would
    // confidently assert "shared chipset" wording that is simply wrong for a vendor's own
    // OUI block, and flatly false if the original hit was the conf-90 BWC DEVICE payload
    // tag. Say what we actually still know instead.
    //
    // Gated on the row REALLY being a replay, not on the detail being absent (J3): a live hit
    // with no recognized signature string (a board that predates the split) is not from the
    // buffer, and telling the owner it was contradicted the LIVE header, the Active segment and
    // the Status count on the same row. That case gets its own sentence, which claims nothing
    // about the buffer. The replay test is `hist || offline`: `hist` is the wire flag (iOS
    // isHistory), and `offline` is the one of the two this platform persists, so a reloaded
    // replay row still counts. TWIN: iOS DetectionDetailView.matchExplainer, the same two
    // sentences under the same two conditions.
    if (d.type == DeviceType.BODY_CAM) {
        append(dossierBodyCamFallbackLine(replay = d.hist || d.offline))
        return@buildAnnotatedString
    }
    // Desert mode's ambient rows match no signature but still carry a method (SSID on WiFi), so
    // the per-method lines below would claim a match. TWIN: iOS DetectionDetailView.matchExplainer,
    // the same branch in the same place.
    if (d.type == DeviceType.NEARBY_DEVICE) {
        append(dossierNearbyDeviceLine(d.detail))
        return@buildAnnotatedString
    }
    when (d.method) {
        1 -> {   // OUI: one of two very different things, and the copy has to say which
            // When `maker` resolved, the block is the MAKER'S OWN registration (Hikvision's
            // 44:19:B6, Axon's 00:25:DF), so the old "only the radio chipset matched" line was
            // flatly false, and would have contradicted a row now titled "Hikvision" on the same
            // screen. What stays open is which of that maker's products this is.
            val mk = d.maker
            if (mk != null) {
                append("Matched ")
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(mk) }
                append("'s own registered MAC block. That names the maker, not which of their products this is.")
                return@buildAnnotatedString
            }
            // No maker: the block really does name a chipset vendor, the false-positive-prone case.
            val isFlock = d.type == DeviceType.FLOCK_CAMERA || d.type == DeviceType.FLOCK_RAVEN
            val part = if (isFlock) "a part Flock shares with routers and home cameras"
                       else "a part shared with routers and home cameras"
            val vendor = d.ouiVendor
            if (vendor != null) {
                append("Only the radio chipset matched: ")
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(vendor) }
                append(", $part. The name and service IDs didn't match.")
            } else {
                append("Only the radio chipset matched, $part. The name and service IDs didn't match.")
            }
        }
        2 -> append("The name this device broadcasts matched a known signature.")
        3 -> append("The manufacturer ID in the advertisement matched a known signature.")
        4 -> append("The device advertises a service UUID tied to this hardware.")
        5 -> append("The WiFi network name matched a known signature.")
        6 -> append("The device probed for a network tied to this hardware.")
        7 -> append("The aircraft identified itself over Remote ID.")
        8 -> append("A service-data tag tied to this hardware matched.")
        9 -> append("A decoded manufacturer-data subtype matched a known signature.")
        10 -> append("This exact device was on your watchlist, so every sighting matched.")
        else -> append("No match method was reported for this hit.")
    }
}

/** The body-cam explainer when no recognized signature string came with the row. [replay] is the
 *  row REALLY being an offline-buffer replay (`hist || offline`), never "detail is nil". TWIN: iOS
 *  dossierBodyCamFallbackLine(isReplay:) in DetectionDetailView.swift, same two sentences. */
internal fun dossierBodyCamFallbackLine(replay: Boolean): String =
    if (replay) "Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired."
    else "Matched a body-worn camera signature. The board didn't report which one."

/** The MATCH QUALITY explainer for a Desert-mode row (NEARBY_DEVICE, wire t=7). desert_detect.cpp
 *  emits one for every device it hears, at confidence 0, with method SSID (WiFi) or none (BLE), so
 *  the per-method lines would claim a signature matched. [detail] is that file's address label
 *  (bleAddrLabel, desertClassifyWiFi), which the footer draws verbatim under this line; an unknown
 *  label or none (a buffered record keeps no detail) gets the first sentence alone. TWIN: iOS
 *  dossierNearbyDeviceLine(detail:) in DetectionDetailView.swift, same sentences. */
internal fun dossierNearbyDeviceLine(detail: String?): String {
    val base = "Desert mode lists every nearby device it hears, and no signature matched this one."
    return when (detail) {
        "randomized MAC" ->
            "$base \"randomized MAC\" means the address isn't from a maker's registered block. Phones, watches, and earbuds use addresses like this and change them often, so the same device can come back under a new one."
        "hardware OUI" ->
            "$base \"hardware OUI\" means the address starts with a block registered to a maker, so it usually stays the same between sightings."
        "OUI unknown" ->
            "$base \"OUI unknown\" means the board couldn't tell whether the address comes from a maker's registered block or is randomized."
        else -> base
    }
}

/** The note under a tracker's verbatim "(offline)" firmware detail: the firmware means the tag is
 *  separated from its owner, which a reader can take for the app's OFFLINE buffer-replay tag.
 *  Tracker AND the suffix; any other category's "(offline)" gets no note. The firmware string
 *  itself stays verbatim. TWIN: iOS trackerOfflineNote(type:detail:) in DetectionDetailView.swift. */
internal fun trackerOfflineNote(type: DeviceType, detail: String?): String? =
    if (type == DeviceType.TRACKER && detail?.endsWith("(offline)") == true)
        "offline here means separated from its owner, not replayed from the offline buffer."
    else null

/** The dossier's "why flagged" footer. A method whose label equals the source ("Remote ID" over
 *  "Remote ID", a drone) says it once. A Desert-mode row (NEARBY_DEVICE) was flagged by nothing:
 *  its method is SSID on WiFi and none on BLE, so it names only the radio and desert mode.
 *  TWIN: iOS dossierFlaggedLine(type:methodLabel:sourceLabel:). */
internal fun dossierFlaggedLine(type: DeviceType, methodLabel: String, sourceLabel: String): String = when {
    type == DeviceType.NEARBY_DEVICE -> "Heard over $sourceLabel in desert mode."
    methodLabel.equals(sourceLabel, ignoreCase = true) -> "Flagged by $methodLabel."
    else -> "Flagged by $methodLabel over $sourceLabel."
}

/** The hero subtitle: the node handle, then the maker or vendor unless the headline already
 *  says it (case-insensitive exact match, no fuzzy match: "Flock Safety" under "FlockSafety" stays).
 *  TWIN: iOS dossierHeroSubtitle(node:makerOrVendor:headline:) in DetectionDetailView.swift. */
internal fun dossierHeroSubtitle(node: String, makerOrVendor: String, headline: String): String =
    if (makerOrVendor.equals(headline, ignoreCase = true)) "NODE $node"
    else "NODE $node · $makerOrVendor"

/** The caption under a drone's location thumbnail, drawn only when the drone reported a valid
 *  pilot coordinate (the operator marker on the thumbnail). TWIN: iOS droneOperatorCaption. */
internal const val DRONE_OPERATOR_CAPTION = "operator position, from the drone's Remote ID"

/** The firmware detail strings for the five body-cam signatures, exactly as axon_detect.cpp
 *  and police_detect.cpp write them. Membership selects a per-signature explainer
 *  below. */
private val BODY_CAM_SIGNATURES =
    setOf("BWC DEVICE", "Axon OUI", "Utility BodyWorn", "Motorola Solutions OUI", "WatchGuard Video OUI")

/** The body-cam signature behind this hit, when the board reported one. Null for every other
 *  category, and for a buffered record (the offline store keeps no detail field). */
private val Detection.bodyCamSigDetail: String?
    get() = detail?.takeIf { type == DeviceType.BODY_CAM && it in BODY_CAM_SIGNATURES }

/** Which body-cam signature fired, and how much weight it carries. The five sources under
 *  this one category range from Axon's own broadcast identifier to a vendor-block proxy, and
 *  without this they all read as "Body camera". Says nothing about the numbers: the verdict
 *  and percentage on the confidence row above already carry the strength. Copy mirrors iOS
 *  word for word. */
private fun AnnotatedString.Builder.appendSignatureExplainer(d: Detection, sig: String) {
    fun name() = withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(sig) }
    when (sig) {
        "BWC DEVICE" -> {
            append("Matched "); name()
            append(", the tag Axon body cams broadcast about themselves. It rides in the advertisement rather than in the address, so it holds even when the device randomizes its MAC. This is the strongest body cam signature the board carries.")
        }
        "Axon OUI" -> {
            append("Matched "); name()
            append(" only. The address block is Axon Enterprise's, but the broadcast body cam tag never appeared, so this is Axon-made gear of some kind. They ship other products on the same block.")
        }
        "Utility BodyWorn" -> {
            append("Matched "); name()
            if (d.method == 2) {
                append(" by broadcast name. The device announced itself as part of Utility's body cam system, which is a deliberate self-identification and a solid match, though a name is easy for anything to copy.")
            } else {
                append(" by address block only. The block is Utility Inc's, but the broadcast name didn't match and Utility ships other gear on it, so treat this as a maybe.")
            }
        }
        "Motorola Solutions OUI" -> {
            append("Matched "); name()
            append(", a vendor proxy rather than a body cam signature. The block is Motorola Solutions' own, so the maker is right, but they also sell two-way radios, docks, and site infrastructure on it. Read this as their equipment nearby, not a confirmed camera.")
        }
        "WatchGuard Video OUI" -> {
            append("Matched "); name()
            append(", a vendor proxy rather than a body cam signature. The block is WatchGuard Video's own, so the maker is right, but they also put in-car video systems and docks on it. WatchGuard belongs to Motorola Solutions, so the Motorola Solutions switch controls this match. Read this as their equipment nearby, not a confirmed body cam.")
        }
    }
}

/** Field checklist for weak / chipset-only hits: what to look for, whether it sticks
 *  around, and a one-tap star. The checkboxes are scratch state, local to this screen. */
@Composable
private fun ConfirmItPanel(
    d: Detection, firstSeen: Long?, nowMs: Long, watched: Boolean, onWatch: () -> Unit,
) {
    var looked by remember(d.id) { mutableStateOf(false) }
    var secondPass by remember(d.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        SectionLabel("CONFIRM IT", color = Acab.warn)   // amber header, iOS parity: this is a to-do, not chrome
        // The three rows in one card ([DossierCard]), the iOS confirmItPanel section.
        DossierCard {
            CheckRow(d.type.confirmPrompt,
                checked = looked) { looked = !looked }
            val span = seenSpan(firstSeen, nowMs)
            CheckRow(
                if (span != null) "Still here on a second pass? It's been seen ${d.count}× over $span so far."
                else "Still here on a second pass? It's been seen ${d.count}× so far.",
                checked = secondPass) { secondPass = !secondPass }
            GroupedRow(
                headline = "Watch it to get pinged every time this exact device shows up.",
                trailing = { WatchChip(watched, onWatch) },
            )
        }
    }
}

/** Tappable checkbox row; the check is just a field note for the user, nothing persists. */
@Composable
private fun CheckRow(text: String, checked: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 56.dp)
            .toggleable(
                value = checked,
                role = Role.Checkbox,
                onValueChange = { onToggle() },
            )
            .semantics(mergeDescendants = true) {}
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // The rule both apps share: the UNREAD prompt is the bright one and a completed row dims,
        // so finished items recede and the pending work stands out; the checked box takes the
        // scheme's checked colour. TWIN: iOS DetectionDetailView.confirmItPanel, whose Toggle
        // labels dim when on the same way. The row toggles; the Checkbox is display-only.
        Checkbox(checked = checked, onCheckedChange = null)
        Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
            color = if (checked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
    }
}

/** Filter chip wired to the same watch/star action as the Watch button above. Selected while
 *  watched; the scheme draws the selected fill, the gold stays on the star glyph only. */
@Composable
private fun WatchChip(watched: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = watched,
        onClick = onClick,
        // Same pair as WatchButton and the iOS CONFIRM IT star row's button: the action verb,
        // spoken as drawn on both platforms (neither side overrides the label). The chip's
        // selected state is the watched state, as the iOS button's selected trait is.
        label = { Text(if (watched) "Stop Watching" else "Watch") },
        leadingIcon = {
            Icon(if (watched) Icons.Filled.Star else Icons.Filled.StarBorder, contentDescription = null,
                tint = Acab.watchTone, modifier = Modifier.size(FilterChipDefaults.IconSize))
        },
    )
}

/** Amber warning for experimental detectors: this category's signatures are not field-verified. */
@Composable
private fun ExperimentalNote(type: DeviceType) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(24.dp))
        Text("Experimental detector. ${type.experimentalNoun} signatures are not field-verified yet, so treat this as a maybe.",
            Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = Acab.warn)
    }
}

/** Dim footer recapping how the node was matched. */
@Composable
private fun WhyFlagged(d: Detection, tone: Color) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.GpsFixed, contentDescription = null,
            tint = tone, modifier = Modifier.size(16.dp))
        Text(dossierFlaggedLine(d.type, d.methodLabel, d.sourceLabel), Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Dark-mode tile filter for the light MAPNIK tiles: a color-matrix inversion
 *  concatenated with a partial-saturation matrix, so the inverted land/water hues read
 *  as muted dark surfaces instead of neon. The standard osmdroid dark-map approach. */
// R4: the one shared dark-tile filter, used by both this mini-map and the full MapScreen so
// the two surfaces render an identical tint (inversion first, then saturation).
internal val osmDarkTileFilter: ColorMatrixColorFilter by lazy {
    val inversion = ColorMatrix(
        floatArrayOf(
            -1f, 0f, 0f, 0f, 255f,
            0f, -1f, 0f, 0f, 255f,
            0f, 0f, -1f, 0f, 255f,
            0f, 0f, 0f, 1f, 0f,
        )
    )
    // Invert first, then pull chroma down to ~30% of the inverted result.
    val adjust = ColorMatrix().apply { setSaturation(0.3f) }
    adjust.preConcat(inversion)
    ColorMatrixColorFilter(adjust)
}

/** Static map thumbnail centered on the sighting, with the device pin, a tracker's accumulated
 * session breadcrumb, and (for drones) a separate operator marker. Tapping the thumbnail (it
 * never pans or zooms itself) jumps to the full Map tab centered close-in on this spot. */
@Composable
private fun LocationPanel(
    d: Detection,
    lat: Double,
    lon: Double,
    breadcrumbTrail: List<Pair<Double, Double>>,
    onOpenInMap: (Double, Double) -> Unit,
    headerStacked: Boolean = false,
) {
    val context = LocalContext.current
    val markers = rememberCategoryMarkers()
    val operatorMarker = rememberOperatorMarker()
    // The corroboration line below asks the known-ALPR dataset for its nearest node, which is a
    // full pass over every node it holds. The dossier live-shadows its row at ~3 Hz, so the
    // answer is memoised on everything that can actually move it: the type, the spot, the parsed
    // dataset, and the tier toggle that decides which records may vouch for a hit at all.
    val alpr = remember { AlprStore.getInstance(context) }
    val alprNodes by alpr.nodes.collectAsState()
    val alprShowUnverified by alpr.showUnverified.collectAsState()
    val nearestAlpr = remember(d.type, lat, lon, alprNodes, alprShowUnverified) {
        if (d.type == DeviceType.FLOCK_CAMERA || d.type == DeviceType.FLOCK_RAVEN)
            alpr.nearest(lat, lon) else null
    }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    val liveMap = remember { mutableStateOf<MapView?>(null) }
    val mapResumed = remember { booleanArrayOf(false) }
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    if (!mapResumed[0]) liveMap.value?.onResume()
                    mapResumed[0] = liveMap.value != null
                }
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE -> {
                    if (mapResumed[0]) liveMap.value?.onPause()
                    mapResumed[0] = false
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (mapResumed[0]) liveMap.value?.onPause()
            mapResumed[0] = false
        }
    }

    Column(Modifier.fillMaxWidth()) {
        // At large text the coordinate drops under the heading, the fallback iOS locationPanel
        // gets from ViewThatFits; side by side, the unweighted coordinate would squeeze
        // "LOCATION" until the word wrapped mid-word.
        if (headerStacked) {
            SectionLabel("LOCATION")
            Text(coordText(lat, lon), Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
                style = DossierCoordStyle, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Row(Modifier.fillMaxWidth()) {
                SectionLabel("LOCATION", Modifier.weight(1f))
                Text(coordText(lat, lon), Modifier.padding(top = 16.dp, bottom = 8.dp, end = 16.dp),
                    style = DossierCoordStyle, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        // The age line, the corroboration, the thumbnail and its captions share one card
        // ([DossierCard]) under the bare LOCATION header row, the iOS locationPanel section
        // (header outside, rows and the thumbnail inside).
        DossierCard {
            Column(Modifier.padding(top = 4.dp, bottom = 8.dp)) {
                // gpsAgeSec describes the wire coordinate on THIS row. Once a different strongest
                // sample owns the observer pin, applying this row's age to it would be false.
                val wireLat = d.lat
                val wireLon = d.lon
                if (wireLat != null && wireLon != null && wireLat == lat && wireLon == lon) {
                    // The board stamped this fix from a stale phone position (offline / Desert mode),
                    // so flag how old it is.
                    d.locationAgeDetail?.let { age ->
                        Text(age, Modifier.padding(horizontal = 16.dp),
                            style = MaterialTheme.typography.bodyMedium, color = Acab.warn)
                    }
                }
                // CORROBORATION, positive-only (mirrors iOS). An ALPR-type hit within ~150m of a
                // community-mapped camera is strong confirmation, and names the mapped maker when known.
                // We NEVER show a "no mapped camera" line: OSM lags installs and cruiser ALPR is meant to
                // move, so absence is not evidence of a false positive (the confidence row is that tell).
                // Null for anything that is not an ALPR-type hit: the memo above owns that gate.
                nearestAlpr?.let { (meters, maker, tier) ->
                    if (meters <= 150) {
                        val m = meters.roundToInt()
                        // This line is the app using the mapped record as corroboration. Only tier 1
                        // carries structured manufacturer attribution; tier 0 can support the mapped
                        // location without naming a maker, while tier 2 stays explicitly a legacy
                        // candidate. Mirrors iOS DetectionDetailView.
                        Text(
                            when {
                                tier == 0 ->
                                    "\u2713 near a mapped ALPR camera · no structured manufacturer · $m m"
                                tier == 2 -> "near a legacy ALPR candidate · $m m"
                                tier == ALPR_TIER_LEGACY_FORMAT ->
                                    "\u2713 near a mapped ALPR camera · legacy dataset format · $m m"
                                tier == 1 && maker.isEmpty() ->
                                    "\u2713 near a mapped ALPR camera · manufacturer attributed · $m m"
                                tier == 1 -> "\u2713 matches a mapped $maker camera · $m m"
                                else -> "near a mapped ALPR record · unknown attribution tier · $m m"
                            },
                            Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.bodyMedium,
                            // ALPR WORDS take the text-safe tint (textTone), never the ALPR hue (the
                            // textTone KDoc in Theme.kt says why). nearestAlpr is non-null only for ALPR
                            // types, so this resolves to primary.
                            color = if (tier == 1 || tier == ALPR_TIER_LEGACY_FORMAT)
                                d.type.textTone() else Acab.warn,
                        )
                    }
                }
                // The whole thumbnail is one tap target: the inner MapView refuses every touch at
                // dispatch, so the clickable on this wrapper receives the tap and hands off to the
                // real map, centered on this sighting.
                Box(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .height(170.dp)
                        .clip(MaterialTheme.shapes.medium)
                        .clickable(role = Role.Button) { onOpenInMap(lat, lon) }
                        .semantics {
                            contentDescription = if (breadcrumbTrail.count {
                                    validCoord(it.first, it.second)
                                } >= 2) {
                                "Open this location and phone breadcrumb trail from this session in the map"
                            } else {
                                "Open this location in the map"
                            }
                        },
                ) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                        // osmdroid setup (user agent + bounded tile cache) MUST land before the first tile
                        // fetch, and the factory is the last point before MapView is constructed. It used
                        // to sit in a remember{} in composition, which lint flags as a side effect in
                        // remember (it is: remember is for caching, not for running things). Idempotent
                        // via compareAndSet, so calling it per factory is free.
                        configureOsmdroid(ctx)
                            // A TRUE static thumbnail, the analog of iOS's .allowsHitTesting(false) on this
                            // same panel: refuse every touch at dispatch so the gesture falls through to the
                            // scrolling sheet instead of being half-eaten by a map that won't pan anyway.
                            // The real map tab is for panning.
                            object : MapView(ctx) {
                                override fun dispatchTouchEvent(event: MotionEvent?): Boolean = false
                            }.apply {
                                liveMap.value = this
                                if (lifecycleOwner.lifecycle.currentState.isAtLeast(
                                        androidx.lifecycle.Lifecycle.State.RESUMED)) {
                                    onResume()
                                    mapResumed[0] = true
                                }
                                importantForAccessibility =
                                    android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                                setTileSource(TileSourceFactory.MAPNIK)
                                // MAPNIK ships light-only tiles; invert + desaturate so the thumbnail
                                // sits in the dark app instead of glowing like a flashlight.
                                overlayManager.tilesOverlay.setColorFilter(osmDarkTileFilter)
                                setMultiTouchControls(false)
                                // With pinch off, osmdroid force-shows its +/- buttons as the "only zoom
                                // affordance left" - on a static thumbnail they're clutter on top of the
                                // OSM attribution (same overlap the main map hid them for).
                                zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
                                controller.setZoom(15.0)
                                controller.setCenter(GeoPoint(lat, lon))
                                val validTrail = breadcrumbTrail.filter {
                                    validCoord(it.first, it.second)
                                }
                                if (validTrail.size >= 2) {
                                    overlays.add(
                                        Polyline(this).apply {
                                            setPoints(validTrail.map { GeoPoint(it.first, it.second) })
                                            outlinePaint.color = Acab.trackerTone.toArgb()
                                            outlinePaint.strokeWidth = 4f
                                            outlinePaint.pathEffect =
                                                DashPathEffect(floatArrayOf(18f, 12f), 0f)
                                        }
                                    )
                                }
                                overlays.add(
                                    Marker(this).apply {
                                        position = GeoPoint(lat, lon)
                                        icon = markers.getValue(d.type)
                                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                        title = d.type.category
                                    }
                                )
                                // drones broadcast the operator's position too; drop a pin for it
                                val plat = d.pilotLat
                                val plon = d.pilotLon
                                if (d.type == DeviceType.DRONE && plat != null && plon != null &&
                                    validCoord(plat, plon)) {
                                    overlays.add(
                                        Marker(this).apply {
                                            position = GeoPoint(plat, plon)
                                            icon = operatorMarker
                                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                            title = "Operator"
                                        }
                                    )
                                }
                            }
                        },
                        // The screen live-shadows the row (~3 Hz), so the coordinates can move while the
                        // panel is up: a drone in flight, or a closest-approach migration on a stronger
                        // sighting. The header text and openOnMap already recompose with the new values;
                        // without this block the retained MapView kept the first composition's center and
                        // pins and the panel disagreed with itself. Signature-guarded so the 3 Hz feed
                        // doesn't churn osmdroid when nothing moved; zoom is deliberately untouched.
                        update = { map ->
                            val sig = listOf(lat, lon, d.pilotLat, d.pilotLon, breadcrumbTrail)
                            if (map.tag != sig) {
                                map.tag = sig
                                val validTrail = breadcrumbTrail.filter { validCoord(it.first, it.second) }
                                val trail = map.overlays.filterIsInstance<Polyline>().firstOrNull()
                                if (validTrail.size >= 2) {
                                    val points = validTrail.map { GeoPoint(it.first, it.second) }
                                    if (trail != null) {
                                        trail.setPoints(points)
                                    } else {
                                        map.overlays.add(
                                            0,
                                            Polyline(map).apply {
                                                setPoints(points)
                                                outlinePaint.color = Acab.trackerTone.toArgb()
                                                outlinePaint.strokeWidth = 4f
                                                outlinePaint.pathEffect =
                                                    DashPathEffect(floatArrayOf(18f, 12f), 0f)
                                            },
                                        )
                                    }
                                    fitDetailBreadcrumb(map, lat, lon, validTrail, sig)
                                } else {
                                    if (trail != null) map.overlays.remove(trail)
                                    map.controller.setCenter(GeoPoint(lat, lon))
                                }
                                val pins = map.overlays.filterIsInstance<Marker>()
                                pins.firstOrNull { it.title != "Operator" }?.position = GeoPoint(lat, lon)
                                val plat = d.pilotLat
                                val plon = d.pilotLon
                                val op = pins.firstOrNull { it.title == "Operator" }
                                if (d.type == DeviceType.DRONE && plat != null && plon != null &&
                                    validCoord(plat, plon)) {
                                    if (op != null) {
                                        op.position = GeoPoint(plat, plon)
                                    } else {
                                        map.overlays.add(
                                            Marker(map).apply {
                                                position = GeoPoint(plat, plon)
                                                icon = operatorMarker
                                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                                title = "Operator"
                                            }
                                        )
                                    }
                                } else if (op != null) {
                                    map.overlays.remove(op)
                                }
                                map.invalidate()
                            }
                        },
                        onRelease = { map ->
                            if (mapResumed[0]) map.onPause()
                            mapResumed[0] = false
                            if (liveMap.value === map) liveMap.value = null
                            map.onDetach()
                        },
                    )
                    // Corner label that makes the tap discoverable; the whole thumbnail is the target.
                    // Opaque, so it reads the same over any tile. Top-trailing like iOS, which also keeps
                    // it off the OSM attribution's bottom corner.
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .padding(8.dp)
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.shapes.small)
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    ) {
                        Text("Open in Map", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                // Captions the dashed line on the thumbnail above, so it reads under the map rather
                // than over it, and the same trail gate decides both. Same placement as iOS
                // DetectionDetailView.locationPanel, which renders this caption after its thumbnail.
                if (breadcrumbTrail.count { validCoord(it.first, it.second) } >= 2) {
                    Text(
                        "Phone breadcrumb trail · this session",
                        Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                // Names the operator marker on the thumbnail, under it like the trail caption, and on the
                // same gate that draws that marker (a drone with a valid pilot coordinate). The fit is
                // unchanged, so the marker can sit outside the frame the caption describes. TWIN: iOS
                // DetectionDetailView.locationPanel, Label(droneOperatorCaption, systemImage: "person.fill").
                val pla = d.pilotLat
                val plo = d.pilotLon
                if (d.type == DeviceType.DRONE && pla != null && plo != null && validCoord(pla, plo)) {
                    Row(
                        Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Person, contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                        Text(DRONE_OPERATOR_CAPTION, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

internal data class DetailBreadcrumbBounds(
    val north: Double,
    val east: Double,
    val south: Double,
    val west: Double,
)

private const val DETAIL_MAP_MAX_LAT = 85.05112878 // Web Mercator's finite latitude limit

/** Frame padding and the smallest box the dossier thumbnail will ask for.
 *
 *  SHARED WITH iOS - these two ARE the same numbers, applied in this same order (pad first, then
 *  floor): detectionDetailMapRegion in MapTabView.swift computes `max(span * 1.35, 0.008)` on both
 *  axes, so one pin and one trail get one frame on both phones. 0.008 deg of latitude is about
 *  890 m, and it is the fixed span the iOS thumbnail used before either side gained a fit: it is
 *  there so a lone pin, or a trail shorter than the 25 m crumb gate, still shows the neighbourhood
 *  around the sighting instead of a rooftop with no context. Android's own previous behaviour was
 *  a flat zoom 15 (roughly twice this box), so the floor also keeps the short-trail view from
 *  tightening well past what this screen has ever shown.
 *
 *  A trail of FEWER THAN TWO valid crumbs is not folded in on either platform. One crumb draws
 *  no polyline anywhere - both this screen's fit call sites and iOS's thumbnail gate the line at
 *  two points - so widening the frame around it would trade real context near the pin for a point
 *  nothing renders. The gate lives in `detailBreadcrumbBounds` and in `detectionDetailMapRegion`
 *  itself, not only at the call sites, so the pure fit policy is the same on both phones.
 *
 *  Two platform-derived differences are left, both from the renderer rather than the policy: the
 *  24 px border zoomToBoundingBox adds while fitting this box to the view, which MapKit needs no
 *  equivalent for, and the latitude ceiling - osmdroid is Web Mercator, so this clamps to
 *  DETAIL_MAP_MAX_LAT where MapKit keeps its region inside +/-90. */
private const val DETAIL_MAP_MIN_SPAN_DEG = 0.008
private const val DETAIL_MAP_FIT_SCALE = 1.35

private fun normalizeLon360(lon: Double): Double = ((lon % 360.0) + 360.0) % 360.0

private fun normalizeLon180(lon: Double): Double {
    val out = ((lon + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
    // Keep +180 when that is the supplied edge; either spelling is the same meridian, but this
    // avoids flipping a non-crossing interval merely because `% 360` chose -180.
    return if (out == -180.0 && lon > 0.0) 180.0 else out
}

/** Pure fit policy for a detail breadcrumb. Longitudes use the smallest circular arc, so a trail
 * crossing 179E -> 179W spans two degrees rather than almost the whole world. `west > east` is the
 * ordinary osmdroid representation of an antimeridian-crossing box. Latitude is padded and
 * clamped to Web Mercator before a BoundingBox is constructed. A trail of fewer than two valid
 * crumbs frames the pin alone, which is what both call sites already asked for and what iOS does
 * (see DETAIL_MAP_MIN_SPAN_DEG above). */
internal fun detailBreadcrumbBounds(
    pin: Pair<Double, Double>,
    crumbs: List<Pair<Double, Double>>,
): DetailBreadcrumbBounds? {
    val validCrumbs = crumbs.filter { validCoord(it.first, it.second) }
    val points = buildList {
        if (validCoord(pin.first, pin.second)) add(pin)
        // Two-point gate, shared with iOS detectionDetailMapRegion. A lone crumb is not a trail:
        // no polyline is drawn for it here or there, so folding it in would zoom the thumbnail
        // out around something invisible and push the pin's own surroundings off the frame.
        if (validCrumbs.size >= 2) addAll(validCrumbs)
    }
    if (points.isEmpty()) return null

    val lats = points.map { it.first.coerceIn(-DETAIL_MAP_MAX_LAT, DETAIL_MAP_MAX_LAT) }
    var south = lats.min()
    var north = lats.max()
    val latCenter = (north + south) / 2.0
    val latSpan = maxOf((north - south) * DETAIL_MAP_FIT_SCALE, DETAIL_MAP_MIN_SPAN_DEG)
    south = (latCenter - latSpan / 2.0).coerceAtLeast(-DETAIL_MAP_MAX_LAT)
    north = (latCenter + latSpan / 2.0).coerceAtMost(DETAIL_MAP_MAX_LAT)

    val lons = points.map { normalizeLon360(it.second) }.sorted()
    var gapAfter = 0
    var largestGap = Double.NEGATIVE_INFINITY
    for (i in lons.indices) {
        val next = if (i == lons.lastIndex) lons.first() + 360.0 else lons[i + 1]
        val gap = next - lons[i]
        if (gap > largestGap) {
            largestGap = gap
            gapAfter = i
        }
    }
    val west360 = if (gapAfter == lons.lastIndex) lons.first() else lons[gapAfter + 1]
    val rawSpan = (360.0 - largestGap).coerceAtLeast(0.0)
    val lonCenter = west360 + rawSpan / 2.0
    val lonSpan = maxOf(rawSpan * DETAIL_MAP_FIT_SCALE, DETAIL_MAP_MIN_SPAN_DEG)
        .coerceAtMost(359.999)
    val west = normalizeLon180(lonCenter - lonSpan / 2.0)
    val east = normalizeLon180(lonCenter + lonSpan / 2.0)
    return DetailBreadcrumbBounds(north = north, east = east, south = south, west = west)
}

/** Frame the whole accumulated tracker breadcrumb plus its strongest-sighting pin. [tag] cancels
 * a posted fit when a newer trail arrives before layout completes. */
private fun fitDetailBreadcrumb(
    map: MapView,
    pinLat: Double,
    pinLon: Double,
    crumbs: List<Pair<Double, Double>>,
    tag: Any,
) {
    val bounds = detailBreadcrumbBounds(pinLat to pinLon, crumbs) ?: return
    val box = runCatching {
        org.osmdroid.util.BoundingBox(
            bounds.north, bounds.east, bounds.south, bounds.west,
        )
    }.getOrNull() ?: return
    map.post {
        if (map.tag != tag) return@post
        runCatching { map.zoomToBoundingBox(box, false, 24) }
    }
}

/**
 * "Seen with you": what the phone's own breadcrumb trail says about this tracker, and nothing else.
 *
 * TRACKERS ONLY, and the caller already gated on it. The manager collects crumbs for no other type,
 * so a body cam has nothing to score; showing it an empty panel would claim a check that never ran.
 *
 * NEVER AN ALARM. No tone colour, no icon, no amber. A band is a header plus two dim paragraphs, and
 * the second one names the innocent explanation. The NONE, NOT_MEASURED and no-crumb states get no
 * header at all, so a header can never assert something the body then walks back.
 *
 * FIVE STATES, FIVE SENTENCES, and none of them may be borrowed from another: a band, "scored and
 * found nothing" (NONE), "refused to score" (NOT_MEASURED), "location is off", and "no position was
 * recorded this session". Every one of those sentences is authored in FollowEvidence, never here.
 *
 * COST. The span pass is O(n^2) over up to 120 crumbs (7140 haversines). That is cheap, but it must
 * never ride the ~3 Hz publish this screen live-shadows, or a Desert-mode flood would pay for it on
 * every frame. So: score once when the screen appears, then at most once per 5 s, off a snapshot
 * copy of the crumb list taken outside storeLock (crumbs() already hands back a .toList()).
 */
@Composable
private fun FollowEvidencePanel(
    id: String,
    // Passed through rather than hardcoded to TRACKER at the evaluate() call below. The caller
    // already gated on type, so this looks redundant, and that is the point: the scorer carries its
    // own type guard so that widening crumb collection past trackers cannot start scoring body cams
    // by accident. Handing it a constant would quietly disarm the guard on this platform only, and
    // iOS would keep an assertion Android had lost.
    type: DeviceType,
    ble: AcabBleManager,
    timeBasis: TimeBasis,
) {
    val context = LocalContext.current
    val demo by ble.demoMode.collectAsState()
    // The 5 s recompute clock. A plain counter rather than a re-read of the feed: the feed changes
    // ~3 Hz and almost none of those changes can move a band, which needs a fresh crumb, and a
    // crumb needs 60 s and 25 m.
    var tick by remember(id) { mutableStateOf(0) }
    LaunchedEffect(id) {
        while (true) {
            delay(5_000)
            tick++
        }
    }
    // Asked on every recompute rather than remembered: the user can grant location from the system
    // sheet while this screen sits open, and the panel would otherwise keep saying we aren't using it.
    //
    // FINE *or* COARSE, matching the manager's own hasLocationPermission() gate and iOS's
    // authorizedWhenInUse/Always test. Testing FINE alone would tell a user who chose Android 12's
    // "Approximate location" that the app is not using location at all, which is false: coarse fixes
    // do reach freshSelfCoord and do produce crumbs. Getting this wrong is not a cosmetic slip in a
    // panel whose entire job is to say honestly what the app did and did not look at.
    val locationGranted = ContextCompat.checkSelfPermission(
        context, android.Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
        context, android.Manifest.permission.ACCESS_COARSE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED

    val crumbs = remember(id, tick) { ble.crumbs(id) }
    val ev = remember(id, tick, timeBasis, type) {
        FollowEvidence.evaluate(
            type = type,
            crumbs = crumbs,
            // The FIRST CRUMB, not first-seen. first-seen is when the device was first HEARD, and
            // it comes back off the persisted store on launch while the crumbs do not. Handing the
            // scorer first-seen made it narrate a window the trail never covered, and let the
            // bands' time floors be satisfied by minutes containing no crumbs at all. The scorer's
            // parameter was RENAMED along with the fix precisely so this call site could not keep
            // passing the wrong instant and still compile.
            firstCrumbAtMs = ble.firstCrumbAt(id),
            lastCrumbAtMs = ble.lastCrumbAt(id),
            timeBasis = timeBasis,
        )
    }

    // No crumbs at all has three different causes and they are not interchangeable. Demo seeds the
    // store directly and never runs the live filing path, so a demo tracker has zero crumbs for a
    // reason that is neither a permission problem nor a fix problem: it says the ordinary "not
    // enough ground" line and stays at band NONE forever. Fabricating follow evidence inside a tour
    // would teach the user to trust a fabricated judgement.
    val hasTrail = crumbs.isNotEmpty() || demo
    val body = when {
        // A trail exists (or this is the tour), so the model owns the sentence, and it now has FOUR
        // of them. NOT_MEASURED is the one this has to keep distinct: a refusal (a derived time
        // basis off the board's offline buffer, a clock jump, a window longer than an address
        // lives) is not a finding, and reporting it through the NONE branch is how the panel came
        // to tell a user "not across enough ground to read anything into yet" about a tag it had
        // never compared against anything. Under-claiming cuts both ways here: a false reassurance
        // is as much a false statement as a false alarm, and it is the one nobody audits.
        hasTrail -> ev.detailText
        !locationGranted -> FollowEvidence.NO_LOCATION_TEXT
        else -> FollowEvidence.NO_FIX_TEXT
    }
    // EVERY state, no exceptions. This used to be suppressed on the two no-crumb states, on the
    // reasoning that a session-and-trackers caveat under them would qualify a measurement that was
    // never taken. That had it backwards. The no-crumb states are precisely where the user needs to
    // be told the memory is session-scoped: after an app restart the store row is restored from
    // disk and the crumbs are not, so the panel says there is nothing to compare, and this is the
    // one line that explains why a tag they watched ride along with them yesterday shows nothing
    // today. Suppressing it left the false-looking sentence standing with no context at all.
    val scope = FollowEvidence.SCOPE_TEXT

    // Always the card, and the header only when a band fired. Same shape as iOS: the panel chrome is
    // constant so the screen does not visibly restructure itself when a band appears, but the header
    // is conditional so it can never assert a finding that the body immediately walks back. Reading
    // the label straight off the band covers the empty-crumb and refused states for free: fewer than
    // three crumbs can only score NONE, and NONE and NOT_MEASURED both have no label.
    val label = ev.band.label
    GroupedCard(Modifier.padding(horizontal = 16.dp)) {
        Column(
            Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp,
                top = if (label != null) 0.dp else 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (label != null) {
                // SectionLabel supplies its own 16dp top.
                SectionLabel(FollowEvidence.KICKER, inset = false)
                // Plain body text, NOT a header: the band label is content, and passing it through
                // a casing transform is exactly how two platforms end up rendering it differently.
                Text(label, style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface)
            }
            Text(body, style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(scope, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** The SIGNAL header's trailing word: SAMPLE for sample rows (an uppercase sibling of LIVE /
 *  STALE; the banner and pill already say sample, and LIVE would claim a real reading), else
 *  STALE / LIVE from the store's clock. The sparkline keeps its category hue for sample rows
 *  because `stale` is false there. TWIN: iOS dossierSignalWord(isDemoMode:stale:) in
 *  DetectionDetailView.swift, same three words. Pinned in DetailTimeLabelsTest. */
internal fun dossierSignalWord(demo: Boolean, stale: Boolean): String = when {
    demo -> "SAMPLE"
    stale -> "STALE"
    else -> "LIVE"
}

/** The Technical details "Last seen" value. Sample data reads "now" (relativeAgo's word for the
 *  freshest bucket), the same demo arm the SIGNAL header's `stale` takes: the seed stamps its rows
 *  once, so the measured age used to grow to "9m ago" under a live header (C12-03). [measured]
 *  is only called for a real row. TWIN: iOS dossierLastSeenValue(isDemoMode:measured:) in
 *  DetectionDetailView.swift, same word. Pinned in DetailTimeLabelsTest. */
internal inline fun dossierLastSeenValue(demo: Boolean, measured: () -> String): String =
    if (demo) "now" else measured()

/** Outlined button that copies the MAC and says Copied for a beat (announced politely). Outlined,
 *  not filled: copying an address is the dossier's least urgent action, so it must not outrank
 *  Watch (tonal) or Mute… (outlined); iOS draws it as a plain tinted row (C12-11). */
@Composable
private fun CopyMacButton(mac: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    OutlinedButton(
        onClick = {
            val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clip.setPrimaryClip(ClipData.newPlainText("MAC", mac))
            copied = true
        },
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
            contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
        Text(if (copied) "Copied" else "Copy MAC Address")
    }
}

/** One explicit mute entry point: Mute… opens the scoped options; once a rule exists the same
 *  button reads Unmute and lifts it at once. The rule's state and Change render under the pair
 *  (MutedStateRows), so success is visible and reversible without leaving the dossier. TWIN: iOS
 *  DetectionDetailView.ignoreButton, same labels. */
@Composable
private fun MuteButton(
    muted: Boolean,
    onUnmute: () -> Unit,
    onOptions: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (muted) {
        Button(onClick = onUnmute, modifier = modifier) {
            Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                modifier = Modifier.size(ButtonDefaults.IconSize))
            Spacer(Modifier.size(ButtonDefaults.IconSpacing))
            Text("Unmute")
        }
    } else {
        OutlinedButton(onClick = onOptions, modifier = modifier) {
            Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                modifier = Modifier.size(ButtonDefaults.IconSize))
            Spacer(Modifier.size(ButtonDefaults.IconSpacing))
            Text("Mute…")
        }
    }
}

/** An existing mute rule's state, under Watch and Unmute: the headline, the status sentence when
 *  the rule is not muting right now, and Change to reopen the scoped options. TWIN: iOS
 *  DetectionDetailView.mutedStateSection. */
@Composable
private fun MutedStateRows(mutedScope: String, muteStatus: MuteRuleStatus?, onOptions: () -> Unit) {
    val active = muteStatus == MuteRuleStatus.ACTIVE
    val headline = when (muteStatus) {
        MuteRuleStatus.ACTIVE -> "MUTED · ${mutedScope.uppercase()}"
        MuteRuleStatus.CURRENT_LOCATION_REQUIRED -> "MUTE SET · ACCURATE LOCATION NEEDED"
        MuteRuleStatus.OUTSIDE_RADIUS -> "MUTE SET · OUTSIDE SAVED AREA"
        MuteRuleStatus.EXPIRED -> "MUTE ENDED"
        MuteRuleStatus.INVALID_PLACE -> "MUTE SET · PLACE UNAVAILABLE"
        null -> "MUTE SET · ${mutedScope.uppercase()}"
    }
    val statusText = when (muteStatus) {
        MuteRuleStatus.CURRENT_LOCATION_REQUIRED ->
            "This place mute is saved but inactive because a fresh location accurate to " +
                "50 meters is unavailable."
        MuteRuleStatus.OUTSIDE_RADIUS ->
            "This place mute is configured but inactive outside its saved radius."
        MuteRuleStatus.EXPIRED -> "This timed mute is no longer active."
        MuteRuleStatus.INVALID_PLACE ->
            "This saved place rule is incomplete and is not muting the device."
        else -> null
    }
    val headlineColor = if (active) MaterialTheme.colorScheme.primary else Acab.warn
    Column(Modifier.fillMaxWidth()) {
        // One TalkBack node for the headline and its sentence, as iOS combines them.
        Row(
            Modifier.fillMaxWidth().padding(top = 8.dp).semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                tint = headlineColor, modifier = Modifier.size(24.dp))
            Column(Modifier.weight(1f)) {
                Text(headline, style = MaterialTheme.typography.bodyLarge, color = headlineColor)
                statusText?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        TextButton(onClick = onOptions) { Text("Change") }
    }
}

@Composable
private fun ScopedMuteDialog(
    locationAvailable: Boolean,
    locationPermissionGranted: Boolean,
    locationCanRefresh: Boolean,
    addressRotates: Boolean,
    error: String?,
    onRequestLocation: () -> Unit,
    onDismiss: () -> Unit,
    onChoose: (MuteScope) -> Unit,
) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Mute this device") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "Existing log history is kept. Permanent mutes silence the app and beacon. Timed and place mutes are enforced by this phone, so the beacon can still sound.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (addressRotates) {
                    Text(
                        "This device uses a rotating address, so the mute may stop matching after the address changes.",
                        style = MaterialTheme.typography.bodyMedium, color = Acab.warn,
                    )
                }
                error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = Acab.warn) }
                listOf(
                    "Permanently" to MuteScope.PERMANENT,
                    "For 1 Hour" to MuteScope.ONE_HOUR,
                    "For 24 Hours" to MuteScope.ONE_DAY,
                )
                    .forEach { (label, scope) ->
                        Text(label, style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                                .clickable(role = Role.Button) { onChoose(scope) }.padding(vertical = 12.dp))
                    }
                when {
                    locationAvailable -> Text(
                        "At This Place (50 m)", style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                            .clickable(role = Role.Button) { onChoose(MuteScope.HERE) }
                            .padding(vertical = 12.dp),
                    )
                    !locationPermissionGranted -> Text(
                        // primary is the text-safe crimson on this scheme (8.15:1 on the dialog's
                        // surfaceContainerHigh).
                        "Enable Location for a Place Mute", style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                            .clickable(role = Role.Button, onClick = onRequestLocation)
                            .padding(vertical = 12.dp),
                    )
                    locationCanRefresh -> Text(
                        "Waiting for a fresh location accurate to 50 m. Keep this screen open, " +
                            "then try again.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    )
                    else -> Text(
                        "Connect to your beacon to get a fresh location accurate to 50 m for a " +
                            "place mute.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Star toggle: add/remove this exact MAC from the watchlist. */
@Composable
private fun WatchButton(watched: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    // A filled tonal button in both states; the gold stays on the star glyph (filled when
    // watched), never as a fill under text. The labels are "Watch" / "Stop Watching": the action
    // verb, not a state word. TalkBack reads it as drawn (no contentDescription override), so the
    // sighted label and the spoken one say the same thing. TWIN: iOS DetectionDetailView
    // `watchButton` (and the CONFIRM IT star row's button), same pair, byte for byte, which
    // VoiceOver also reads as drawn; iOS adds the selected trait while watched, this button
    // carries no state (the verb itself changes).
    FilledTonalButton(onClick = onToggle, modifier = modifier) {
        Icon(if (watched) Icons.Filled.Star else Icons.Filled.StarBorder, contentDescription = null,
            tint = Acab.watchTone, modifier = Modifier.size(ButtonDefaults.IconSize))
        Spacer(Modifier.size(ButtonDefaults.IconSpacing))
        Text(if (watched) "Stop Watching" else "Watch")
    }
}

/** Honest heads-up before starring a randomized address: it rotates, so the star may lapse.
 *  Exactly one body, chosen by type: a separated Find My tag holds its address for about a day
 *  and rolls near 4am, a phone churns every few minutes, everything else gets the generic line.
 *  Detection never uses the address, so rotation only costs you the star, never the hit. */
@Composable
private fun RandomAddrWarnDialog(type: DeviceType, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val body = when (type) {
        DeviceType.TRACKER -> "This tag's address holds for about a day, then changes around 4am. The watchlist entry stops matching when it does. The tracker detector finds it either way."
        DeviceType.NEARBY_DEVICE -> "Most phones change their address every few minutes, so the watchlist entry will likely stop matching within the hour."
        // No "trackers" here: TRACKER is handled one branch above, and a separated tag rotates
        // about once a day, not every few minutes. Repeating the near-owner interval in the
        // fallback would put the debunked claim straight back in front of the user.
        else -> "This address looks randomized, so the watchlist entry may stop matching this device."
    }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Watch a rotating address?") },
        text = { Text(body) },
        // Amber on the dialog container (surfaceContainerHigh): 7.55:1.
        confirmButton = { TextButton(onClick = onConfirm) { Text("Watch Anyway", color = Acab.warn) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The firmware watchlist holds 256 MACs. Mirrors AcabBleManager.WATCH_CAP (private there);
 *  checked here so a refused star gets the alert below instead of a silent no-op. */
private const val WATCH_CAP = 256

/** iOS's "Watchlist full" alert: the manager refuses a 257th star without a word, so the
 *  screen has to say why the Watch tap did nothing. */
@Composable
private fun WatchlistFullDialog(onDismiss: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Watchlist full") },
        text = { Text("You can watch up to 256 devices at once. Stop watching one before adding another.") },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}

/** Each stat pair as one title + trailing value row (GroupedValueRow) in one card ([DossierCard]);
 *  a row stacks title over value rather than clip. The dossier passes one pair, SIGHTINGS (iOS
 *  statGrid's one row, its own inset-grouped section). */
@Composable
private fun StatGrid(cells: List<Pair<String, String>>) {
    DossierCard {
        cells.forEach { (title, value) -> GroupedValueRow(title, value) }
    }
}

/** The dossier's section card: [GroupedCard] (surfaceContainer, the M3 medium shape) under the
 *  screen's 16dp gutter, holding a section's rows while its kicker and footers stay bare on the
 *  surface. Every grouped section of this screen draws through it (MATCH QUALITY, CONFIRM IT,
 *  SIGNAL, SIGHTINGS, LOCATION, Related help, Technical details), so the card look is one
 *  decision; the hero, Watch / Mute and Copy MAC Address stay bare, as on iOS. No icon tiles and
 *  no per-card footers (the Showcase look R13 rejected). TWIN: iOS DetectionDetailView's
 *  `.listStyle(.insetGrouped)` sections with `.listRowBackground(ACABTheme.bg2)`. */
@Composable
private fun DossierCard(content: @Composable ColumnScope.() -> Unit) =
    GroupedCard(Modifier.padding(horizontal = 16.dp), content = content)

/** RSSI history with quiet direction labels; dimmed when the node is stale. */
@Composable
private fun SignalHistoryGraph(
    values: List<Int>,
    currentRssi: Int,
    tone: Color,
    stale: Boolean,
    modifier: Modifier = Modifier,
) {
    val alpha = if (stale) 0.35f else 1f
    val strongest = values.maxOrNull()
    val weakest = values.minOrNull()
    val historyDescription = when {
        strongest == null || weakest == null ->
            "Signal history. Strong is at the top and weak is at the bottom. Current signal $currentRssi dBm."
        values.size < 2 ->
            "Signal history. Strong is at the top and weak is at the bottom. Current signal $currentRssi dBm. More readings are needed to draw a trend."
        else ->
            "Signal history. Strong is at the top and weak is at the bottom. Strongest $strongest dBm, weakest $weakest dBm, current $currentRssi dBm."
    }
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant.let { it.copy(alpha = it.alpha * alpha) }

    Row(
        modifier.clearAndSetSemantics { contentDescription = historyDescription },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // These stay at the chart's top and bottom, so the vertical direction is obvious without
        // replacing the exact dBm reading above. Pinning their size preserves the slim plot at
        // large font scales; TalkBack receives the full numeric summary on the row.
        Column(
            Modifier.fillMaxHeight(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Kicker("STRONG", color = labelColor, pinned = true, style = MaterialTheme.typography.labelMedium)
            Kicker("WEAK", color = labelColor, pinned = true, style = MaterialTheme.typography.labelMedium)
        }
        Canvas(Modifier.weight(1f).fillMaxHeight()) {
            drawSparkline(values, tone, alpha)
        }
    }
}

/** The signal graph's fixed dBm scale, shared with iOS (signalGraphFloorDbm /
 *  signalGraphCeilingDbm in Components.swift). -30 is the ceiling the sample history already
 *  clamps to and -100 sits under its -99 floor; on this range the band edges -90 / -80 / -67 sit
 *  at 14 % / 29 % / 47 % of the plot, so the weak, good and strong bands each get visible height.
 *  A reading above -30 pins to the top edge, one below -100 to the bottom. */
internal const val SIGNAL_GRAPH_FLOOR_DBM = -100
internal const val SIGNAL_GRAPH_CEILING_DBM = -30

/** Where [rssi] sits on the fixed scale, 0 (WEAK, bottom) to 1 (STRONG, top), clamped. Fixed, not
 *  the series' own min...max: a two-reading [-88, -86] series used to fill the plot top to bottom
 *  and read as a strong swing. TWIN: iOS signalGraphFraction(rssi:). */
internal fun signalGraphFraction(rssi: Int): Float =
    (rssi.coerceIn(SIGNAL_GRAPH_FLOOR_DBM, SIGNAL_GRAPH_CEILING_DBM) - SIGNAL_GRAPH_FLOOR_DBM).toFloat() /
        (SIGNAL_GRAPH_CEILING_DBM - SIGNAL_GRAPH_FLOOR_DBM)

private fun DrawScope.drawSparkline(values: List<Int>, tone: Color, alpha: Float) {
    // Fewer than two readings draw no line, as on iOS: on a fixed scale a lone mark would read
    // as a trend.
    if (values.size < 2) return
    val w = size.width
    val h = size.height
    val step = w / (values.size - 1)
    // Fixed dBm scale: STRONG (the ceiling) at the top, WEAK (the floor) at the bottom.
    fun y(v: Int) = h - signalGraphFraction(v) * h
    val line = Path().apply {
        moveTo(0f, y(values[0]))
        values.forEachIndexed { i, v -> lineTo(i * step, y(v)) }
    }
    val fill = Path().apply {
        addPath(line)
        lineTo(w, h)
        lineTo(0f, h)
        close()
    }
    drawPath(fill, tone.copy(alpha = 0.12f * alpha))
    drawPath(line, tone.copy(alpha = alpha), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()))
}

/** Last 4 hex of the MAC (colons stripped) for the NODE name. */
private fun nodeName(mac: String): String {
    val hex = mac.filter { it != ':' && it != '-' }
    return hex.takeLast(4).uppercase().ifEmpty { "????" }
}

/** The identity row that carries a derived time, named once so the qualifier line under it and
 *  the row itself can never drift apart. (APPROX_TIME and the rest of the time copy live in
 *  Components.kt now, shared with the log rows.) */
private const val FIRST_SEEN_LABEL = "First seen"

/** Short "ago" string like "now", "12s ago", "4m ago", "1h ago", "3d ago", or a dash if we don't
 *  know the time. Pure in ([ms], [nowMs]): the body reads no clock. Every dossier call passes the
 *  screen's 1 s tick as [nowMs], because a wall-clock reading taken inside a skipped child
 *  composable stays at its last composition (see the nowMs tick comment in this file). The
 *  wall-clock default has one user, MapScreen checkedAgo; the other callers outside the dossier
 *  (AcabLinkService lastLine, the widget's widgetLastLine) pass their own clock. TWIN: iOS
 *  `dossierRelativeAgo(_:now:)` in DetectionDetailView.swift, same buckets and edges. Pinned by
 *  DetailTimeLabelsTest and iOS DetectionDetailTimeTests; check-signature-drift.py's "dossier
 *  time labels" rule pins the same buckets in both bodies. */
internal fun relativeAgo(ms: Long?, nowMs: Long = System.currentTimeMillis()): String {
    if (ms == null) return "-"
    val secs = ((nowMs - ms) / 1000).coerceAtLeast(0)
    return when {
        secs < 5 -> "now"
        secs < 60 -> "${secs}s ago"
        secs < 3600 -> "${secs / 60}m ago"
        secs < 86_400 -> "${secs / 3600}h ago"
        else -> "${secs / 86_400}d ago"
    }
}

/** Bare duration since a timestamp, for "seen 4× over 18m so far": "45s", "18m", "2h", "3d".
 *  null when the first sighting time is unknown, so the caller can drop the clause. Pure in
 *  ([ms], [nowMs]) with no default, so a caller has to pass a clock reading on purpose;
 *  ConfirmItPanel passes the dossier's tick. TWIN: iOS `dossierSightingSpan(since:now:)` in
 *  DetectionDetailView.swift, same buckets and floor; it takes no optional, so there the view's
 *  `sightingSpan` makes the null call and feeds it the same `now` tick. Pinned by
 *  DetailTimeLabelsTest and iOS DetectionDetailTimeTests; check-signature-drift.py's "dossier
 *  time labels" rule pins the same buckets in both bodies. internal only so DetailTimeLabelsTest
 *  can pin it. */
internal fun seenSpan(ms: Long?, nowMs: Long): String? {
    if (ms == null) return null
    // Floor of 1, like iOS: a fresh detection reads "over 1s", never "over 0s".
    val secs = ((nowMs - ms) / 1000).coerceAtLeast(1)
    return when {
        secs < 60 -> "${secs}s"
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}

/** "32.76324, -117.15342": the on-screen coordinate pair. Pinned to Locale.US so the decimal
 *  separator is a dot on every phone; the default-locale format() printed "32,76324" on an
 *  es/pl/ro/sv device, which reads as a swapped pair and disagrees with the CSV export (see the
 *  Locale.US note on AcabBleManager.f6) and with iOS, whose String(format:) is locale-free. */
private fun coordText(lat: Double, lon: Double): String =
    String.format(java.util.Locale.US, "%.5f, %.5f", lat, lon)
