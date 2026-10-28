# Contributing to Çentik

Thanks for helping make the notch better. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/YusufEmreYazici/Centik/issues/new/choose) with your macOS version, your Mac model (with or without a notch) and the steps that reproduce it. Logs help a lot:

```sh
log stream --level debug --predicate 'subsystem == "com.emre.centik"'
```

## Making a change

1. Fork the repo and create a branch from `main`.
2. Build and run with `./build.sh --install`, or `swift build` for a quick check.
3. Check the layout of every island state without screen-recording permission:
   ```sh
   swift build && .build/debug/Centik --snapshot /tmp/snap
   ```
4. If you changed something visible in the README GIFs, re-record them with `tools/make-demo-gifs.sh`.
5. Open a pull request that says what changed and why. Screenshots or a short recording are great for UI changes.

## Code style

- SwiftUI and AppKit, no third-party dependencies. Keep it that way unless there's a strong reason.
- Match the surrounding code: naming, comment density and structure.
- Keep the island light: no per-frame SwiftUI timelines for decoration (use Core Animation layers), and only sample system data while it's on screen.
- Anything that touches privacy (new permissions, network requests, stored data) needs a note in the PR and in the README's Privacy section.

## Translations

Çentik is available in Turkish and English. The keys in the code are the Turkish text, and each language has a folder in `Resources/`:

- `en.lproj/Localizable.strings`: one line per string, `"Turkish key" = "Translation";`
- `en.lproj/Localizable.stringsdict`: plural forms, such as "1 item" and "2 items"
- `en.lproj/InfoPlist.strings`: the permission prompts macOS shows

When you add or change text in the interface, run:

```sh
tools/check-localization.sh
```

It lists every string without a translation and every translation that's no longer used. CI runs it too.

**Adding a language:** copy `en.lproj` to `<code>.lproj` (for example `de.lproj`), translate the values, add the code to `CFBundleLocalizations` in `Resources/Info.plist`, add it to `AppLanguage` in `Sources/Centik/App/Localization.swift`, and open a pull request.
