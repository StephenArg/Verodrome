# Verodrome

Verodrome is an iOS / iPadOS music client for Ampache and Subsonic servers.

## Features

- Ampache and Subsonic (including legacy auth) with auto-detect at login
- Local SwiftData library cache with background sync
- Streaming and offline playback via AudioStreaming
- Smart queue prefetch: keep previous 2 / current / next 5 tracks; prune stale and obsolete cache files
- Playlists, podcasts, radios, favorites, search, downloads
- CarPlay and App Intents
- Per-account theme colors and offline mode

## Requirements

- Xcode 16+
- iOS 17+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup

```bash
cd Verodrome
xcodegen generate
open Verodrome.xcodeproj
```

Select a development team in the Verodrome target signing settings, then build and run on a device or simulator.

## Architecture

| Target | Role |
|--------|------|
| `VerodromeKit` | Networking, SwiftData, player, downloads, sync |
| `Verodrome` | SwiftUI UI, CarPlay, App Intents |
| `VerodromeKitTests` | Unit tests for parsers, storage, queue, cache policy |

## License

Copyright © Verodrome. All rights reserved.
Choose your own license before App Store distribution.
