# keyboard-extension (Expo config plugin + iOS extension target)

A custom iOS keyboard extension that lets the user dictate from any text field system-wide. Its keys look and type like Apple's keyboard; the toolbar above them holds the tone menu, the dictation pill and the agent button, with no suggestions or autocorrect. Tapping **Tap to speak** records in place through the OpenWhispr app's background session; only when that session has gone stale does the pill read **Activate** and hand off to the app.

## What's here

| File                                  | Role                                                                                                                                                                           |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `withKeyboardExtension.js`            | Expo config plugin. Runs at `expo prebuild` time and adds the keyboard target to the generated Xcode project, links the entitlements, and configures the App Group capability. |
| `ios/KeyboardViewController.swift`    | The keyboard UI and lifecycle. Reads/writes shared state through the App Group `UserDefaults` suite (see [`modules/app-group-storage`](../../modules/app-group-storage/)).     |
| `ios/KeyboardCapitalization.swift`    | When shift turns on by itself, following the field's autocapitalization type. Foundation-only, so it is unit-tested on macOS.                                                  |
| `ios/Info.plist`                      | Extension Info.plist (display name, RequestsOpenAccess, etc.)                                                                                                                  |
| `ios/OpenWhisprKeyboard.entitlements` | App Group capability entitlement                                                                                                                                               |
| `tests/`                              | Swift tests: the capitalization rule, and UIKit touch routing across the real keyboard layout.                                                                                 |
| `__tests__/`                          | Jest tests for the config plugin's Xcode project wiring.                                                                                                                       |

## How it works

1. User installs the keyboard from iOS Settings → General → Keyboard → Keyboards → Add New, and turns on Allow Full Access.
2. User opens any app, switches to the OpenWhispr keyboard and taps the pill.
3. **In place.** When the app's background session is ready (`isBackgroundSessionReady()`), or when the keyboard is inside OpenWhispr itself, the pill reads **Tap to speak**. A tap writes a start request to the App Group and posts a Darwin notification. The app records without leaving the host app, the keyboard shows a recording canvas, and it inserts the transcript when `transcriptReady` arrives.
4. **Handoff.** Only when that session has gone stale does the pill read **Activate**. Its link opens `<scheme>://keyboard-dictation` (handled by [src/hooks/useKeyboardHandoff.ts](../../src/hooks/useKeyboardHandoff.ts)). The app starts a native recording, then sends the user back to the host app (`returnToHost` in [src/lib/handoffReturn.ts](../../src/lib/handoffReturn.ts)). iOS 26.4+ hides the host from the extension, so the containing app learns it from UIKit ([`HostAppObserver.swift`](../../modules/app-group-storage/ios/HostAppObserver.swift)). When no host is found, the app shows the "Swipe back to your app" screen instead. The transcript is pasted on the keyboard's next focus.

## Apple capabilities required

- **App Group** (`group.<ios bundle id>`) — must match between the main app, the extension, and the `app-group-storage` module.
- **Open Access** (`RequestsOpenAccess` in `Info.plist`) — required for the extension to read/write the shared suite.

## Environments

Runtime identifiers are resolved from `config/openwhispr-environments.js` and applied by `app.config.js` plus this plugin during prebuild.

- Production/TestFlight: `OPENWHISPR_APP_ENV=production`
- Development: `OPENWHISPR_APP_ENV=development`
- Local signing override: set `OPENWHISPR_IOS_BUNDLE_IDENTIFIER` and `OPENWHISPR_SCHEME` when needed. The App Group defaults to `group.<OPENWHISPR_IOS_BUNDLE_IDENTIFIER>`.

Verify with:

```bash
OPENWHISPR_APP_ENV=development npx expo config --json
```

After changes, regenerate the native project:

```bash
OPENWHISPR_APP_ENV=development npx expo prebuild --clean
npm run ios
```

## Tests

```bash
npm run test:keyboard-capitalization # capitalization rule (macOS, needs Xcode's swiftc)
npx jest plugins/keyboard-extension # config plugin
```

Mobile CI runs both, and the touch regression tests below, on pull requests that change `openwhispr-mobile/`.

## Keyboard touch regression tests

On macOS with Xcode:

```bash
python3 openwhispr-mobile/plugins/keyboard-extension/tests/run-keyboard-touch-tests.py
```

Run it from the repository root after changing the keyboard layout, its padding or key targets; mobile CI runs it too. The runner compiles the production keyboard Swift sources for Mac Catalyst, so it needs no simulator, signing credentials or Expo build; it stubs what iOS would tell the keyboard (the field behind it, the globe key, a phone or an iPad, landscape). It tests UIKit hit routing across row gaps, overlapping key targets, unequal key widths, nested stacks, hidden layouts, disabled keys and keyboard boundaries, then lays out the real keyboard at every iPhone width in portrait and landscape, on all three pages, with and without the globe key, on iPad, and with the URL, email, web search and Twitter bottom rows and a greyed return key, and checks that no tap below the dictation strip is dropped, the keyboard's padding included. It also checks shift after letters and deletes, smart quotes per field, the return key and Twitter rows per page, rotation, the globe key settling late, a view shorter than the keyboard, and the review card's extra height.

The height regressions also exercise the intrinsic self-sizing contract at cold
start with provisional host frames, compact/full transitions and review expansion.
They cannot validate iOS's system-owned glass backdrop. Before releasing a sizing
change, cold-launch several host apps (including a search field), open the keyboard
for the first time, and compare the toolbar/backdrop before and after switching to
another keyboard and back. Repeat with full and minimal keyboards, in portrait and
landscape. The previous sizing patch has **not** resolved the reported first-opening
failure on a physical iPhone; passing the fitting tests is not evidence otherwise.

### Cold-presentation diagnostics

Release and Debug builds emit bounded `KEYBOARD_GEOMETRY` records through Apple's
unified logging (`com.gizmolabs.openwhispr.keyboard`, category `UI`, notice level).
Capture that subsystem from the device while reproducing; do not publish an
unfiltered device log. Each input view has an ephemeral `input` token so sizing
queries can be paired with its controller events. `presentation=1` and `2` distinguish
first opening from reopening **of that controller**; a new token indicates recreation.
There are at most 96 controller and 96 sizing records per input instance, with
unchanged layout snapshots suppressed. No field text, transcript, host identity,
URL, credentials, or persistent device identifier is included.

Record, in order, without changing settings between the first two observations:

1. After a fresh app/extension start, open a host text field and screenshot the
   broken presentation. Preserve `loaded`, `willAppear.*`, `safeAreaChanged`,
   `layout`, `didAppear`, and fitting/intrinsic queries (including `content=0`, if any).
2. Dismiss and reopen the same field; screenshot the recovered presentation.
3. Switch to Apple's keyboard and back; capture again. Repeat separately in full
   and minimal mode, portrait and landscape, including without Full Access.

Compare requested/content height against actual input bounds, root and toolbar
frames, safe/additional safe-area insets, and up to four ancestor frames/insets.
This distinguishes an extension-content offset from an unchanged content view in a
changed system container, and shows whether a late host/inset transition happens
without a new size request. Do **not** infer point values from cropped/scaled images.
The system backdrop lives outside the extension's ownership: these measurements
and screenshots must be correlated, not treated as a direct measurement of its glass.
No diagnostic callback changes layout, forces a keyboard reload, adds padding or
schedules a delayed sizing retry. This is instrumentation, **not a confirmed fix**.

Overriding `loadView` to assign a custom view is documented UIKit behavior;
[UIViewController.loadView](<https://developer.apple.com/documentation/uikit/uiviewcontroller/loadview()>)
specifically says not to call `super` in that implementation. Its absence alone
is not a root cause. Likewise, initial safe areas may be zero before attachment;
[UIView.safeAreaInsets](https://developer.apple.com/documentation/uikit/uiview/safeareainsets)
and `viewSafeAreaInsetsDidChange` describe that lifecycle. Do not compensate for
it permanently without first observing the failing and recovered host cycles.

These touch tests do not measure typing latency. Before releasing,
check fast two-thumb typing and repeated letters on an iPhone, near-edge taps,
Shift, 123/ABC, space/return, held delete, keyboard switching, and dictation in
portrait and landscape in Notes and another host app.

## Reference

- [Apple — Custom Keyboard Extensions](https://developer.apple.com/documentation/uikit/keyboards_and_input/creating_a_custom_keyboard)
- [Apple — App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
