package tech.acab.app.ui

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.materialIcon
import androidx.compose.material.icons.materialPath
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CameraOutdoor
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import tech.acab.app.model.BufferHealthNotice
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.CAT_GLYPH_FILL_ALPHA
import tech.acab.app.ui.theme.isInstrumentLabel
import tech.acab.app.ui.theme.telemetry
import tech.acab.app.ui.theme.tone
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** True when the user has zeroed the system animator duration scale (the OS-level "remove
 *  animations" accessibility setting). Looping ornaments (radar sweep, breathing dots) key off
 *  this so a motion-sensitive user's screen holds still. Observed LIVE (2026-09-26 review
 *  P3-13): the setting is not a configuration change, so nothing recreates the activity when it
 *  flips, and a read on composition alone held the old verdict until the ornament next
 *  recomposed (an earlier cache held it until process death). A ContentObserver on the setting's
 *  URI re-reads it on the main thread and flips the state, so a user who turns animations off
 *  while the app is open sees the sweep stop at once, as iOS reacts to Reduce Motion. One
 *  observer per ornament, registered for its composition lifetime; Settings.Global.getFloat is
 *  one cheap provider read, on composition and on each change, never per frame. */
@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    val read = { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    var reduce by remember(resolver) { mutableStateOf(read()) }
    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { reduce = read() }
        }
        resolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        // A flip between the first read and the registration would otherwise be missed.
        reduce = read()
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return reduce
}

/** Secondary line: secondary ink, wraps; draws the string AS WRITTEN (no case transform:
 *  uppercase literals stay uppercase, lowercase copy stays lowercase). The default look is
 *  bodyMedium in onSurfaceVariant, the secondary text of a grouped list; a GroupedRow supporting
 *  line uses it as is.
 *  Instrument layer (R16): an uppercase identifier ([isInstrumentLabel]: a section header, a
 *  telegram, TOTAL NEARBY) sets in JetBrains Mono ([telemetry]) at Medium with the spaced
 *  capitals; a sentence (a footer, a caption) stays Roboto with no tracking. [telemetryLine] = true
 *  forces the instrument face on a telemetry LINE that may hold lowercase (a Beacon row's state,
 *  the hero status line, a dossier value): the role's own weight and no tracking, whatever its
 *  case. TWIN: iOS Kicker (uppercase identifiers) and GroupedRow telemetrySubtitle / valueText
 *  (the forced lines) in Views/Components.swift.
 *  [pinned] divides size, line height and tracking by fontScale for an ornament beside a number
 *  that already scales (StatusScreen TOTAL NEARBY, DetailScreen STRONG / WEAK); those sites pass
 *  style = labelMedium. A style without a size (LocalTextStyle's guard) is never divided.
 *  Drift rule "kicker captions may always wrap": keep the first parameter on the fun line, never
 *  cap the line count or turn wrapping off, and close the block body with `}` at column 0. */
@Composable
fun Kicker(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, pinned: Boolean = false,
           style: TextStyle = MaterialTheme.typography.bodyMedium, telemetryLine: Boolean = false) {
    val fs = if (pinned) LocalDensity.current.fontScale else 1f
    val label = !telemetryLine && isInstrumentLabel(text)
    // Remembered on its inputs: Kicker runs on the ~3 Hz publish path, and the copy is a style
    // allocation. The text itself is not a key, only which of the three looks it takes.
    val drawn = remember(style, telemetryLine, label) {
        when {
            telemetryLine -> style.telemetry()
            label -> style.telemetry(weight = FontWeight.Medium, tracked = true)
            else -> style.copy(letterSpacing = 0.sp)
        }
    }
    Text(
        text,
        color = color,
        style = drawn,
        fontSize = if (pinned && drawn.fontSize.isSpecified) drawn.fontSize / fs else drawn.fontSize,
        lineHeight = if (pinned && drawn.lineHeight.isSpecified) drawn.lineHeight / fs else drawn.lineHeight,
        letterSpacing = if (pinned && drawn.letterSpacing.isSpecified) drawn.letterSpacing / fs else drawn.letterSpacing,
    )
}

/** Section header (M3 list subheader). Draws text AS WRITTEN and owns neither case: the
 *  uppercase identifier headers (DETECTION, ON THE BOARD, MATCH QUALITY, SIGNAL) and copy
 *  headers ("heard in the last 45 s", "earlier today", "older") alike. Renders Kicker, so the
 *  wrap rule covers it. [inset] = false inside a padded column or a GroupedCard. No forced
 *  width: in a Row pass Modifier.weight(1f); as a sticky header pass a fillMaxWidth + surface
 *  background so rows do not show through. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier,
                 color: Color = MaterialTheme.colorScheme.onSurfaceVariant, inset: Boolean = true) {
    Box(modifier
        .padding(start = if (inset) 16.dp else 0.dp, end = if (inset) 16.dp else 0.dp, top = 16.dp, bottom = 8.dp)
        .semantics(mergeDescendants = true) { heading() }) {
        Kicker(text, color = color, style = MaterialTheme.typography.titleSmall)
    }
}

/** List / section footer: the Log lens summary, the dossier match-quality explainer. */
@Composable
fun SectionFooter(text: String, modifier: Modifier = Modifier) =
    Text(text, modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp),
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

// ---- flat M3 list rows (grouped lists: rows sit directly on surface, groups split by
// SectionLabel, no dividers inside a group; a lane that needs a filled cell wraps rows in
// GroupedCard) ----

/** One M3 list row. Heights come from the ListItem minimums; a fixed height is never set.
 *  [supporting] is the value line (`supporting = { Kicker(value) }`), [overline] a provenance
 *  mark (OFFLINE / MUTED / RECON), [badge] sits after the headline text, [leading] takes a
 *  CatGlyph or an Icon. For a title with one trailing runtime string use [GroupedValueRow].
 *  The headline is always Roboto, never the uppercase-label rule: callers pass runtime device
 *  names here (the Map cluster sheet's titleName), and an all-caps name is a name, not a label. */
@Composable
fun GroupedRow(
    headline: String,
    modifier: Modifier = Modifier,
    supporting: (@Composable () -> Unit)? = null,
    overline: (@Composable () -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    badge: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    onClickLabel: String? = null,
) {
    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(headline, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyLarge)
                if (badge != null) {
                    Spacer(Modifier.width(8.dp))
                    badge()
                }
            }
        },
        modifier = if (onClick != null) {
            modifier.clickable(onClickLabel = onClickLabel, role = Role.Button, onClick = onClick)
        } else modifier,
        overlineContent = overline,
        supportingContent = supporting,
        leadingContent = leading,
        trailingContent = trailing,
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

/** Title + TRAILING value (the dossier's rows in DetailScreen, such as "matched on" and
 *  "confidence"; the Beacon rows moved to DeviceScreen's BeaconLinkRow, the state under the title). Falls back to title-over-value STACKING when both do not fit on one line
 *  ([valueRowStacks]); never clamps the line count or hugs a width, so a runtime value of any
 *  length stays whole. [onClick] = null draws no chevron and has no click role (a disabled
 *  row's value string names its state). Intrinsics are measured in layout, not composition.
 *  The value is data (a method, a confidence, a MAC, an age), so it is always the instrument face
 *  (Kicker telemetryLine = true); an uppercase-identifier title (SIGHTINGS) is too ([rowTitleStyle]).
 *  The value is drawn through [dossierValueForDisplay], so a wrapped value never starts a line
 *  with an orphan middle dot; the note is prose and is drawn as written.
 *  [note] is a sentence under the value (the first-seen row's time qualifier), in bodySmall on the
 *  system face: prose, not data, so it never takes the instrument face. It stays in the value's
 *  column, so it can never pair with another row's number.
 *  TWIN: iOS GroupedRow valueText / titleBlock in Views/Components.swift; [note] twins iOS
 *  DetectionDetailView dossierRowNote (SF footnote). */
@Composable
fun GroupedValueRow(title: String, value: String?, modifier: Modifier = Modifier,
                    leading: (@Composable () -> Unit)? = null, onClick: (() -> Unit)? = null,
                    onClickLabel: String? = null, chevron: Boolean = onClick != null,
                    note: String? = null) {
    val scheme = MaterialTheme.colorScheme
    val titleContent: @Composable () -> Unit = {
        Text(title, style = rowTitleStyle(title), color = scheme.onSurface)
    }
    val valueContent: @Composable () -> Unit = {
        if (value != null) {
            val drawn = dossierValueForDisplay(value)
            if (note == null) {
                Kicker(drawn, telemetryLine = true)
            } else {
                Column {
                    Kicker(drawn, telemetryLine = true)
                    Kicker(note, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
    Row(
        modifier
            .fillMaxWidth()
            .then(if (onClick != null) {
                Modifier.clickable(onClickLabel = onClickLabel, role = Role.Button, onClick = onClick)
            } else Modifier)
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            // The ListItem leading colour, so a bare Icon matches GroupedRow's.
            CompositionLocalProvider(LocalContentColor provides scheme.onSurfaceVariant) { leading() }
            Spacer(Modifier.width(16.dp))
        }
        Layout(
            contents = listOf(titleContent, valueContent),
            modifier = Modifier.weight(1f),
        ) { (titleMeasurables, valueMeasurables), constraints ->
            val titleM = titleMeasurables.first()
            val valueM = valueMeasurables.firstOrNull()
            val gap = 16.dp.roundToPx()
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            if (valueM == null) {
                val t = titleM.measure(loose)
                val w = if (constraints.hasBoundedWidth) constraints.maxWidth else t.width
                layout(w, t.height) { t.placeRelative(0, 0) }
            } else {
                val bounded = constraints.hasBoundedWidth
                val avail = constraints.maxWidth
                val titleW = titleM.maxIntrinsicWidth(Constraints.Infinity)
                val valueW = valueM.maxIntrinsicWidth(Constraints.Infinity)
                if (bounded && valueRowStacks(avail, titleW, valueW, gap)) {
                    val t = titleM.measure(loose)
                    val v = valueM.measure(loose)
                    layout(avail, t.height + v.height) {
                        t.placeRelative(0, 0)
                        v.placeRelative(0, t.height)
                    }
                } else {
                    val v = valueM.measure(loose.copy(maxWidth = if (bounded) valueW else Constraints.Infinity))
                    val t = titleM.measure(
                        loose.copy(maxWidth = if (bounded) avail - gap - v.width else Constraints.Infinity))
                    val w = if (bounded) avail else t.width + gap + v.width
                    val h = maxOf(t.height, v.height)
                    layout(w, h) {
                        t.placeRelative(0, (h - t.height) / 2)
                        v.placeRelative(w - v.width, (h - v.height) / 2)
                    }
                }
            }
        }
        if (chevron) {
            Spacer(Modifier.width(8.dp))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
                tint = scheme.onSurfaceVariant)
        }
    }
}

/** A dossier row value as drawn: through [keepingMiddleDotsAttached] (LogScreen.kt), the no-break
 *  space BEFORE each middle dot that the Log rows use, so at a large font scale "Strong match ·
 *  80%" wraps with the dot on its word's line and never starts a line with an orphan "· 80%".
 *  Applied where [GroupedValueRow] draws its value, not in the builders, so the strings the tests
 *  pin (dossierConfidenceLine) stay as written; the row's text differs from
 *  them only by that no-break space. Every GroupedValueRow caller is a dossier
 *  row (DetailScreen.kt). TWIN: iOS dossierValueForDisplay (DetectionDetailView.swift), which
 *  dossierRowValue draws through, the same substitution. */
internal fun dossierValueForDisplay(value: String): String = keepingMiddleDotsAttached(value)

/** A [GroupedValueRow] title's style: bodyLarge, or for an uppercase identifier
 *  ([isInstrumentLabel], the dossier's SIGHTINGS) the instrument face at Medium with the spaced
 *  capitals, as Kicker sets a label. Every GroupedValueRow title is a fixed label, never a runtime
 *  name, so the rule cannot catch an all-caps device name. Both styles are built once. */
@Composable
private fun rowTitleStyle(title: String): TextStyle =
    if (isInstrumentLabel(title)) RowTitleLabelStyle else MaterialTheme.typography.bodyLarge

private val RowTitleLabelStyle = AcabTypography.bodyLarge.telemetry(weight = FontWeight.Medium, tracked = true)

/** The fit rule of [GroupedValueRow]: stack the value under the title when title, gap and
 *  value together are wider than the row. Pure so GroupedValueRowLayoutTest can pin it. */
internal fun valueRowStacks(availablePx: Int, titlePx: Int, valuePx: Int, gapPx: Int): Boolean =
    titlePx + gapPx + valuePx > availablePx

/** A toggle row: the whole row toggles (Role.Switch), the Switch is display-only. Same contract
 *  as DeviceScreen's ToggleRow: disabled while [pending], with "Applying" as the spoken state and
 *  a small spinner beside the switch. No switch colours are set: the M3 defaults come from the
 *  scheme (track primary, thumb onPrimary, the check mark in onPrimaryContainer). [exp] draws the
 *  EXP tag after the title. The row never decides a toggle's polarity; callers pass it. */
@Composable
fun GroupedSwitchRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit,
                     modifier: Modifier = Modifier, supporting: String? = null,
                     enabled: Boolean = true, pending: Boolean = false, exp: Boolean = false) {
    GroupedRow(
        headline = title,
        modifier = modifier
            .toggleable(value = checked, enabled = enabled && !pending, role = Role.Switch,
                onValueChange = onCheckedChange)
            .semantics(mergeDescendants = true) { if (pending) stateDescription = "Applying" },
        supporting = if (supporting != null) { { Kicker(supporting) } } else null,
        badge = if (exp) { { ExpTag() } } else null,
        trailing = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (pending) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                }
                Switch(
                    checked = checked,
                    onCheckedChange = null,
                    enabled = enabled && !pending,
                    thumbContent = if (checked) {
                        { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(SwitchDefaults.IconSize)) }
                    } else null,
                )
            }
        },
    )
}

/** Divider for the rare list that separates rows inside a group. Default colour outlineVariant. */
@Composable
fun GroupedDivider(modifier: Modifier = Modifier) =
    HorizontalDivider(modifier.padding(horizontal = 16.dp, vertical = 8.dp))

/** A filled cell (surfaceContainer, the M3 medium 12dp shape) for rows that need one: the
 *  Status strongest and legend cells, the connect screen. */
@Composable
fun GroupedCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    Column(modifier.fillMaxWidth().clip(MaterialTheme.shapes.medium)
        .background(MaterialTheme.colorScheme.surfaceContainer), content = content)

/** Card look for the screens that still use it: a surfaceContainer fill ([strong] = the raised
 *  surfaceContainerHigh) with rounded corners and no border. Interior padding is the card token
 *  [Acab.padCard]. New code uses [GroupedCard] or a flat list. */
fun Modifier.panel(strong: Boolean = false): Modifier = this
    .background(if (strong) Acab.palette.surfaceContainerHigh else Acab.palette.surfaceContainer,
        RoundedCornerShape(Acab.radius))
    .padding(Acab.padCard)

/** The app's banner frame: a surfaceContainerHigh card (M3 medium shape) holding an optional
 *  20dp icon or spinner (either one drawn in [iconTint]), an optional title, the message, then
 *  the caller's actions. The actions trail the message while the message keeps a readable width
 *  beside them at a normal font scale. Otherwise they move to their own end-aligned line under
 *  the message ([bannerActionsStackAt]): always from font scale [BANNER_STACK_FONT_SCALE] in a
 *  window under [BANNER_WIDE_WINDOW_DP] wide, and at any scale whenever the actions plus the
 *  message's readable minimum would not fit, so a large font scale never squeezes the message
 *  into a sliver (at 2.0 the sample banner once wrapped one word per line beside Exit Sample
 *  Data on every tab). In a wide window (a phone in landscape, a tablet) only the fit decides
 *  ([bannerWindowIsWide], verify step 2026-09-26): the stacked sample banner took about 140dp of
 *  a 411dp landscape window at 2.0 with room to spare beside the message. Intrinsics are measured
 *  in layout, not composition; the font scale and the window width are read once here. TWIN: iOS
 *  RootView's pinned banners, which stack the button under the message at an accessibility text
 *  size; the wide-window rule is Android's own (the M3 medium window-width class). */
@Composable
internal fun AcabBanner(
    text: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    iconTint: Color = MaterialTheme.colorScheme.primary,
    title: String? = null,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    progress: Boolean = false,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val fontScale = LocalDensity.current.fontScale
    val wideWindow = bannerWindowIsWide(LocalConfiguration.current.screenWidthDp)
    val leadingContent: @Composable () -> Unit = {
        if (progress) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), color = iconTint, strokeWidth = 2.dp)
                Spacer(Modifier.width(16.dp))
            }
        } else if (icon != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(16.dp))
            }
        }
    }
    val messageContent: @Composable () -> Unit = {
        Column {
            if (title != null) {
                Text(title, style = MaterialTheme.typography.titleSmall, color = titleColor)
            }
            Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
        }
    }
    val actionsContent: @Composable () -> Unit = {
        Row(verticalAlignment = Alignment.CenterVertically, content = actions)
    }
    Surface(modifier, color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = MaterialTheme.shapes.medium) {
        Layout(
            contents = listOf(leadingContent, messageContent, actionsContent),
            modifier = Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 12.dp),
        ) { (leadMeasurables, messageMeasurables, actionMeasurables), constraints ->
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            val bounded = constraints.hasBoundedWidth
            val lead = leadMeasurables.firstOrNull()?.measure(loose)
            val leadW = lead?.width ?: 0
            val leadH = lead?.height ?: 0
            val messageM = messageMeasurables.first()
            val actionsM = actionMeasurables.first()
            val avail = if (bounded) (constraints.maxWidth - leadW).coerceAtLeast(0) else Constraints.Infinity
            // The message's readable minimum: its longest word, and never under the floor.
            val messageMin = maxOf(messageM.minIntrinsicWidth(Constraints.Infinity),
                BannerMessageMinWidth.roundToPx())
            val stacks = bounded && bannerActionsStackAt(
                fontScale = fontScale,
                availablePx = avail,
                actionsPx = actionsM.maxIntrinsicWidth(Constraints.Infinity),
                messageMinPx = messageMin,
                wideWindow = wideWindow,
            )
            if (stacks) {
                val w = constraints.maxWidth
                val msg = messageM.measure(loose.copy(maxWidth = avail))
                val act = actionsM.measure(loose.copy(maxWidth = w))
                val topH = maxOf(leadH, msg.height)
                val gap = 4.dp.roundToPx()
                val h = maxOf(topH + gap + act.height, constraints.minHeight)
                layout(w, h) {
                    lead?.placeRelative(0, (topH - leadH) / 2)
                    msg.placeRelative(leadW, (topH - msg.height) / 2)
                    act.placeRelative(w - act.width, topH + gap)
                }
            } else {
                val act = actionsM.measure(loose.copy(maxWidth = avail))
                val msg = messageM.measure(loose.copy(
                    maxWidth = if (bounded) (avail - act.width).coerceAtLeast(0) else Constraints.Infinity))
                val w = if (bounded) constraints.maxWidth else leadW + msg.width + act.width
                val h = maxOf(leadH, msg.height, act.height, constraints.minHeight)
                layout(w, h) {
                    lead?.placeRelative(0, (h - leadH) / 2)
                    msg.placeRelative(leadW, (h - msg.height) / 2)
                    act.placeRelative(w - act.width, (h - act.height) / 2)
                }
            }
        }
    }
}

/** Floor for [AcabBanner]'s message width beside the actions, so the message never narrows to
 *  a few characters a line even when each single word would still fit. */
private val BannerMessageMinWidth = 120.dp

/** The fit rule of [AcabBanner]: move the actions under the message when the actions plus the
 *  message's readable minimum are wider than the space beside the icon. A banner without actions
 *  never stacks. Pure so AcabBannerLayoutTest can pin it. */
internal fun bannerActionsStack(availablePx: Int, actionsPx: Int, messageMinPx: Int): Boolean =
    actionsPx > 0 && actionsPx + messageMinPx > availablePx

/** From this font scale every [AcabBanner] with actions stacks them under the message, whatever
 *  the width: the fit rule alone compares against a floor that does not grow with the font, so
 *  the row branch kept winning at 2.0. The same 1.3 threshold DeviceScreen's large-text bar and
 *  its System readiness card use. TWIN: iOS RootView, which stacks at an accessibility text size. */
internal const val BANNER_STACK_FONT_SCALE = 1.3f

/** From this window width, in dp, an [AcabBanner] keeps its actions beside the message at any
 *  font scale and lets the width fit alone decide: the M3 medium window-width class boundary,
 *  where a phone in landscape and every tablet have the room the scale rule was written for the
 *  lack of. On the Map (the one tab whose content is under the banner) the stacked sample banner
 *  at 2.0 in landscape took about a third of the window's height (verify step 2026-09-26). */
internal const val BANNER_WIDE_WINDOW_DP = 600

/** Whether a window [widthDp] wide is wide for [bannerActionsStackAt]. Pure so
 *  AcabBannerWideWindowTest can pin it. */
internal fun bannerWindowIsWide(widthDp: Int): Boolean = widthDp >= BANNER_WIDE_WINDOW_DP

/** The whole stack decision of [AcabBanner]: a banner without actions never stacks; with actions
 *  it stacks from [BANNER_STACK_FONT_SCALE] unless the window is wide ([wideWindow],
 *  bannerWindowIsWide), and otherwise whenever [bannerActionsStack] says the pieces do not fit.
 *  Pure so AcabBannerFontScaleTest and AcabBannerWideWindowTest can pin it. */
internal fun bannerActionsStackAt(
    fontScale: Float,
    availablePx: Int,
    actionsPx: Int,
    messageMinPx: Int,
    wideWindow: Boolean = false,
): Boolean =
    actionsPx > 0 && ((!wideWindow && fontScale >= BANNER_STACK_FONT_SCALE) ||
        bannerActionsStack(availablePx = availablePx, actionsPx = actionsPx, messageMinPx = messageMinPx))

/** Persistent board-side evidence warning, shared by the Log and the Offline Buffer control.
 *  These are deliberately not dismissible: the corresponding firmware flag stays authoritative
 *  until a successful physical buffer clear resets the firmware's latched health mask. */
@Composable
fun BufferHealthBanner(notice: BufferHealthNotice) {
    val tone = if (notice.critical) MaterialTheme.colorScheme.error else Acab.warn
    AcabBanner(
        notice.detail,
        modifier = Modifier.fillMaxWidth(),
        icon = Icons.Filled.WarningAmber,
        iconTint = tone,
        title = notice.title,
        titleColor = tone,
    )
}

/** Plain overline marks (C10): no fill, no border, no tracking. The instrument face (R16), as
 *  iOS ExpTag sets it. Built once, not per composition. */
private val TagStyle = AcabTypography.labelSmall.telemetry()

/** The one EXP tag for experimental detectors: amber text, matching on both platforms. */
@Composable
fun ExpTag(modifier: Modifier = Modifier) = Text("EXP", modifier, color = Acab.warn, style = TagStyle)

/** What a buffered row says instead of an age when the board recorded only the order of a
 *  sighting and nothing bounds it. Never fabricate the pseudo-stamp into "24 years ago". */
const val APPROX_TIME = "time unknown · offline buffer"

/** Within the last six days, a weekday or bare clock reading is unambiguous and much easier
 *  to read than a full date. Past that it isn't, so the date comes back. The same window as
 *  iOS TimeBasisCopy.isRecent, so both platforms flip format on the same record. */
private fun isRecentStamp(atMs: Long): Boolean {
    val age = System.currentTimeMillis() - atMs
    return age >= 0 && age < 6 * 86_400_000L
}

/** Clock for a reconstructed stamp, e.g. "~14:32:07", or "~Mar 4, 14:32:07" once it's older
 *  than the recency window. The tilde is the dense shorthand for "derived"; the qualifier
 *  line under the value spells it out. Format mirrors iOS TimeBasisCopy.value. Locale.US
 *  pins the month names and 24-hour clock the way iOS's en_US_POSIX formatter does. */
fun reconTimeText(atMs: Long): String =
    "~" + DateTimeFormatter.ofPattern(if (isRecentStamp(atMs)) "HH:mm:ss" else "MMM d, HH:mm:ss", Locale.US)
        .format(Instant.ofEpochMilli(atMs).atZone(ZoneId.systemDefault()))

/** Day + clock at minute resolution for a bracket endpoint, e.g. "Tue 14:00", falling back to
 *  "Mar 4, 14:00" past the recency window (a bare weekday stops being unambiguous). Minutes,
 *  not seconds: the endpoints are bounds, and printing them to the second would dress a bound
 *  up as a measurement. */
fun bracketTimeText(atMs: Long): String =
    DateTimeFormatter.ofPattern(if (isRecentStamp(atMs)) "EEE HH:mm" else "MMM d, HH:mm", Locale.US)
        .format(Instant.ofEpochMilli(atMs).atZone(ZoneId.systemDefault()))

/** "14:32": the capture-window endpoints in the contribution flow (review sentence, disclosure
 *  block, and the note that ships with the CSV). Fixed 24-hour on Locale.US like the two
 *  formatters above, because the note is evidence handed to a third party and the disclosure text
 *  is a byte-for-byte contract with iOS. Until 2026-09-02 this was SimpleDateFormat("h:mm a") on
 *  the default locale, a 12-hour clock whose AM/PM token changed with the phone language.
 *  iOS twin: TimeBasisCopy.clock in Models/TimeBasis.swift. */
fun clockTimeText(atMs: Long): String =
    DateTimeFormatter.ofPattern("HH:mm", Locale.US)
        .format(Instant.ofEpochMilli(atMs).atZone(ZoneId.systemDefault()))

/** The one-line time a row shows, with its qualification built in. [TimeBasis.Exact] returns
 *  null: a live stamp renders exactly as it always has, and this model adds nothing to it. */
fun TimeBasis.primaryText(): String? = when (this) {
    is TimeBasis.Exact -> null
    is TimeBasis.Reconstructed -> reconTimeText(atMs)
    is TimeBasis.Bracketed -> {
        val a = afterMs; val z = beforeMs
        when {
            a != null && z != null -> "between ${bracketTimeText(a)} and ${bracketTimeText(z)}"
            a != null -> "after ${bracketTimeText(a)}"
            else -> "before ${bracketTimeText(z!!)}"
        }
    }
    is TimeBasis.Unknown -> APPROX_TIME
}

/** The secondary line under [primaryText]: how the number was arrived at, in plain words.
 *  Null where the primary line already says everything there is to say. */
fun TimeBasis.qualifierText(): String? = when (this) {
    is TimeBasis.Exact -> null
    is TimeBasis.Reconstructed -> "reconstructed from device uptime, +/-${precisionSec}s"
    is TimeBasis.Bracketed -> "the beacon restarted, so this is bounded, not measured"
    // The primary line already says "time unknown", but not WHY; iOS spells it out and an
    // evidence reader deserves the reason on both platforms.
    is TimeBasis.Unknown -> "the beacon had no clock reference for this record"
}

/** Eyeglasses glyph for GLASSES, hand-authored on the 24-unit Material grid because Material
 *  Icons carries no eyeglasses: two lens rings (lens centres 6 and 18 at y 14.5, outer radius 4.2,
 *  hole 2.7) joined by a bridge above centre, with short temples rising outward from each lens.
 *  Non-zero fill: every solid part winds clockwise and each hole counter-clockwise, so the bridge
 *  and temples can overlap the rings without cancelling. Built once (a lazy top-level val), never
 *  per call: icon() runs per strip tile, Log row, map pin and dossier. The widget's checked-in
 *  vector (res/drawable/ic_w_glasses.xml) is NOT this shape; the widget follow-up owns that. */
private val EyeglassesIcon: ImageVector by lazy {
    materialIcon(name = "Filled.Eyeglasses") {
        materialPath {
            // left lens ring: outer clockwise, hole counter-clockwise
            moveTo(1.8f, 14.5f)
            arcTo(4.2f, 4.2f, 0f, false, true, 10.2f, 14.5f)
            arcTo(4.2f, 4.2f, 0f, false, true, 1.8f, 14.5f)
            close()
            moveTo(3.3f, 14.5f)
            arcTo(2.7f, 2.7f, 0f, false, false, 8.7f, 14.5f)
            arcTo(2.7f, 2.7f, 0f, false, false, 3.3f, 14.5f)
            close()
            // right lens ring
            moveTo(13.8f, 14.5f)
            arcTo(4.2f, 4.2f, 0f, false, true, 22.2f, 14.5f)
            arcTo(4.2f, 4.2f, 0f, false, true, 13.8f, 14.5f)
            close()
            moveTo(15.3f, 14.5f)
            arcTo(2.7f, 2.7f, 0f, false, false, 20.7f, 14.5f)
            arcTo(2.7f, 2.7f, 0f, false, false, 15.3f, 14.5f)
            close()
            // bridge, clockwise
            moveTo(9.5f, 12.3f)
            lineTo(14.5f, 12.3f)
            lineTo(14.5f, 13.5f)
            lineTo(9.5f, 13.5f)
            close()
            // temples, clockwise, rising outward from each lens's upper outer edge
            moveTo(3.17f, 12.52f)
            lineTo(1.16f, 8.5f)
            lineTo(2.01f, 7.65f)
            lineTo(4.02f, 11.67f)
            close()
            moveTo(19.98f, 11.67f)
            lineTo(21.99f, 7.65f)
            lineTo(22.84f, 8.5f)
            lineTo(20.83f, 12.52f)
            close()
        }
    }
}

/** The category glyph, one per type, shared by the Status strip tiles, Log rows, map pins and the
 *  dossier. BODY_CAM is the mockups' person-search glyph and GLASSES the eyeglasses above
 *  ([EyeglassesIcon]); both differ from the widget vectors on purpose (the widget follow-up owns
 *  those). Pinned in CategoryTilesPerRowTest. */
internal fun DeviceType.icon(): ImageVector = when (this) {
    DeviceType.FLOCK_CAMERA -> Icons.Filled.PhotoCamera
    DeviceType.FLOCK_RAVEN -> Icons.Filled.GraphicEq
    DeviceType.BODY_CAM -> Icons.Filled.PersonSearch
    DeviceType.DRONE -> Icons.Filled.Flight
    DeviceType.TRACKER -> Icons.Filled.Sensors
    DeviceType.GLASSES -> EyeglassesIcon
    DeviceType.NEARBY_DEVICE -> Icons.Filled.Radar
    DeviceType.WATCHED -> Icons.Filled.Star
    // wall-mounted surveillance-camera glyph, distinct from the flock PhotoCamera
    DeviceType.NETWORK_CAMERA -> Icons.Filled.CameraOutdoor
    DeviceType.UNKNOWN -> Icons.AutoMirrored.Filled.HelpOutline
}

/** Category glyph in a circle. [filled] (the default) draws the type's tone at
 *  [CAT_GLYPH_FILL_ALPHA] behind it, as the 4d / 4h mockups do; unfilled sits on the neutral
 *  surfaceContainerHigh (ambient and unclassified rows). No border. */
@Composable
fun CatGlyph(type: DeviceType, size: Int = 40, filled: Boolean = true) {
    val tone = type.tone()
    Box(
        modifier = Modifier
            .size(size.dp)
            .background(
                if (filled) tone.copy(alpha = CAT_GLYPH_FILL_ALPHA) else MaterialTheme.colorScheme.surfaceContainerHigh,
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        // Always decorative: every CatGlyph sits beside text that names the category/device.
        // Announcing both produced duplicate TalkBack nodes ("Drone, Drone").
        Icon(type.icon(), contentDescription = null, tint = tone,
            modifier = Modifier.size((size * 0.55f).dp))
    }
}

/** Four rising bars for signal strength (0..4). Lit bars take [tint] (onSurfaceVariant when
 *  unspecified), unlit bars outlineVariant; bar height is the second cue. */
@Composable
fun SignalBars(bars: Int, tint: Color = Color.Unspecified) {
    val lit = tint.takeOrElse { MaterialTheme.colorScheme.onSurfaceVariant }
    val unlit = MaterialTheme.colorScheme.outlineVariant
    Row(verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 4) {
            Box(
                Modifier
                    .padding(end = 2.dp)
                    .width(3.dp)
                    .height((5 + i * 3).dp)
                    .background(if (i < bars) lit else unlit, RoundedCornerShape(1.dp))
            )
        }
    }
}

/** RSSI to a 0..4 bar count. */
fun rssiBars(rssi: Int): Int = when {
    rssi < -90 -> 1
    rssi < -80 -> 2
    rssi < -67 -> 3
    else -> 4
}

internal enum class LinkChipTone { LINKED, ATTENTION, OFFLINE }
/** The pill's leading glyph. WARNING is the amber triangle of a real fault or transition
 *  (RECONNECTING, UPDATING, RADIO FAULT); DOT is the small filled amber circle of sample data, a
 *  state the user chose and not an alarm, the glyph iOS LinkChip draws for SAMPLE. */
internal enum class LinkChipMark { CHECK, WARNING, DOT, NONE }
internal data class LinkChipLook(val label: String, val tone: LinkChipTone, val mark: LinkChipMark)

/** Pure: which word and which look the status pill shows. Existing callers can keep inferring
 *  connection from [version]; surfaces that retain stale status during reconnect / update pass
 *  an authoritative [connected] and a compact [stateLabel] instead. Labels are drawn as written.
 *  TWIN: iOS `LinkChip` in Views/Components.swift - same labels and the same amber rule: SAMPLE (sample data;
 *  iOS LinkChip.sampleLabel) and the three attention states (`stateNeedsAttention`) never read as a healthy pill, so a radio
 *  fault never looks connected. Only the word CONNECTED wears the check mark (WAITING does not);
 *  SAMPLE wears the amber dot and only a fault or transition wears the warning triangle. */
internal fun linkChipAppearance(version: String?, demo: Boolean, connected: Boolean?, stateLabel: String?): LinkChipLook {
    val linked = connected ?: (version != null)
    val stateNeedsAttention = stateLabel == "RECONNECTING" || stateLabel == "UPDATING" ||
        stateLabel == "RADIO FAULT"
    val attention = demo || stateNeedsAttention
    val label = when {
        demo -> "SAMPLE"
        stateLabel != null -> stateLabel
        linked -> "CONNECTED"
        else -> "OFFLINE"
    }
    val tone = when {
        attention -> LinkChipTone.ATTENTION
        linked -> LinkChipTone.LINKED
        else -> LinkChipTone.OFFLINE
    }
    val mark = when {
        demo -> LinkChipMark.DOT
        tone == LinkChipTone.ATTENTION -> LinkChipMark.WARNING
        tone == LinkChipTone.LINKED && label == "CONNECTED" -> LinkChipMark.CHECK
        else -> LinkChipMark.NONE
    }
    return LinkChipLook(label, tone, mark)
}

/** Status pill (M3 assist-chip geometry: 32dp, small shape, labelLarge). Not clickable, so it
 *  takes no 48dp floor. LINKED = primaryContainer / onPrimaryContainer; ATTENTION = amber on
 *  surfaceContainerHigh with a warning mark (the triangle for a fault or transition, an 8dp
 *  filled dot for sample data, [LinkChipMark]); OFFLINE = onSurfaceVariant on
 *  surfaceContainerHigh. The look is [linkChipAppearance]. The word is an uppercase identifier,
 *  so it is set in the instrument face with the spaced capitals ([LinkChipLabelStyle]), as iOS
 *  LinkChip sets it. TWIN: iOS LinkChip's 8pt amber circle before SAMPLE. */
@Composable
fun LinkChip(
    version: String?,
    demo: Boolean = false,
    connected: Boolean? = null,
    stateLabel: String? = null,
) {
    val look = linkChipAppearance(version, demo, connected, stateLabel)
    val scheme = MaterialTheme.colorScheme
    val container = if (look.tone == LinkChipTone.LINKED) scheme.primaryContainer else scheme.surfaceContainerHigh
    val content = when (look.tone) {
        LinkChipTone.LINKED -> scheme.onPrimaryContainer
        LinkChipTone.ATTENTION -> Acab.warn
        LinkChipTone.OFFLINE -> scheme.onSurfaceVariant
    }
    Row(
        Modifier
            .heightIn(min = 32.dp)
            .background(container, MaterialTheme.shapes.small)
            .padding(start = if (look.mark != LinkChipMark.NONE) 8.dp else 16.dp, end = 16.dp, top = 6.dp, bottom = 6.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val mark = when (look.mark) {
            LinkChipMark.CHECK -> Icons.Filled.Check
            LinkChipMark.WARNING -> Icons.Filled.WarningAmber
            LinkChipMark.DOT, LinkChipMark.NONE -> null
        }
        if (mark != null) {
            Icon(mark, contentDescription = null, tint = content, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        } else if (look.mark == LinkChipMark.DOT) {
            // A status light, not a fault icon: sample mode is a state the user chose. Centred in
            // the same 18dp slot the icons take, so the word does not shift between the marks.
            // Decorative (the merged node speaks the word); the tint is the ATTENTION ink.
            Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(8.dp).background(content, CircleShape))
            }
            Spacer(Modifier.width(8.dp))
        }
        Text(look.label, style = LinkChipLabelStyle, color = content)
    }
}

/** The pill's word: labelLarge in the instrument face, tracked. Built once. */
private val LinkChipLabelStyle = AcabTypography.labelLarge.telemetry(tracked = true)

// ---- category tile strips (StatusScreen CountTile; LogScreen CategoryTile until C10 retires it) ----

/** The connect screen's "what the beacon hears" tile label (AcabApp BeaconHearsPanel), and the
 *  default [rememberCategoryTilesPerRow] measures: Roboto 12sp Medium (labelMedium), as the 4b
 *  mockup draws the strip labels, with no tracking. It stays Roboto, as iOS
 *  ConnectView.beaconHearsPanel keeps SF. A top-level val, so the measure key stays stable. */
internal val CategoryTileLabelStyle = AcabTypography.labelMedium.copy(letterSpacing = 0.sp)

/** The Status strip's tile label (StatusScreen CountTile): labelMedium in the instrument face
 *  (R16), JetBrains Mono Medium at 10.8sp with the 0.8sp spaced capitals, as iOS DashboardView
 *  sets its tile label. The strip passes it to [rememberCategoryTilesPerRow] and draws with it, so
 *  the fit test and the drawn label cannot disagree. */
internal val CategoryTileTelemetryLabelStyle = AcabTypography.labelMedium.telemetry(tracked = true)

/** Side padding of a category tile, measured against by [rememberCategoryTilesPerRow]. 0dp: the
 *  tiles have no chrome (C9), and the tile centres its content, as iOS does. */
internal val CategoryTileSidePadding = 0.dp

/** Top and bottom padding of a category tile. */
internal val CategoryTileEndPadding = 10.dp

/** Gap between tiles, and between wrapped rows: 4dp, as the 4b mockup draws the strip. */
internal val CategoryTileGap = 4.dp

/** How many tiles go on one row so every label stays on one line: [preferred] (all six on
 *  Status, or a strip's own choice) when the widest label fits a tile at that count, otherwise
 *  three, otherwise two. Two is the floor: a label wider than a half-row tile would still clip.
 *
 *  Widths with the 12sp Roboto label ([CategoryTileLabelStyle]), 4dp gaps and 0dp side padding
 *  (TTF-derived 2026-09-23 from the Roboto-Medium advances, kerning ignored; re-measure on
 *  beacon_play_36 at 1.0 / 1.15 / 1.3 / 2.0 and true these numbers and the test fixtures before
 *  commit): NETCAM is about 48.9 / 56.3 / 63.6 / 97.8dp at font scale 1.0 / 1.15 / 1.3 / 2.0. A
 *  411dp phone (a 379dp strip at the 16dp gutter) has a 59.8dp box six across, so it keeps six
 *  through 1.15 and wraps to three from 1.3; its three-across box (123.7dp) still holds NETCAM at
 *  2.0. A 360dp phone (328dp strip, 51.3dp box) keeps six at 1.0 and wraps to three from 1.15.
 *  The Status strip draws [CategoryTileTelemetryLabelStyle] instead: every JetBrains Mono glyph
 *  advances 0.6em (600 of 1000 units in jetbrains_mono_medium.ttf) plus the 0.8sp tracking, so
 *  NETCAM is 6 x (0.6 x 10.8 + 0.8) = 43.7dp at 1.0, and a linear estimate of 50.2 / 56.8 /
 *  87.4dp at 1.15 / 1.3 / 2.0 (Android 14 scales large text nonlinearly; re-measure on the AVD
 *  as above). The 411dp phone then keeps six through 1.3 and wraps to three at 2.0; the 360dp
 *  phone keeps six through 1.15 and wraps to three from 1.3.
 *
 *  This replaced a fixed rule (three per row below 360dp or at font scale 1.5 and up), which
 *  let the labels clip ("NETCA", "DRON") at Android's own 1.15 and 1.3 text sizes (seen on an
 *  emulator, 2026-09-20). Measuring the real label covers every width and scale.
 *
 *  TWIN: iOS Views/Components.swift `CategoryStripLayout`, the same rule measured on the whole
 *  tile. Each side derives its own numbers. */
internal fun categoryTilesPerRow(
    stripWidthPx: Float, gapPx: Float, tilePaddingPx: Float, widestLabelPx: Float, preferred: Int,
): Int {
    fun fits(n: Int) = widestLabelPx <= (stripWidthPx - gapPx * (n - 1)) / n - 2 * tilePaddingPx
    return listOf(preferred, 3, 2).filter { it <= preferred }.firstOrNull { it <= 2 || fits(it) }
        ?: preferred
}

/** [categoryTilesPerRow] for a strip of [stripWidth] holding tiles labelled [labels], drawn in
 *  [labelStyle] (pass the style the tiles draw with). The measurement reruns only when the labels,
 *  the style or the density (which carries the font scale) change, so the ~3 Hz Status
 *  recomposition pays a list comparison, not a text layout. */
@Composable
internal fun rememberCategoryTilesPerRow(labels: List<String>, stripWidth: Dp, preferred: Int,
                                         labelStyle: TextStyle = CategoryTileLabelStyle): Int {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = LocalTextStyle.current.merge(labelStyle)
    val widest = remember(labels, density, style) {
        labels.maxOfOrNull {
            measurer.measure(AnnotatedString(it), style = style, softWrap = false, maxLines = 1).size.width
        } ?: 0
    }
    // Gap and padding as the layout draws them: spacedBy and Modifier.padding round each to whole
    // px (4dp is 10.5px at 420dpi, drawn as 11), so the fractional toPx() would test a box a pixel
    // wider than the one the label gets.
    return with(density) {
        categoryTilesPerRow(stripWidth.toPx(), CategoryTileGap.roundToPx().toFloat(),
            CategoryTileSidePadding.roundToPx().toFloat(), widest.toFloat(), preferred)
    }
}

/** Light status- and navigation-bar icons for a ModalBottomSheet's own dialog window. Call it once
 *  inside the sheet's content. material3 1.3.1 sets that window's icon appearance from
 *  isSystemInDarkTheme() when it builds the dialog (the ModalBottomSheetDialogWrapper
 *  constructor), but this app is dark whatever the phone's setting (AcabPalette.toColorScheme
 *  builds on darkColorScheme). With the phone in light mode the sheet therefore drew dark grey
 *  clock and battery icons on the dark sheet and scrim, where every other screen has light ones
 *  (Theme.OuiAcab is a dark window theme). The write runs when the sheet's window is first seen,
 *  not on each recomposition of the sheet. */
@Composable
internal fun LightSheetSystemBarIcons() {
    val window = (LocalView.current.parent as? DialogWindowProvider)?.window
    DisposableEffect(window) {
        if (window != null) {
            WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = false
                isAppearanceLightNavigationBars = false
            }
        }
        onDispose { }
    }
}
