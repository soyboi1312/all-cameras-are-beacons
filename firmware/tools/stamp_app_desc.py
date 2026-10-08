"""PlatformIO post-build action: stamp ACAB identity into the ESP app descriptor.

Arduino's prebuilt ESP-IDF archive carries its framework build string in app_desc.version. The OTA
anti-rollback check needs the product version and revision label inside the signed binary instead.
release_tools.restamp_app_desc checks the incoming ROM checksum and appended SHA-256 digest,
rewrites both fields and repairs the two with the standard library, so this build step imports and
installs nothing else.
"""
from pathlib import Path
import re
import sys

Import("env")  # type: ignore[name-defined]  # supplied by PlatformIO/SCons


FW_ROOT = Path(env["PROJECT_DIR"])
sys.path.insert(0, str(FW_ROOT / "tools"))
from release_tools import restamp_app_desc  # noqa: E402


def build_define(name: str):
    parsed = env.ParseFlags(env.get("BUILD_FLAGS", ""))
    for define in parsed.get("CPPDEFINES", []):
        if not isinstance(define, (list, tuple)) or len(define) != 2 or define[0] != name:
            continue
        value = str(define[1]).strip()
        while len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        return value.replace(r'\"', '"')
    return None


def declared_version() -> str:
    value = build_define("ACAB_FW_VERSION")
    if value:
        match = re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value)
        if not match:
            raise RuntimeError(f"invalid ACAB_FW_VERSION {value!r}")
        return value
    header = (FW_ROOT / "lib/acab_core/acab_version.h").read_text(encoding="utf-8")
    match = re.search(r'#define\s+ACAB_FW_VERSION\s+"([0-9]+\.[0-9]+\.[0-9]+)"', header)
    if not match:
        raise RuntimeError("ACAB_FW_VERSION is not declared")
    return match.group(1)


def declared_label() -> str:
    value = build_define("ACAB_FW_LABEL")
    if value:
        return value
    pio_env = str(env.get("PIOENV", ""))
    if pio_env == "oui-spy":
        return "ACAB-ouispy"
    if pio_env == "mesh-detect":
        return "mesh-detect-ACAB"
    if pio_env == "mesh-detect-ch1":
        return "mesh-detect-ACAB-ch1"
    if pio_env.startswith("beacon-board"):
        return "beacon board"
    return pio_env or "ACAB firmware"


def stamp_app_desc(source, target, env):
    image_path = Path(str(target[0]))
    version, label = declared_version(), declared_label()
    image_path.write_bytes(restamp_app_desc(image_path.read_bytes(), version, label))
    print(f"Stamped esp_app_desc.version={version} project_name={label!r} in {image_path.name}")


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", stamp_app_desc)
