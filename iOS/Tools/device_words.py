"""The device the app runs on, by name: where a text says "iPhone" and means this device, an iPad says "iPad".

One rule for English and German: the word is swapped, nothing else. Both are neuter in German and decline alike
("dieses iPhone", "des iPhones" / "dieses iPad", "des iPads"), so the swapped sentence is right too. An iPhone Duo is an
iPhone. Phrases that name something else stay as they are: the Mac app's own labels (its menu and its settings say
"iPhone" for the paired device, whatever it is).

Used by device_variations.py (the String Catalog's device variations) and fill_xliff.py (the German of the variations
that an export contains).
"""

# Kept word for word, in English and in German.
KEPT = [
    "“Pair” next to iPhone",
    "bei „iPhone“ auf „Koppeln“",
    "Settings > iPhone",
    "Einstellungen > iPhone",
    "“Install apps on my iPhone”",
    "„Apps auf meinem iPhone installieren“",
]


def ipad(text):
    """`text` as an iPad says it."""
    held = {}
    for number, phrase in enumerate(KEPT):
        if phrase in text:
            mark = f"\x00{number}\x00"
            held[mark] = phrase
            text = text.replace(phrase, mark)
    text = text.replace("iPhone", "iPad")
    for mark, phrase in held.items():
        text = text.replace(mark, phrase)
    return text


def varies(text):
    """Whether an iPad says `text` differently."""
    return ipad(text) != text
