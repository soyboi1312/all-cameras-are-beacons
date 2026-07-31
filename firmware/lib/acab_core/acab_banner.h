#ifndef ACAB_BANNER_H
#define ACAB_BANNER_H

// Boot-time serial easter egg: the tofu robot standing on two legs, one arm on the hip and the
// other raised in a sparkle-wave, with "watch back." over its head. A raw string literal (custom
// BEACON delimiter) so the slashes, the backslash sparkles, the [////////] visor, and the \o/ wave
// all print literally, no escaping. An isometric cube head, a one-sided smirk (.__/ , only the
// right corner turns up). Printed once on setup(), ahead of the version line.
inline const char* acabBanner() {
    return R"BEACON(
         watch back. 
      _________________.   _
     /                /|  (_)
    /________________/ |   |
    | .            . | |  /
  __|  [//| - |//|   | |_/
 |  |                | |
 |  |    _______/    | |
 '--| .              | /
    |________________|/
         ||    ||
         ||    ||
      
      soyboi forever
)BEACON";
}

#endif // ACAB_BANNER_H
