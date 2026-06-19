package tech.acab.app.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.ui.theme.Acab

private enum class Tab(val label: String, val icon: ImageVector) {
    STATUS("Status", Icons.Filled.Radar),
    MAP("Map", Icons.Filled.Map),
    LOG("Log", Icons.AutoMirrored.Outlined.ListAlt),
    DEVICE("Device", Icons.Filled.Memory),
}

/** Four-tab shell: bottom nav swaps the body between screens. */
@Composable
fun MainScreen(ble: AcabBleManager) {
    var tab by remember { mutableIntStateOf(0) }
    var selected by remember { mutableStateOf<Detection?>(null) }

    Scaffold(
        containerColor = Acab.bg,
        bottomBar = {
            NavigationBar(containerColor = Acab.bg2) {
                Tab.entries.forEachIndexed { i, t ->
                    NavigationBarItem(
                        selected = tab == i,
                        onClick = { tab = i },
                        icon = { Icon(t.icon, contentDescription = t.label) },
                        label = { Text(t.label) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Acab.accent,
                            selectedTextColor = Acab.accent,
                            indicatorColor = Acab.bg3,
                            unselectedIconColor = Acab.faint,
                            unselectedTextColor = Acab.faint,
                        ),
                    )
                }
            }
        },
    ) { inner ->
        Box(Modifier.fillMaxSize().padding(inner)) {
            when (Tab.entries[tab]) {
                Tab.STATUS -> StatusScreen(ble)
                Tab.MAP -> MapScreen(ble, onSelect = { selected = it })
                Tab.LOG -> LogScreen(ble, onSelect = { selected = it })
                Tab.DEVICE -> DeviceScreen(ble)
            }
        }
    }

    // dossier sits full-screen over the tabs; back clears it
    selected?.let { d ->
        DetailScreen(d, ble, onBack = { selected = null })
    }
}
