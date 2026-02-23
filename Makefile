.PHONY: generate check check-i18n check-no-literals

generate:
	xcodegen generate

check: check-no-literals check-i18n

check-no-literals:
	./scripts/check_no_literals.sh

check-i18n:
	./scripts/check_i18n.sh
