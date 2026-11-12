# Video Converter

A macOS app that converts videos with the bundled FFmpeg libraries and VideoToolbox hardware encoding.

- **Formats:** MP4, MOV and M4V (H.264, HEVC, ProRes 422), MKV (H.264), and M4A (audio only).
- **Subtitles:** you can burn them into the picture, keep them as a track (on by default), or remove them. This works for embedded text and bitmap (PGS, VobSub) subtitles, and for `.srt`, `.vtt`, `.ass` or `.ssa` files dropped next to a video with a matching name.
- Converts several files at once and never overwrites existing files.

## Requirements

- macOS 14 Sonoma or later
- Xcode 27 to build

## Building

Open `video-converter.xcodeproj` and run the `video-converter` scheme. Xcode fetches [FFmpegKit](https://github.com/kingslay/FFmpegKit) through Swift Package Manager.

Tests (CI skips the UI tests because they need a GUI session):

```sh
xcodebuild test -project video-converter.xcodeproj -scheme video-converter \
  -destination 'platform=macOS' -skip-testing:video-converterUITests
```

CI builds a DMG for every push to `main` and every `v*` tag.

## License

Video Converter is free software, licensed under the [GNU General Public License v3.0](LICENSE).

It links [FFmpegKit](https://github.com/kingslay/FFmpegKit), which is also GPL-3.0, so anyone who distributes the app (including the DMG) must make the matching source code available under the same terms.
