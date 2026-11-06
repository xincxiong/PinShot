# Contributing to PinShot

Thanks for helping improve PinShot. This is a small native macOS app, so the
contribution flow is intentionally lightweight.

## Requirements

- macOS 14+
- Command Line Tools (`xcode-select --install`) — full Xcode is not required
- No third-party dependencies

## Build & test

```bash
make typecheck     # all Swift sources, fast feedback
make test          # pure-logic unit tests (20 cases)
make fast          # quick -Onone build
make build         # optimized build → build/PinShot.app
make run           # launch the app
make render-test   # offscreen render self-test (no screen recording permission)
make render-ui     # offscreen UI renders (settings/onboarding/annotation)
```

Please make sure `make typecheck` and `make test` pass before opening a PR.

## Code style

- Swift 5 language mode, AppKit only (no SwiftUI, no external packages).
- Keep UI code in `Sources/UI`, screenshot/annotation logic in `Sources/Core`.
- Use the design tokens in `Sources/UI/Theme.swift` and controls in
  `Sources/UI/Controls.swift` for new UI; do not hardcode colors/fonts.
- Comments and user-facing copy are in Chinese; code identifiers are English.
- Do not commit `build/` or generated `.app` bundles.

## Pull requests

- Keep PRs focused: one feature or fix per PR.
- Describe the user-visible behavior change and how you tested it.
- Screenshots/GIFs are very welcome for UI changes; you can generate them with
  `--render-ui` / `--render-test` without granting screen recording permission.

## Permissions note

Screen capture requires macOS Screen Recording permission (TCC). Local builds
are ad-hoc signed and use a stable identifier-based designated requirement, so
permission normally survives rebuilds. If a stale TCC entry shows the toggle as
ON while capture still fails, run:

```bash
./scripts/reset-screen-permission.sh
```

## License

By contributing, you agree that your contributions are licensed under the
MIT license (see [LICENSE](LICENSE)).
