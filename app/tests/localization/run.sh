#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT="$PWD/checks/i18n/unit"
mkdir -p "$OUT"
python3 scripts/check-localization.py
xcrun swiftc app/Localization.swift app/LocalizationCatalog.swift app/tests/localization/main.swift -o "$OUT/localization-test"
export HARBOR_TEST_PREFERENCES_DOMAIN="local.harbor.localization-test.$$.${RANDOM}"
unset HARBOR_LANGUAGE
trap '"$OUT/localization-test" --reset' EXIT
"$OUT/localization-test"
"$OUT/localization-test" --set-chinese
"$OUT/localization-test" --check-persisted
"$OUT/localization-test" --reset
"$OUT/localization-test" -AppleLanguages '(zh-Hans)' --expect-language zh-Hans
"$OUT/localization-test" -AppleLanguages '(en-US)' --expect-language en
"$OUT/localization-test" -AppleLanguages '(ja-JP)' --expect-language en
