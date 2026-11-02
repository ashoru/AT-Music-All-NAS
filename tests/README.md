
# Audio tag writer regression (1.9.37 build 128)

```sh
swiftc -O ATMusic/AudioTagEmbedder.swift ATMusic/AudioTagContainerWriters.swift \
  tests/AudioTagWriterTests.swift -o /tmp/atmusic-tag-writer-tests
/tmp/atmusic-tag-writer-tests
```

Exercises the production writers against real audio: MP3 (ID3v2.3 + ID3v1), FLAC (Vorbis Comment + PICTURE), M4A (moov/udta/meta/ilst), WAV/AIFF (embedded ID3 chunk). Every case asserts the file still parses (`afinfo`), the fully decoded PCM is identical to the pre-write decode, the tag bytes are present, and a second consecutive write is idempotent. MP4 additionally asserts the `mdat` bitstream is byte-identical, that all `stco` chunk offsets shifted by exactly the moov growth, and that the first offset lands on the `mdat` payload start. Unsupported containers (APE/OGG) must be rejected without touching the file.

Requires macOS `afconvert` / `afinfo` and a system sample MP3; without a source it degrades to structural assertions.

# Lyric timeline baking regression (1.9.37 build 128)

```sh
swiftc -O ATMusic/LyricTimingBaker.swift tests/LyricTimingBakerTests.swift -o /tmp/atmusic-lyric-baker-tests
/tmp/atmusic-lyric-baker-tests
```

Covers the production `LyricTimingBaker`: advance/delay direction, multi-timestamp lines, `[offset:±ms]` folding and removal (no double offset after baking), sub-second digit preservation, clamping at 00:00.00, and pass-through when the offset is zero or the lyrics have no timeline.

# Scroll dock regression checks

Run from the source project directory (no signing, device or account needed):

```sh
swiftc ATMusic/ScrollDockState.swift tests/ScrollDockStateTests.swift -o /tmp/atmusic-scroll-state-tests
/tmp/atmusic-scroll-state-tests
```

This tests the production state machine, not a copy of its logic. Includes cumulative small gestures, direction hysteresis, 20 bottom bounce cycles, top bounce, page/source changes, programmatic movement, content/viewport resizing and invalid geometry.

These assertions do **not** prove SwiftUI layout stability, rendering performance or iOS 27 real-device behavior. Complete the manual matrix below before marking phase 1 done.

## Manual matrix (scroll fix 1.6.5.9 build 46; dock placement 1.6.5.10 build 47)

1. Confirm bundle `com.atmusic.player`。
2. Music library: long playlist collection, scroll to end, pull away/release and push back at least 20 times. No spontaneous jump; bottom dock collapse/expansion still works.
3. Playlist detail: repeat with a long `List` of songs; back navigation preserves expected position.
4. Profile: short and expanded donation-card layouts, repeat bottom/top elastic gestures. No state oscillation or sudden movement to mid-page.
5. Change between tabs at different offsets; no direction carried over from the previous tab. Search continues to show the last main tab shortcut (do not swap it to Home).
6. Repeat with a track playing/paused, player presented/dismissed, and while cover images finish loading.
7. Test both visual styles, then background/foreground and relaunch. Observe responsiveness and memory on the largest real playlist collection.
8. Record result, OS version and build. Simulator iOS 26.5 results cannot substitute for the user's iOS 27 device.

## Implementation notes

- iOS 18+: native scroll geometry + phase callbacks, scoped to the modified scroll view. No whole-window UIKit scan.
- Older OS: bounded, local-subtree UIKit fallback; no infinite retry loop, normalized top inset, detached observers invalidated.
- Non-published reducer state; only a changed dock state updates RootView.
- Offset elastic excursions and layout corrections do not act as navigation gestures.
- Fixed existing 136-point dock reservation retained. No programmatic `contentOffset` writes or forced `scrollTo` added.
- Library/Profile coarse section containers are eager `VStack`s to avoid lazily estimating a whole variable-height section. This intentionally does not redesign the rows or introduce new features. Very large libraries still need later row-level virtualization/profiling.

## Dock placement follow-up

The user confirmed build 46 no longer stutters, but reported the dock too high. Build 47 keeps the scroll reducer unchanged (SHA-256 compared with the build-46 source snapshot). It bottom-aligns contents in the existing 136pt reservation and applies a visual-only safe-area adjustment. Total reserved space remains 148pt for every state.

Reference: Apple iOS27 Music MiniPlayer illustration, https://support.apple.com/en-ng/guide/iphone/iph676daac9b/27/ios/27 . The 22pt screen-edge gap is an implementation target based on the illustration, not a published Apple metric. Both expanded and collapsed layouts share the bottom baseline. Keyboard-sized insets do not move the dock into the keyboard.

Automated assertions additionally cover 0/20/34pt safe areas, 50/52/64/122pt content heights, fixed reservation, invalid inset and keyboard inset. Visual position and touch targets still require device confirmation.
