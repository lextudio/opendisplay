# Local macOS development

Keep the development app identities stable. macOS TCC associates Screen
Recording and Accessibility grants with the bundle identifier and signing
requirement; changing either creates stale or duplicate permission entries.

- Sender Debug bundle ID: `com.peetzweg.opensidecar.mac.debug`
- Receiver Debug bundle ID: `com.peetzweg.opensidecar.mac.receiver.debug`
- Keep Debug builds separate from the release bundle IDs.
- Build the sender into `build/Build/Products/Debug/OpenDisplay Dev.app` and
  launch it with `./run.sh`. The script normalizes an ad hoc build's designated
  requirement before launch. Do not rebuild or re-sign it after granting Screen
  Recording during a test session.
- If the Debug sender's permission row is stale, quit it, run
  `tccutil reset ScreenCapture com.peetzweg.opensidecar.mac.debug`, launch the
  unchanged app, use its Grant button, and restart it once.

The Intel receiver test host is available as `ssh imac`. Deploy the x86_64
Debug receiver to `~/Applications/OpenDisplay Receiver Dev.app`; do not replace
the release receiver app. A windowed receiver is sufficient for protocol,
encode, and decode validation. Use its fullscreen video window for end-to-end
latency, presentation, scaling, and visual-quality measurements.

## Deploying the iOS receiver (iPad/iPhone)

`com.lextm.opendisplay.ios` is installed with `xcrun devicectl`. Its embedded
provisioning profile expires (about a week for a personal team), after which
installation fails with `0xe8008011` ("This provisioning profile has expired.")
and the app already on the device may show "OpenDisplay Is No Longer Available".
This is a signing-profile problem, not a code one — rebuild with
`-allowProvisioningUpdates` to fetch a fresh profile, then install and launch:

```bash
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecariOS \
  -configuration Debug -destination 'id=<device-udid>' \
  -allowProvisioningUpdates PRODUCT_BUNDLE_IDENTIFIER=com.lextm.opendisplay.ios \
  -derivedDataPath build build
xcrun devicectl device install app --device <coredevice-id> \
  build/Build/Products/Debug-iphoneos/OpenSidecariOS.app
xcrun devicectl device process launch --device <coredevice-id> \
  com.lextm.opendisplay.ios
```

Test iPad: udid `afb4b890dc4b5d269b7de027c37e1517061b576b`, coredevice id
`1E3BE8A5-1E69-5D5E-AC88-88589FA848CC`. Reinstalling replaces the running
instance, so relaunch after every install.

The receiver's log lives in the app container; pull it with
`xcrun devicectl device copy from --device <coredevice-id> --source
Documents/opensidecar-phone.log --destination <file> --domain-type
appDataContainer --domain-identifier com.lextm.opendisplay.ios`. This copy fails
with "socket was closed unexpectedly" while the app is busy streaming or after
it has crashed; retry after relaunching the app.
