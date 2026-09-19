# Localization

ESP Remote supports English (`en`) and Ukrainian (`uk`). iOS exposes these
localizations under Settings → Apps → ESP Remote → Language, so the app language
can be tested without changing the device language.

Ukrainian is the Xcode development language because most existing source keys
are Ukrainian. English is maintained as a complete translation.

## Adding interface text

- In SwiftUI, use a string literal with APIs such as `Text`, `Label`, `Button`,
  `Section`, `Picker`, and accessibility modifiers. SwiftUI resolves those
  literals through `Localizable.strings` automatically.
- For UIKit, model/status strings, ternary expressions, and other values typed
  as `String`, use `localized(_:)`. Use `localizedFormat(_:_:)` for values with
  substitutions and positional format specifiers where translators may reorder
  arguments.
- The existing Ukrainian source text is the key for existing UI. Add the
  English value to `ESPRemoteControl/en.lproj/Localizable.strings`. English
  source keys need an explicit Ukrainian value in
  `ESPRemoteControl/uk.lproj/Localizable.strings`.
- The Share Extension has its own localization files under
  `ESPRemoteControlShare/{en,uk}.lproj` because it is a separate bundle.
- Privacy permission descriptions belong in each target's
  `InfoPlist.strings`, not in `Localizable.strings`.

Keep format placeholders (`%@`, `%d`, and positional variants) identical in
both languages. Run `bash ./scripts/test-localizations.sh` before merging; the iOS
build also verifies that both localization tables are present in the app and
Share Extension bundles. Finally, run the app once in each app-specific language
and exercise Bluetooth statuses, scanner errors, settings, accessibility labels,
and the Share Extension.
