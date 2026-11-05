#!/bin/bash
# Exports the strings, fills German from Tools/translations_de.py, imports them into the string catalogs.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/loc
xcodebuild -exportLocalizations -project Annex.xcodeproj -localizationPath build/loc -exportLanguage de \
  -skipPackagePluginValidation -skipMacroValidation >/dev/null 2>&1
X="build/loc/de.xcloc/Localized Contents/de.xliff"
python3 - "$X" <<'PY'
import sys, importlib.util, xml.etree.ElementTree as ET
spec = importlib.util.spec_from_file_location("t", "Tools/translations_de.py"); t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
ns = 'urn:oasis:names:tc:xliff:document:1.2'
ET.register_namespace('', ns)
tree = ET.parse(sys.argv[1]); missing = []
for u in tree.getroot().iter('{%s}trans-unit' % ns):
    key = u.get('id'); de = t.DE.get(key)
    if de is None: missing.append(key); continue
    target = u.find('{%s}target' % ns)
    if target is None:
        target = ET.SubElement(u, '{%s}target' % ns)
    target.text = de; target.set('state', 'translated')
tree.write(sys.argv[1], encoding='UTF-8', xml_declaration=True)
if missing: print("missing German:", *missing, sep="\n  ")
PY
xcodebuild -importLocalizations -project Annex.xcodeproj -localizationPath build/loc/de.xcloc -skipPackagePluginValidation -skipMacroValidation >/dev/null 2>&1
echo "imported"
