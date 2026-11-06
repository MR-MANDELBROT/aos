# aOS brand

*aOS* is a working title. Everything that carries the name is listed at the end, so a rename stays one afternoon of
work.

## Idea

An aos is the extra building next to the main house. aOS is the extra Mac next to yours: your agent works there,
you stay in your own. The icon shows exactly that: a window, a second window behind it (the aos), and a pointer (the
agent at work).

**Tagline:** A Mac of its own for your coding agent. / Ein eigener Mac für deinen Coding-Agent.

**Voice:** calm, plain, short. Say what happens and who decides ("You approve every time"). No hype words, no
"AI magic", no dashes as punctuation in German texts. Agents are "your agent", never personified beyond that.

## Colors

| Name | Light | Dark | Use |
|------|-------|------|-----|
| Indigo | `#4D51E0` | `#8C90FF` | accent color of the app, buttons, icon background |
| Mint | `#3DD9B4` | `#8EECD3` | the pointer in the icon, "ready" and "file waiting" moments |
| Lavender | `#B2B9FF` | `#666CDC` | back window in the icon, soft fields on the website |

In the app the indigo is the asset catalog's `AccentColor`, mint is `BrandMint`. Status colors stay system colors
(green running, orange needs you, red error).

## Icon

`App/Resources/AppIcon.icon` (Icon Composer document, macOS 27 Liquid Glass): automatic gradient on indigo, three
glass layers (back window lavender, front window white, pointer mint), dark, clear and tinted variants come from the
same layers. Render pictures with Icon Composer's `ictool`:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" App/Resources/AppIcon.icon \
  --export-image --output-file icon.png --platform macOS --rendition Default --width 512 --height 512 --scale 2
```

## Type

System font only (SF Pro): large, bold titles with tight tracking on the website, standard macOS text styles in the
app. No custom fonts.

## App surfaces (macOS 27)

- Liquid Glass: `glassEffect` cards (`GlassCard`), `.glass` buttons for secondary and `.glassProminent` for the one
  primary action per screen, a native sidebar in the setup window.
- One hero symbol per setup step in a tinted glass circle.
- The menu bar window is a status surface: what is happening, what needs you, three quick actions.
- Requests that need the person (approval, help) use orange glass and always say who asks and why.

## Where the name appears

`AOSKit/Sources/AOSKit/Brand.swift`, `project.yml` (target, product and bundle names, `NSLocalNetworkUsageDescription`,
`SUFeedURL`), `App/LaunchAgents/*.plist` (label), the guest paths (`/usr/local/libexec/aos`, guest account `aos`,
only internal), `Tools/release.sh`, `site/`, `README.md`, `Docs/`.
