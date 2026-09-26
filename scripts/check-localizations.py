#!/usr/bin/env python3
"""Validate translation completeness and printf argument compatibility without third-party tools."""
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/ExplorerCore/Resources"
KEYS = set(re.findall(r"^\s*case (\w+)$", (ROOT / "Sources/ExplorerCore/LocalizationKey.swift").read_text(), re.M))
TOKEN = re.compile(r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.\d+)?(?:ll|l|h|z)?[@diuoxXfFeEgGcCsSp]")


def signature(text):
    return TOKEN.findall(text.replace("%%", ""))


def load(language):
    folder = RESOURCES / (language + ".lproj")
    text = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(folder / "Localizable.strings")]))
    plural = plistlib.loads((folder / "Localizable.stringsdict").read_bytes())
    assert not (text.keys() & plural.keys()), f"{language}: duplicate text/plural keys"
    assert text.keys() | plural.keys() == KEYS, f"{language}: keys differ from L10n.Key"
    for key, spec in plural.items():
        assert spec["NSStringLocalizedFormatKey"] == "%#@count@", (language, key)
        count = spec["count"]
        assert count["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType"
        assert count["NSStringFormatValueTypeKey"] == "ld"
        assert "other" in count
        if language == "en":
            assert "one" in count
        for category, value in count.items():
            if not category.startswith("NSString"):
                assert signature(value) == ["%ld"], (language, key, category)
    return text, plural


english, english_plural = load("en")
for language in ("ja",):
    translations, plurals = load(language)
    assert translations.keys() == english.keys() and plurals.keys() == english_plural.keys()
    for key, value in translations.items():
        assert value.strip() and signature(value) == signature(english[key]), (language, key)
for file in (ROOT / "Sources").rglob("*.swift"):
    assert not re.search(r"[ぁ-んァ-ヶ一-龠]", file.read_text()), f"Unlocalized Japanese in {file.relative_to(ROOT)}"
print(f"Localization checks passed: {len(KEYS)} keys, English and Japanese.")
