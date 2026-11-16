# Contributing to Video Converter

Thanks for helping out. Bug reports, feature ideas and pull requests are all welcome.

## Reporting bugs and requesting features

Use the [issue templates](https://github.com/chavdar12/macos-video-converter/issues/new/choose). For a bug, include
your macOS version, the app version (**Video Converter → About**), and if you can, a short sample file that shows
the problem.

Security problems go through [private vulnerability reporting](https://github.com/chavdar12/macos-video-converter/security/advisories/new),
not a public issue. See the [security policy](https://github.com/chavdar12/macos-video-converter/security/policy).

## Development setup

You need macOS 14 or later and Xcode 27. Open `video-converter.xcodeproj` and run the `video-converter` scheme;
Xcode fetches [FFmpegKit](https://github.com/kingslay/FFmpegKit) through Swift Package Manager.

## Before you open a pull request

1. Branch from `main` and keep the change focused on one thing.
2. Add or update tests in `video-converterTests` for any behaviour you change. Small media samples for tests go in
   `video-converterTests/Fixtures`.
3. Run the tests (the UI tests need a GUI session, so CI skips them):

   ```sh
   xcodebuild test -project video-converter.xcodeproj -scheme video-converter \
     -destination 'platform=macOS' -skip-testing:video-converterUITests
   ```

4. Run SwiftLint, which CI runs in strict mode:

   ```sh
   swiftlint lint --strict
   ```

5. Open the pull request against `main` and fill in the template. CI must pass before it can be merged.

## Licensing

Video Converter is licensed under the [GNU General Public License v3.0](LICENSE). By contributing, you agree that
your contribution is licensed under the same terms.

## Code of conduct

Everyone taking part in this project is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
