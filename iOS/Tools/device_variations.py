"""Gives the String Catalog its device variations: every text that names "this iPhone" gets an iPad wording, in English
and in German (rule and exceptions: device_words.py). Run by localize.sh after the import; safe to run again.

The iPhone's wording stays the source: English in the code, German in translations_de.py. This script only derives the
iPad's from them, so nothing has to be written twice. Texts that are no longer in the code (stale) are left alone.

Usage: python3 -I device_variations.py <Localizable.xcstrings> [--check]
"""
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("device_words", os.path.join(os.path.dirname(os.path.abspath(__file__)), "device_words.py"))
words = importlib.util.module_from_spec(spec)
spec.loader.exec_module(words)

path, *flags = sys.argv[1:]
catalog = json.load(open(path, encoding="utf-8"))
source = catalog.get("sourceLanguage", "en")


def plain(localization):
    """The text as an iPhone says it: the plain one, or the device variation for the others. None: not a plain text."""
    if localization is None:
        return None
    if "stringUnit" in localization:
        return localization["stringUnit"]["value"]
    device = localization.get("variations", {}).get("device")
    if device is None or set(localization["variations"]) != {"device"}:
        return None  # plural or other variations: not handled here
    unit = device.get("other", device.get("iphone", {})).get("stringUnit")
    return unit["value"] if unit else None


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


changed, skipped = 0, []
for key, entry in catalog["strings"].items():
    if entry.get("extractionState") == "stale":
        continue
    localizations = entry.setdefault("localizations", {})
    texts = {}
    for language in sorted(set(localizations) | {source}):
        text = plain(localizations[language]) if language in localizations else key
        if text is None:
            skipped.append(key)
            texts = None
            break
        texts[language] = text
    if texts is None:
        continue
    if not any(words.varies(text) for text in texts.values()):
        # Nothing an iPad says differently: no variation (also not one left from before)
        for language, text in texts.items():
            if language in localizations and "variations" in localizations[language]:
                localizations[language] = unit(text)
                changed += 1
        continue
    for language, text in texts.items():
        wanted = {"variations": {"device": {"ipad": unit(words.ipad(text)), "other": unit(text)}}}
        if localizations.get(language) != wanted:
            localizations[language] = wanted
            changed += 1

for key in skipped:
    print("left as it is (plural or other variations):", repr(key))
if "--check" in flags:
    print(f"device wording: {changed} texts would change")
else:
    if changed:
        with open(path, "w", encoding="utf-8") as file:
            # As Xcode writes it
            file.write(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")))
    print(f"device wording: {changed} texts updated")
