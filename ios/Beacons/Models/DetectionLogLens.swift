import Foundation

enum DetectionLogSort: String, CaseIterable {
    case newest, strongest

    var label: String { self == .newest ? "Newest" : "Strongest signal" }
}

/// Per-row folded haystack, kept ACROSS publishes. The store republishes ~3 Hz while detections
/// stream and hands the lens a new array each time, but a re-sighted row differs from its
/// predecessor in RSSI / count / lastSeen only: nothing the search reads moved. Without this,
/// every publish re-derived the nine identity fields and re-folded them for all 5,000 retained
/// rows, on the main thread, for as long as a query was typed.
///
/// An entry is reused while the row's identity text is unchanged: the six wire fields the nine
/// searched strings derive from (mac, name, uasID, detail, type, method) plus the
/// `DeviceNames.shared.revision` the customName rung reads through. Any of those moving refolds
/// that one row; a rename refolds all of them, once, on the next pass. Entries are pruned only
/// when the map has outgrown the feed by `pruneSlack`, so an unchanged feed never pays a walk.
/// TWIN: Android `LogSearchIndex` in LogScreen.kt - same key, same reuse rule, same prune.
final class DetectionLogSearchIndex {
    private struct Entry {
        let mac: String
        let name: String?
        let uasID: String?
        let detail: String?
        let type: DeviceType
        let method: DetectionMethod
        let namesRevision: Int
        let searchable: String
        /// Built on first demand only: an ordinary word query never consults it.
        var compactMac: String?
        var lastPass: Int
    }

    private var entries: [String: Entry] = [:]
    private var pass = 0
    private var touched = 0
    /// Folds performed since construction. Tests read it to prove that a publish which changed
    /// only RSSI reused the entry, and that a name change did not.
    private(set) var folds = 0
    /// Entries beyond the feed size tolerated before a prune walks the map.
    static let pruneSlack = 512

    /// Bracket one lens pass: `endPass` prunes entries no row touched, but only once the map has
    /// outgrown the feed, and never after a pass that consulted nothing (an empty query).
    func beginPass() {
        pass &+= 1
        touched = 0
    }

    func endPass(feedCount: Int) {
        guard touched > 0, entries.count > feedCount + Self.pruneSlack else { return }
        let current = pass
        entries = entries.filter { $0.value.lastPass == current }
    }

    func searchable(for detection: Detection) -> String {
        entry(for: detection).searchable
    }

    func compactMac(for detection: Detection) -> String {
        let id = detection.id
        _ = entry(for: detection)
        if let compact = entries[id]?.compactMac { return compact }
        let compact = detection.loweredMac.filter { $0 != ":" && $0 != "-" }
        entries[id]?.compactMac = compact
        return compact
    }

    private func entry(for detection: Detection) -> Entry {
        let id = detection.id
        let revision = DeviceNames.shared.revision
        touched += 1
        if var cached = entries[id], cached.namesRevision == revision,
           cached.mac == detection.mac, cached.name == detection.name,
           cached.uasID == detection.uasID, cached.detail == detection.detail,
           cached.type == detection.type, cached.method == detection.method {
            if cached.lastPass != pass {
                cached.lastPass = pass
                entries[id] = cached
            }
            return cached
        }
        folds += 1
        let built = Entry(mac: detection.mac, name: detection.name, uasID: detection.uasID,
                          detail: detection.detail, type: detection.type,
                          method: detection.method, namesRevision: revision,
                          searchable: DetectionLogQuery.foldedHaystack(for: detection),
                          compactMac: nil, lastPass: pass)
        entries[id] = built
        return built
    }
}

/// Prepared once per query, shared by the on-screen list and its evidence export. Search stays
/// entirely on-device. Words are ANDed; a MAC can be pasted with or without ':' / '-' separators.
struct DetectionLogQuery {
    private let tokens: [(text: String, address: String?)]
    /// True when at least one token could be part of an address. Stripping the separators out
    /// of a row's MAC costs an allocation per row, so a query with no hex-shaped word in it must
    /// not pay for a form it can never consult.
    private let hasAddressToken: Bool
    var isEmpty: Bool { tokens.isEmpty }

    init(_ text: String) {
        // Tokens split on the Unicode White_Space set (`Character.isWhitespace`), so a no-break
        // space pasted from a note separates two words exactly as a plain space does. Android's
        // `isLogTokenSeparator` spells out the same set; one tokenizer, one match set.
        let parsed = Self.fold(text).split(whereSeparator: \.isWhitespace)
            .map { word -> (text: String, address: String?) in
                let text = String(word)
                let address = text.filter { $0 != ":" && $0 != "-" }
                let isAddress = address.count >= 2 && address.utf8.allSatisfy {
                    (48...57).contains($0) || (97...102).contains($0)
                }
                return (text, isAddress ? address : nil)
            }
        tokens = parsed
        hasAddressToken = parsed.contains { $0.address != nil }
    }

    /// Called for every retained row of a capped store on every pass, so the folded haystack
    /// comes from `index`, which keeps it across publishes; only a row whose identity text moved
    /// is derived and folded again (see `DetectionLogSearchIndex`). Treat it as a hot path:
    /// nothing here may grow to a per-row allocation on the reuse path.
    func matches(_ detection: Detection, index: DetectionLogSearchIndex) -> Bool {
        guard !isEmpty else { return true } // no name/vendor lookup on the ordinary live path
        let searchable = index.searchable(for: detection)
        // Not consulted when no token is address-shaped: every token.address is nil there, so
        // the second half of the test below is false whatever this holds.
        let address = hasAddressToken ? index.compactMac(for: detection) : ""
        return tokens.allSatisfy { token in
            searchable.contains(token.text) || token.address.map { address.contains($0) } == true
        }
    }

    /// The one place the Log derives a row's whole identity instead of reading stored fields.
    static func foldedHaystack(for detection: Detection) -> String {
        // THE SAME FIELD SET Android searches, in the same order: LogSearchIndex.foldRow in
        // LogScreen.kt. One lens, one owner - it decides both what the list shows and what the
        // CSV/GPX export carries, so a field on one platform only means the same query returns
        // different evidence on the two phones.
        //
        // `displayName` is deliberately NOT one of these fields, and leaving it out searches
        // exactly the same text. It returns customName, name, uasID, maker or type.label and
        // nothing else, and the last four are already listed in their own right - so naming
        // customName directly covers the one case they miss, while dropping the SECOND `maker`
        // derivation displayName forces on every row that has no name of its own. Tokens are
        // split on whitespace and the fields are joined by a space, so no token can straddle
        // two fields: removing a field that only repeated another cannot change what matches.
        //
        // `nodeName` is absent for a different reason: the visible "NODE 1A2B" chip is the row's
        // last four address characters, which the compact-address path already answers, so the
        // field could never match anything the MAC did not. Do not "fix" a `node 1a2b` query by
        // joining the word into the haystack - a constant present on every row makes a bare
        // `node` query match the whole feed while the lens chip claims a search is narrowing it.
        let fields = [detection.customName, detection.name, detection.maker,
                      detection.ouiVendor, detection.vendor, detection.mac,
                      detection.uasID, detection.type.label,
                      detection.type.category].compactMap { $0 }
        return fold(fields.joined(separator: " "))
    }

    /// ONE fold on both platforms: NFD, drop every combining mark (Mn / Mc / Me), then the SIMPLE
    /// per-scalar lowercase mapping. "Café" -> "cafe", "Straße" stays "straße" (no ß -> ss
    /// expansion, no ligature expansion: NFD is not NFKD), "İ" -> "i" because NFD splits its dot
    /// off first. `lowercaseMapping` is the full mapping, which after NFD + mark stripping equals
    /// the simple one for every scalar (U+0130 was the only unconditional exception and it no
    /// longer survives), and it is applied per scalar, so no Final_Sigma or locale context can
    /// creep in. TWIN: Android `normalizedLogSearch` in LogScreen.kt - same three steps, same
    /// answers; DetectionLogLensTests and LogExportLensTest pin "Café", "Straße" and U+00A0.
    static func fold(_ value: String) -> String {
        // ASCII fast path. Lowercasing maps only A-Z within ASCII and there are no combining
        // marks to strip there, so for a pure-ASCII value the transform below yields exactly
        // `value.lowercased()`. MACs, OUI vendors, type labels and category keys are all ASCII
        // and are most of what a row contributes; the full transform still runs for anything a
        // device (or the user) actually spelled with accents.
        if value.utf8.allSatisfy({ $0 < 0x80 }) { return value.lowercased() }
        var folded = String.UnicodeScalarView()
        for scalar in value.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                folded.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(folded)
    }
}

/// Input is newest-first, including the frozen order of a paused Log. Strongest RSSI retains
/// that order for ties; it never manufactures a timestamp for undated/offline rows.
/// `index` is the caller's cross-publish haystack cache (DetectionsView keeps one in its
/// LogLensMemo); a one-shot caller such as the export may let the default build a throwaway.
func applyDetectionLogLens(_ rows: [Detection], category: String?, unseenOnly: Bool,
                           offlineOnly: Bool, query: DetectionLogQuery, sort: DetectionLogSort,
                           isUnseen: (Detection) -> Bool,
                           isWatched: (Detection) -> Bool,
                           index: DetectionLogSearchIndex = DetectionLogSearchIndex()) -> [Detection] {
    index.beginPass()
    let matched = rows.filter { d in
        detectionMatchesCategory(type: d.type, category: category, isCurrentlyWatched: isWatched(d))
            && (!unseenOnly || isUnseen(d))
            && (!offlineOnly || d.offline)
            && query.matches(d, index: index)
    }
    index.endPass(feedCount: rows.count)
    guard sort == .strongest else { return matched }
    return matched.enumerated().sorted { lhs, rhs in
        lhs.element.rssi == rhs.element.rssi
            ? lhs.offset < rhs.offset
            : lhs.element.rssi > rhs.element.rssi
    }.map(\.element)
}

extension BLEManager.DetectionExportSnapshot {
    /// Apply the same lens to a single immutable snapshot, retaining timestamps, coordinates,
    /// and NEW membership even after the manager has evicted a row in a paused view.
    func reviewed(category: String?, unseenOnly: Bool, offlineOnly: Bool,
                  query: DetectionLogQuery, sort: DetectionLogSort,
                  isWatched: (Detection) -> Bool) -> BLEManager.DetectionExportSnapshot {
        let selected = applyDetectionLogLens(detections, category: category,
            unseenOnly: unseenOnly, offlineOnly: offlineOnly, query: query, sort: sort,
            isUnseen: { unseenIDs.contains($0.id) }, isWatched: isWatched)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.d.id, $0) })
        let selectedIDs = Set(selected.map(\.id))
        return BLEManager.DetectionExportSnapshot(rows: selected.compactMap { byID[$0.id] },
            unseenIDs: unseenIDs.intersection(selectedIDs))
    }
}
