# Native glass button migration inventory

This inventory tracks interactive Button usages reviewed/migrated for native glass styles.

## Onboarding (OpenAlarm/OnboardingFlowView.swift)
- onboarding_welcome_next -> GlassProminentButtonStyle + cyan tint
- actionSkip (default settings step) -> GlassButtonStyle
- default settings next CTA (actionNext) -> GlassProminentButtonStyle + cyan tint
- permission pre-prompt request-next CTA (onboarding_permission_request_next) -> GlassProminentButtonStyle + cyan tint
- permission denied open settings CTA (onboarding_permission_denied_open_settings) -> GlassProminentButtonStyle + cyan tint

## Shared settings / permission (OpenAlarm/SharedAlarmSettingsEditor.swift)
- try-out CTA (alarmEditorTryOut) -> GlassProminentButtonStyle + cyan tint
- wake-check permission pre-prompt next CTA (wake_check_permission_next) -> GlassProminentButtonStyle + cyan tint
- wake-check permission denied open settings CTA (wake_check_permission_open_settings) -> GlassProminentButtonStyle + cyan tint
- wake-check permission denied disable-feature action (wake_check_permission_disable_feature) -> GlassButtonStyle
- shared settings selection-sheet option rows -> GlassButtonStyle

## Alarm editor (OpenAlarm/AlarmEditorView.swift)
- save-scope popover actions (saveScopeActionButton) -> GlassProminentButtonStyle + cyan tint

## Alarm/settings surfaces (OpenAlarm/MainTabView.swift)
- active nap pause/continue CTA -> GlassProminentButtonStyle + cyan tint
- active nap delete action -> GlassButtonStyle + danger tint
- alarm-row disable-choice popover actions (popoverActionButton) -> GlassProminentButtonStyle + cyan tint
- settings open-settings action button -> GlassButtonStyle

## Notes
- NavigationLink label surfaces still use oaGlassButtonChrome where they are not Button interactions.
- Regression guard: scripts/check_glass_button_migration.sh enforces no legacy Button + oaGlass*Chrome + .buttonStyle(.plain) pattern in migrated screens.
