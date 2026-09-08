# ESP Remote development workflow

## iOS releases for device testing

The maintainer installs test updates through SideStore. Every iOS update intended
for device testing must have a new app version and build number and be published
to the SideStore source; a merged PR or a CI artifact alone is not the delivery.

- Increment `MARKETING_VERSION` (normally the patch version) and
  `CURRENT_PROJECT_VERSION` in every app and extension build configuration in
  `ESPRemoteControl.xcodeproj/project.pbxproj`.
- Include `release-tag-<version>` in the release PR title or the release commit
  message on `main`. The existing `auto-release-tag.yml` workflow creates
  `ios-v<version>` and dispatches `build-ios-ipa.yml` for that tag.
- Use the existing release workflow to build and attach the IPA and checksum,
  then update `sidestore-source.json` with the actual asset URL and size.
- Before reporting an update as ready to test, verify the tagged release and
  IPA exist and the latest SideStore source entry has the new version. State
  the version and build number in the response.
- A successful build does not establish physical Bluetooth or wake behavior;
  distinguish CI validation from the maintainer's device testing.
