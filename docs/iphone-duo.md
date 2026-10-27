# iPhone Duo and bedside naps

OpenAlarm builds with Xcode 27.1 and retains its iOS 26 deployment target. Both landscape orientations are supported. System tabs, navigation, sheets, and labeled toolbar actions can adapt to the outer display's vertical bars.

CI uses the [Xcode 27 runner image](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) and selects Xcode 27.1 explicitly. A newer beta selected by filename sorting may not have the same Duo SDK support.

Onboarding, permission covers, alarm dismissal, wake-up confirmation, and the nap bedside screen keep readable content within one pane when an active fold divides the display. A horizontal fold uses the upper pane. A vertical fold uses the larger pane. Active camera regions are excluded too. Backgrounds still fill the display. The iOS 27.1 reserved-region API supplies the actual geometry, with the normal layout retained on iOS 26 and 27.0. No device-name or hinge-angle heuristic determines layout.

Fixed challenge layouts and onboarding can scroll on short displays or with larger text. Resizing keeps the existing state-owning views, selected tab, alarm draft, challenge, and nap. Two tabs remain a tab bar because a sidebar would add little navigation value here.

## Nap bedside screen

Start a nap, then tap the moon button in its active row. It reads the current nap from `AlarmStore`, with pause and resume using the existing scheduling methods. Close returns to the same tab without cancelling the nap. Alarm disarm and wake-check presentations take precedence over bedside content.

The dawn glow begins in the last five minutes. For a shorter nap, it uses the nap's duration. Pause, snooze, and the glow toggle return the background to black. Adding time can put the nap outside the glow window again. The display stays awake while bedside content is visible and the scene is active. Closing, backgrounding, deleting the nap, or presenting an alarm releases that request and restores the prior idle-timer setting. The feature does not change hardware brightness or schedule a separate alarm.

## Tent placement and StandBy

Apple describes landscape support as useful for tent placement in [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/). Its [iPhone pose guide](https://support.apple.com/guide/iphone/pose-iphone-duo-iphv3p93k1bm/ios) also describes tent placement for StandBy. App layout follows the surface the system supplies. OpenAlarm does not force the outer display active or try to draw simultaneously on both displays.

The foreground glow requires OpenAlarm to remain open and unlocked. It cannot brighten the locked display or launch the app when an alarm fires. AlarmKit remains responsible for the scheduled alert. Apple's [AlarmKit introduction](https://developer.apple.com/videos/play/wwdc2025/230/) describes its Lock Screen, Dynamic Island, StandBy, and Apple Watch presentations.

The nap Live Activity uses a larger central countdown when `isActivityFullscreen` is true, with a dark violet background tint that the system can extend across StandBy. Pause, resume, cancel, and extension controls remain App Intents. A timer renders from its end date without per-second ActivityKit updates. Expired timer intervals clamp at zero.

StandBy controls display dimming, Always-On behavior, and the red night tint. The Live Activity does not implement a continuous sunrise animation or a scheduled brightness ramp. Apple's [Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/) explains background extension, and [Design dynamic Live Activities](https://developer.apple.com/videos/play/wwdc2023/10194/) covers StandBy scaling and night tint. The foreground keep-awake request follows the lifecycle requirements for [`isIdleTimerDisabled`](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled).

## Verification

The geometry tests cover flat displays, empty and offscreen regions, asymmetric vertical folds, upper-pane selection, and simultaneous camera and fold exclusions. Dawn tests cover long and short naps, expiration, extension, pause, snooze, and invalid durations. Display-session tests check repeated activation, release, reactivation, and restoration of an existing keep-awake request.

Simulator checks on 2026-10-27 covered outer portrait onboarding and home, outer landscape bedside controls, both flat inner orientations, nap retention while unfolding, book mode's clear pane, and tabletop's upper pane. Real naps exercised pause, resume, Close without cancellation, reopening, the glow toggle, late dawn readability, and AlarmKit expiry while bedside was open. The Settings tab remained selected through tabletop, folding to outer landscape, and reopening to inner portrait. The initial opaque navigation background was corrected and the visible glow was checked again. Native toolbar controls now switch to light appearance during the bright phase so Close retains dark ink. The ten new tests also passed on iOS 26.5.

Final local validation passed all 82 app tests on Duo, 167 scheduling-core tests, the no-signing iOS device build, and `make check`. The app suite initially had a permission-dependent failure, then passed after alarm access was enabled in the simulator. The hosted CI workflow itself has not been run from this local task.

Run the Foundation-only suite with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native`. Xcode 27's default SwiftBuild backend tries to compile the app's unhandled storyboard as a macOS package resource. The native backend runs the existing scheduling package without that resource-processing error.

Physical-device checks remain necessary for tent display routing, locked StandBy, night tint, charging, Always-On behavior, and the perceived glow at different brightness settings. Simulator evidence does not establish those behaviors.

The full settings/editor/task matrix in both rotations, Split View on each side, right-to-left layout, and accessibility text sizes has not been manually verified. The scroll fallbacks and geometry tests cover their layout mechanisms, rather than establishing an exhaustive device acceptance result.
