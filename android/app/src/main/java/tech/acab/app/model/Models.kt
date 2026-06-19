package tech.acab.app.model

import org.json.JSONObject

/** The things ACAB looks for. Raw values match the firmware "t" field. */
enum class DeviceType(val raw: Int) {
    UNKNOWN(0), FLOCK_CAMERA(1), FLOCK_RAVEN(2), BODY_CAM(3), DRONE(4), TRACKER(5), POLICE_GEAR(6);

    val label: String
        get() = when (this) {
            FLOCK_CAMERA -> "ALPR Camera"
            FLOCK_RAVEN  -> "Flock Raven"
            BODY_CAM     -> "Body Camera"
            DRONE        -> "Drone"
            TRACKER      -> "Tracker"
            POLICE_GEAR  -> "Police Gear"
            UNKNOWN      -> "Unknown"
        }

    /** Coarse category; ALPR camera + Raven share one, like the iOS app. */
    val category: String
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN -> "ALPR"
            BODY_CAM -> "BODY CAM"
            DRONE    -> "DRONE"
            TRACKER  -> "TRACKER"
            POLICE_GEAR -> "POLICE"
            UNKNOWN  -> "UNKNOWN"
        }

    /** Short label for the detail badge, like the iOS app. */
    val classLabel: String
        get() = when (this) {
            FLOCK_CAMERA -> "PLATE READER"
            FLOCK_RAVEN  -> "AUDIO SENSOR"
            BODY_CAM     -> "BODY CAMERA"
            DRONE        -> "AERIAL · RID"
            TRACKER      -> "ITEM TRACKER"
            POLICE_GEAR  -> "MOTOROLA GEAR"
            UNKNOWN      -> "UNKNOWN"
        }

    /** Who makes the gear, shown when an ALPR class has a known brand. */
    val brand: String?
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN -> "Flock Safety"
            POLICE_GEAR -> "Motorola Solutions"
            else -> null
        }

    /** Body cam is the only experimental detector — signatures aren't field-verified. */
    val isExperimental: Boolean get() = this == BODY_CAM || this == POLICE_GEAR

    companion object {
        fun from(raw: Int): DeviceType = entries.firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

/** One detection from the Detections characteristic. */
data class Detection(
    val type: DeviceType,
    val source: Int,
    val method: Int,
    val confidence: Int,
    val mac: String,
    val rssi: Int,
    val name: String?,
    val rid: String?,
    val detail: String?,
    val lat: Double?,
    val lon: Double?,
    val pilotLat: Double?,
    val pilotLon: Double?,
    val altitude: Int?,
    val speedH: Int?,
    val speedV: Int?,
    val heading: Int?,
    val heightAGL: Int?,
    val pilotAlt: Int?,
    val ridStatus: Int?,
    val count: Int,
    val isNew: Boolean,
) {
    /** Stable identity. Drones key on UAS-ID (survives MAC rotation, same as the
     *  firmware's dedup key); everything else uses type + mac. */
    val id: String get() =
        if (type == DeviceType.DRONE && !rid.isNullOrEmpty()) "${type.raw}:$rid"
        else "${type.raw}:${mac.lowercase()}"

    /** Readable ODID operational status (drones). */
    val ridStatusLabel: String? get() = when (ridStatus) {
        1 -> "On ground"; 2 -> "Airborne"; 3 -> "Emergency"; 4 -> "System fault"; else -> null
    }

    /** Manufacturer from a CTA-2063-A Remote ID serial (4-char code + length digit +
     *  serial). Names the codes we know; otherwise just shows the code. */
    val ridManufacturer: String? get() {
        if (type != DeviceType.DRONE) return null
        val s = rid ?: return null
        if (s.length < 5) return null
        val code = s.substring(0, 4)
        val codeOk = code.all { it.isDigit() || (it in 'A'..'Z' && it != 'I' && it != 'O') }
        if (!codeOk || s[4] !in "123456789ABCDEF") return null
        val names = mapOf("1581" to "DJI", "1748" to "Autel", "1588" to "Parrot", "1668" to "Skydio", "1871" to "Aurora")
        return names[code] ?: "Mfr $code"
    }

    companion object {
        fun fromJson(o: JSONObject) = Detection(
            type = DeviceType.from(o.optInt("t", 0)),
            source = o.optInt("s", 0),
            method = o.optInt("meth", 0),
            confidence = o.optInt("c", 0),
            mac = o.optString("mac", ""),
            rssi = o.optInt("rssi", 0),
            name = o.stringOrNull("name"),
            rid = o.stringOrNull("id"),
            detail = o.stringOrNull("det"),
            lat = o.doubleOrNull("lat"),
            lon = o.doubleOrNull("lon"),
            pilotLat = o.doubleOrNull("plat"),
            pilotLon = o.doubleOrNull("plon"),
            altitude = if (o.has("alt")) o.optInt("alt") else null,
            speedH = if (o.has("spd")) o.optInt("spd") else null,
            speedV = if (o.has("vspd")) o.optInt("vspd") else null,
            heading = if (o.has("hdg")) o.optInt("hdg") else null,
            heightAGL = if (o.has("hgt")) o.optInt("hgt") else null,
            pilotAlt = if (o.has("palt")) o.optInt("palt") else null,
            ridStatus = if (o.has("sta")) o.optInt("sta") else null,
            count = o.optInt("n", 1),
            isNew = o.optBoolean("new", false),
        )
    }
}

/** Board status from the Status characteristic. */
data class DeviceStatus(
    val firmware: String,
    val uptime: Int,
    val total: Int,
    val ble: Boolean,
    val wifi: Boolean,
    val bodyCam: Boolean,
    val tracker: Boolean,
    val buzzer: Boolean,
    val volume: Int,
    val gps: Boolean,
) {
    /** Just the version, e.g. "0.2.3" from "ACAB-ouispy 0.2.3". */
    val version: String get() = firmware.substringAfterLast(' ', firmware)

    companion object {
        fun fromJson(o: JSONObject) = DeviceStatus(
            firmware = o.optString("fw", ""),
            uptime = o.optInt("up", 0),
            total = o.optInt("total", 0),
            ble = o.optBoolean("ble", false),
            wifi = o.optBoolean("wifi", false),
            // accept the new "bodycam" key, fall back to the legacy "axon" one
            bodyCam = o.optBoolean("bodycam", o.optBoolean("axon", false)),
            tracker = o.optBoolean("tracker", false),
            buzzer = o.optBoolean("buzzer", false),
            volume = o.optInt("vol", 80),
            gps = o.optBoolean("gps", false),
        )
    }
}

// org.json hands back "" instead of null for a missing string, so normalize it.
private fun JSONObject.stringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotEmpty() } else null

private fun JSONObject.doubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) optDouble(key).takeIf { !it.isNaN() } else null
