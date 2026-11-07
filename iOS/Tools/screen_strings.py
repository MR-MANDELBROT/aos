"""Puts the screen client's strings into the app's string catalog as manual entries.

The screen client (target ScreenClient, iOS/ThirdParty/OpenScreenSharing) looks its strings up in the main bundle, so
they live in the app's catalog (iOS/Resources/Localizable.xcstrings). Xcode doesn't extract them there by itself (the
module's strings would go into a catalog of the module's own), so this adds each one the module uses as a manual
entry, with German from Tools/translations_de.py and Tools/translations_screen_de.py (the first table wins) and the
English where it differs from the key. Run by Tools/screen_strings.sh; afterwards Tools/localize.sh keeps them.

Usage: python3 -I screen_strings.py <exported de.xliff with the module's strings> <Localizable.xcstrings> <table.py>...
"""
import importlib.util
import json
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

xliff, catalog_path, *tables = sys.argv[1:]
DE = {}
for number, table in enumerate(tables):
    spec = importlib.util.spec_from_file_location(f"t{number}", table)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for key, value in module.DE.items():
        DE.setdefault(key, value)

ns = "urn:oasis:names:tc:xliff:document:1.2"
units = {}
for file in ET.parse(xliff).getroot().iter("{%s}file" % ns):
    if not file.get("original", "").startswith("ThirdParty/OpenScreenSharing/Sources/Localizable"):
        continue
    for unit in file.iter("{%s}trans-unit" % ns):
        source = unit.find("{%s}source" % ns)
        note = unit.find("{%s}note" % ns)
        units[unit.get("id")] = (source.text if source is not None else unit.get("id"),
                                 note.text if note is not None else None)

catalog = json.load(open(catalog_path, encoding="utf-8"))
strings = catalog["strings"]
added, revived, missing = [], [], []
for key, (english, comment) in sorted(units.items()):
    entry = strings.get(key)
    if entry is None:
        entry = strings[key] = {"extractionState": "manual"}
        added.append(key)
    elif entry.get("extractionState") == "stale":
        entry["extractionState"] = "manual"
        revived.append(key)
    if comment and comment != "No comment provided by engineer.":
        entry.setdefault("comment", comment)
    localizations = entry.setdefault("localizations", {})
    if english and english != key:
        localizations["en"] = {"stringUnit": {"state": "translated", "value": english}}
    if key in DE:
        localizations["de"] = {"stringUnit": {"state": "translated", "value": DE[key]}}
    elif "de" not in localizations:
        missing.append(key)

with open(catalog_path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
    f.write("\n")
print(f"screen client strings: {len(units)}, added {len(added)}, used again {len(revived)}")
for key in missing:
    print("  no German:", repr(key))
