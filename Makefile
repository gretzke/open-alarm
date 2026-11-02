.PHONY: generate check check-i18n check-no-literals check-glass-buttons test test-app-resources

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SWIFT_TEST_JOBS ?= 1

generate:
	xcodegen generate

test:
	swift test --build-system native --jobs $(SWIFT_TEST_JOBS)

test-app-resources:
	@test -d "$(APP_BUNDLE_PATH)"
	OPENALARM_APP_BUNDLE_PATH="$(APP_BUNDLE_PATH)" swift test --build-system native --jobs $(SWIFT_TEST_JOBS) --filter RingtoneResourceTests

check: check-no-literals check-i18n check-glass-buttons

check-no-literals:
	./scripts/check_no_literals.sh

check-i18n:
	./scripts/check_i18n.sh


check-glass-buttons:
	./scripts/check_glass_button_migration.sh
