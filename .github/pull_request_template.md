## What and why

<!-- What does this change, and why? Link the issue it fixes, e.g. "Fixes #12". -->

## How it was tested

<!-- Which tests you added or ran, and any manual checks (formats, subtitle types, sample files). -->

## Checklist

- [ ] Tests pass: `xcodebuild test -project video-converter.xcodeproj -scheme video-converter -destination 'platform=macOS' -skip-testing:video-converterUITests`
- [ ] `swiftlint lint --strict` passes
- [ ] New behaviour is covered by tests
- [ ] README updated if user-facing behaviour changed
