# The All Cameras Are Beacons web flasher

This is the little web page that lets anyone flash a board straight from their
browser, with nothing to install. It uses
[ESP Web Tools](https://esphome.github.io/esp-web-tools/), which talks to the
board over USB right from Chrome.

```
web/
├── index.html               # the flasher page
├── manifest-oui-spy.json     # tells the flasher about the OUI-Spy firmware
├── manifest-mesh-detect.json # ...and the Mesh-Detect firmware
├── build-flasher.sh          # rebuilds the flashable firmware files
└── firmware/
    ├── acab-oui-spy.bin       # one ready-to-flash image each
    └── acab-mesh-detect.bin
```

## Which browsers work

You'll need **Chrome, Edge, or Opera on a desktop or laptop.** Safari and Firefox
don't support the USB feature this relies on, and phones won't work either. The
page checks for you and shows a friendly warning if you're somewhere it can't run.

## Trying it on your own machine

You don't need to host anything to test it. Browsers allow this over `localhost`:

```bash
cd web
python3 -m http.server 8000
# then open http://localhost:8000 in Chrome and click Flash
```

## How it gets published

This repo publishes the flasher for you automatically. There's a GitHub Actions
workflow ([.github/workflows/pages.yml](../.github/workflows/pages.yml)) that
copies the `web/` folder up to GitHub Pages any time something in it changes, and
the live copy lands at https://soyboi1312.github.io/all-cameras-are-beacons/. If you fork
this, switch Pages on under **Settings → Pages → Source: GitHub Actions** and
yours will do the same.

## Rebuilding the firmware files

After you change the firmware, regenerate the flashable images:

```bash
./web/build-flasher.sh
```

That rebuilds both firmware versions and bundles each one into a single file the
flasher can install in one shot. Commit the updated files in `firmware/` and the
hosted page refreshes itself.
