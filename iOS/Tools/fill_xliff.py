"""Fills the German targets of an exported XLIFF from a dictionary (key: English source, value: German).

Usage: python3 -I fill_xliff.py <de.xliff> <translations_de.py> [--check]
Also checks the German for dashes used as punctuation (house style: none in German texts) and for format
specifiers that don't match the English.
"""
import importlib.util
import re
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True  # no __pycache__ next to translations_de.py

xliff, table, *flags = sys.argv[1:]
spec = importlib.util.spec_from_file_location("t", table)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DE = module.DE

ns = "urn:oasis:names:tc:xliff:document:1.2"
ET.register_namespace("", ns)
tree = ET.parse(xliff)
missing, problems = [], []
# The kinds of format specifiers, without positions (%1$@ and %@ are the same kind).
spec_re = re.compile(r"%(?:\d+\$)?(lld|ld|d|@|f|\.\d+f|u|llu)")
for unit in tree.getroot().iter("{%s}trans-unit" % ns):
    key = unit.get("id")
    source = unit.find("{%s}source" % ns)
    english = source.text if source is not None else key
    de = DE.get(key, DE.get(english))
    if de is None:
        missing.append(key)
        continue
    if sorted(spec_re.findall(english or "")) != sorted(spec_re.findall(de)):
        problems.append(f"format specifiers differ: {key!r} -> {de!r}")
    if re.search(r"\s[–—-]\s", de) or "–" in de or "—" in de:
        problems.append(f"dash as punctuation: {de!r}")
    target = unit.find("{%s}target" % ns)
    if target is None:
        target = ET.SubElement(unit, "{%s}target" % ns)
    target.text = de
    target.set("state", "translated")
if "--check" not in flags:
    tree.write(xliff, encoding="UTF-8", xml_declaration=True)
for p in problems:
    print("PROBLEM:", p)
if missing:
    print(f"missing German ({len(missing)}):")
    for key in missing:
        print("  " + repr(key))
else:
    print("all strings have German")
