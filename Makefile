.PHONY: generate check check-i18n check-no-literals check-glass-buttons test

generate:
	xcodegen generate

test:
	swift test

check: check-no-literals check-i18n check-glass-buttons

check-no-literals:
	./scripts/check_no_literals.sh

check-i18n:
	./scripts/check_i18n.sh


check-glass-buttons:
	./scripts/check_glass_button_migration.sh
