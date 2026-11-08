---
name: Bergamota
description: The Mac control panel for a Poco F1 running iOS, drawn in the Bergamota identity - paper work area, a lime state rail with halftone dots, ink console, Archivo and JetBrains Mono.
colors:
  lime: "#d7e98a"
  lime-dot: "#c6dc72"
  ink: "#161616"
  paper: "#f4f3ec"
  leaf: "#1a5933"
  alert: "#b3261e"
  amber: "#e8a33a"
  console-line: "#2c2c29"
  console-muted: "#9a9992"
  alert-on-ink: "#ff6a5a"
  tile-ink: "#1d1d1b"
  quiet: "#8d8c85"
  ground-light: "#f4f3ec"
  ground-dark: "#141413"
  surface-light: "#fbfaf5"
  surface-dark: "#1e1e1c"
  rule-light: "#e2e0d6"
  rule-dark: "#2e2e2b"
  text-light: "#161616"
  text-dark: "#f4f3ec"
  muted-light: "#66655f"
  muted-dark: "#a3a29b"
  leaf-text-light: "#1a5933"
  leaf-text-dark: "#9ccf86"
  alert-text-light: "#b3261e"
  alert-text-dark: "#ff7b6b"
  amber-text-light: "#8a4d00"
  amber-text-dark: "#f0b860"
typography:
  display:
    fontFamily: "Archivo (bundled woff2, variable), system black fallback"
    fontSize: "30px"
    fontWeight: 900
    lineHeight: 1.1
    letterSpacing: "normal"
    fontVariation: "wght 900, wdth 112"
  display-state:
    fontFamily: "Archivo (bundled woff2, variable), system black fallback"
    fontSize: "52px"
    fontWeight: 900
    lineHeight: 1
    fontVariation: "wght 900, wdth 112"
  display-empty:
    fontFamily: "Archivo (bundled woff2, variable)"
    fontSize: "22px"
    fontWeight: 900
    fontVariation: "wght 900, wdth 112"
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "callout (12-13px at default macOS scale)"
    fontWeight: 400
  data:
    fontFamily: "JetBrains Mono (bundled woff2, variable), system monospaced fallback"
    fontSize: "12px"
    fontWeight: 400
  data-console:
    fontFamily: "JetBrains Mono"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: "11.5px + 2px line spacing"
  label:
    fontFamily: "JetBrains Mono"
    fontSize: "11px"
    fontWeight: 800
    letterSpacing: "1.3px"
  pill:
    fontFamily: "JetBrains Mono"
    fontSize: "10.5px"
    fontWeight: 800
    letterSpacing: "0.6px"
rounded:
  panel: "12px"
  tile: "14px"
  button: "9px"
  banner: "14px"
  capsule: "999px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "16px"
  lg: "22px"
  page: "28px"
  rail-x: "20px"
components:
  panel:
    backgroundColor: "{colors.surface-light}"
    textColor: "{colors.text-light}"
    rounded: "{rounded.panel}"
    padding: "16px"
  panel-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.text-dark}"
  button-primary:
    backgroundColor: "{colors.leaf}"
    textColor: "{colors.paper}"
  button-danger:
    backgroundColor: "{colors.alert}"
    textColor: "{colors.paper}"
  button-send:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    padding: "8px 14px"
  button-stage:
    backgroundColor: "{colors.lime}"
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    padding: "8px 14px"
  button-console:
    backgroundColor: "{colors.console-line}"
    textColor: "{colors.paper}"
    rounded: "{rounded.button}"
    padding: "8px 14px"
  pill:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.lime}"
    rounded: "{rounded.capsule}"
    typography: "{typography.pill}"
  console:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.data-console}"
    padding: "12px"
  cp-tile:
    backgroundColor: "{colors.tile-ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.tile}"
    padding: "16px"
  state-rail:
    backgroundColor: "{colors.lime}"
    textColor: "{colors.ink}"
    width: "340px"
  empty-stage:
    backgroundColor: "{colors.lime}"
    textColor: "{colors.ink}"
    rounded: "{rounded.panel}"
    padding: "22px"
---

# Design System: Bergamota

## Overview

**Creative North Star: "The Phone Never Leaves the Window"**

Bergamota is a native macOS SwiftUI app whose look is the Bergamota identity (`tools/identity/IDENTITY.md`) carried from the phone's boot screens onto the Mac: a paper work area, ink type, and a lime rail with the identity's 14 pt halftone dots standing beside every section. The rail holds the phone's state in Archivo 900, what the app is doing, Newton in halftone rising from its foot, and an ink console panel with the next boots. The work area does the section's job on quiet paper panels; the rail answers "what is the phone doing and what happens next" at a glance.

Density is that of a working instrument watched for hours: mono values, hairline-ruled rows, few colours, each with a job (leaf = iOS up and primary action, amber = ABL fastboot and waiting, alert red = anything that writes the phone or fails, lime = the stage). In the dark appearance paper and ink swap; the lime stage and the ink console do not change. The system refuses a dashboard of cards where the phone's state is one card among many.

**Key Characteristics:**
- One lime state rail (inspector column, 290-420 pt, 330 ideal) beside every page; hidden, its state falls back to a pill in the sidebar foot.
- Paper/ink work area with flat hairline panels; no shadows anywhere.
- Archivo 900 at 112% width for state words, page titles and big numbers; JetBrains Mono for every value; SF Pro for labels and controls.
- Halftone as the only decoration: the lime dot ground and the ink dissolve.
- Colour carries meaning (state, danger), never ornament.
- Native chrome stays native (sidebar List, toolbar, confirmation dialogs, `.borderedProminent`).

## Colors

A paper-and-ink neutral field with one lime stage and three working accents; every accent maps to a phone state or consequence.

### Primary
- **Leaf Green** (#1a5933): primary actions (`.borderedProminent` tint), iOS up. On the work area, text/icon use is `leaf-text` (#1a5933 light, #9ccf86 dark) so it keeps contrast on ink.
- **Stage Lime** (#d7e98a): the state rail, empty states, the drop-target fill (55% opacity), Bergamota fastboot's button. Its dots are #c6dc72 on a 14 pt grid, radius 1.6 pt.

### Secondary
- **Fastboot Amber** (#e8a33a): ABL fastboot, iOS booting, waiting, Send now. Type on amber is ink. As text on the work area: #8a4d00 light, #f0b860 dark.
- **Alert Red** (#b3261e): writes the phone, failures, panic; type on it is paper. Text on the work area: #b3261e light, #ff7b6b dark; on ink: #ff6a5a.

### Neutral
- **Paper** (#f4f3ec light ground; #141413 dark ground): the work area page background.
- **Surface** (#fbfaf5 light, #1e1e1c dark): Panel fill.
- **Rule** (#e2e0d6 light, #2e2e2b dark): hairlines and Row dividers.
- **Text** (#161616 light, #f4f3ec dark) and **Muted** (#66655f light, #a3a29b dark): body and secondary text.
- **Ink** (#161616): the console, type on the lime stage; unchanged in dark.
- **Console Line** (#2c2c29) / **Console Muted** (#9a9992): rules and secondary text on ink.
- **Control Plane Tile** (#1d1d1b): one step lighter than ink for raised tiles on the second-display window.
- **Quiet** (#8d8c85): the offline/unknown pill fill.

### Tones (phone state as fill + type)
leaf/paper (iOS up), lime/ink, ink/lime (Bergamota fastboot, recovery, android), amber/ink (ABL fastboot, iOS booting), alert/paper, quiet/paper (offline, unknown). Text colour per state on paper: leafText, amberText, text, muted.

### Named Rules
**The Colour-Is-State Rule.** A colour on screen names a phone state or a consequence. Decorative use of leaf, amber, alert or lime is a defect.

**The Red-Writes Rule.** Alert red marks exactly what writes the phone (flash userdata, boot, logo) and failures; it also always asks first (typed or dialog confirmation).

**The Ink-Under-Lime Rule.** On the lime stage every mark (type, rules, underline, progress) is ink; lime on lime vanishes.

## Typography

**Display Font:** Archivo, bundled `archivo.woff2`, variation axes wght 900 / wdth 112 (fallback system black)
**Body Font:** SF Pro (system) for labels, controls, callouts
**Label/Mono Font:** JetBrains Mono, bundled `jetbrains-mono.woff2`, variable weight (fallback system monospaced)

**Character:** A heavy, wide grotesque for the few words that matter and a plain engineering mono for everything measured, with the system face doing only UI work. Loaded through CoreText so the app uses the exact faces the phone screens and the icon were drawn with.

### Hierarchy
- **State word** (Archivo 900/112, 52 pt, min scale 0.45, 3 lines): the rail's state or activity title.
- **Page title** (Archivo 900/112, 30 pt): `PageHeader`, with a `.callout` muted subtitle under it (6 pt gap, 2 lines).
- **Empty title** (Archivo, 22 pt): `EmptyStage`. Banner titles 28 pt (50 in big), Control Plane scaled by `s`.
- **Body** (SF Pro callout): row keys, notices, descriptions.
- **Data** (JetBrains Mono 12 pt, 400): Row values, paths, commands. Console text 11.5 pt with 2 pt line spacing. Rail detail lines 10.5-11.5 pt, weight 500-700.
- **Label** (JetBrains Mono 11 pt, 800, tracking 1.3, caps): `Label12` section heading inside a Panel or rail console, muted. `caps()` keeps the product spelling "iOS".
- **Pill** (JetBrains Mono 10.5 pt, 800, tracking 0.6, caps).

### Named Rules
**The Three Voices Rule.** Archivo says what state; mono says what value; SF Pro says what to do. Never set a value in SF Pro or a label in Archivo.

**The Monospaced Digits Rule.** Live numbers use `.monospacedDigit()` so they do not shimmer while metrics refresh.

## Layout

A `NavigationSplitView` (sidebar 170 min / 196 ideal) with the page as detail and the State Rail as the inspector on the right. Pages are single scrolling columns on the paper ground with 28 pt page padding and 22 pt between blocks; panels sit side by side in `HStack`s when two fit (Dashboard: Detection and Mac, then the device panel). Spacing is hand-set rather than tokenised: 6 / 10 / 16 / 22 / 28 pt are the reused steps (6 header gap, 10 in-panel, 16 panel padding and header gap, 22 empty-stage padding and block gap, 28 page padding). The Control Plane window is a separate, ink-ground, large-type layout driven by a scale factor `s` for a second display; every size in it is `n * s`.

## Elevation & Depth

Flat. Depth is tonal: ground < surface panel with a 1 pt rule hairline in the work area; ink console and the lime rail sit as separate planes, with the Newton halftone dissolve (46 pt, ink dots growing quadratically from nothing to solid, cell 7 pt) bridging stage to console. No shadows, no blur, no gradients.

### Named Rules
**The Flat-Hairline Rule.** Separation comes from fill and a 1 pt `rule` stroke, never a shadow.

## Shapes

12 pt continuous-feeling corners on panels, empty stage and drop zones; 14 pt on Control Plane tiles and banners (26 in big); 9 pt on Control Plane/rail buttons; capsules for pills and progress tracks (8 pt tall in the rail, 6 in banners). Drop targets are a dashed 1.5 pt hairline (6/5 dash) that fills lime at 55% and turns leaf-text while hovered. The signature texture is the 14 pt halftone dot grid; Newton is a halftone portrait cropped hair-to-shoulders.

## Components

### State Rail (signature component)
- A 290-420 pt (330 ideal) inspector column, full height under the toolbar. Top to bottom: state pill (only when the activity line does not already say the state), a symbol, the state word (Archivo 52 pt), mono detail, optional ink progress capsule, a "since hh:mm . serial" mono line; then Newton, sized so head and shoulders fill the remaining height; then the ink console.
- Ink console (20 pt horizontal, 16 pt vertical padding, forced dark scheme): `Queue` label, an armed/stopped pill (amber/console-line), Start (lime/ink) or Stop (console-line/paper), the next three items in mono 11.5 pt 600, `writes <target>` in alert-on-ink, "+ n more", amber Send now (confirmation dialog: "Send the next image now?"), and the last boot line.
- **Signature move: the Step.** `StateStep` on the state word. When the state or title key changes, the word drops to 18% opacity for 90 ms with animations disabled (two frames, no eased fade), and a 64x4 pt ink underline stays 7 pt under it until the pointer passes over the word or the window next becomes key (cleared 1.5 s later), so a change that happened while you were in the terminal is still marked. The underline mark is ink on lime and the tone's `on` colour in the banner.

### Buttons
- **Primary:** native `.borderedProminent` tinted leaf; `.tint(.leafText)` app-wide.
- **Danger:** `.borderedProminent` tinted alert (flash and write flows).
- **Send now:** tint amber with ink type (`.controlSize(.small)` on Boot).
- **CPButtonStyle** (rail, Control Plane): 9 pt radius, 14x8 pt padding scaled by `s`, semibold system 14 pt, pressed = 80% fill, disabled = 35% opacity. Fills: lime/ink (enter Bergamota fastboot), amber/ink (send), alert/paper (write), console-line/paper (quiet).

### Panel
Surface fill, 1 pt rule stroke, 12 pt corners, 16 pt padding, 10 pt content spacing, optional header of a 11 pt semibold muted SF symbol plus `Label12`. The work area's only container; do not nest panels.

### Row
Key in callout muted, value in mono 12 pt right-aligned and selectable, optional check/minus mark (leaf-text/muted); 3 pt vertical padding with a 1 pt rule under it.

### Pill
Capsule in a Tone, caps mono 10.5 pt 800; horizontal padding 0.85x size, vertical 0.3x. Rail and sidebar-foot use 9.5 pt.

### Notice
A `.callout` line with a symbol (amber triangle by default), text in `text`, up to 4 lines, selectable.

### Empty Stage
Lime halftone card, 12 pt corners, 22 pt padding, max 440 wide: symbol, Archivo 22 title, callout explanation in ink (what is missing and how to get it).

### Console Pane
Ink background, paper mono 11.5 pt, 12 pt padding, follows the end; placeholder in console-muted.

### Control Plane Tile and Label
Raised #1d1d1b tile, console-line hairline, 14*s radius, 16*s padding, `CPLabel` mono 12*s 800 tracking 1.4*s console-muted. Sparklines and frequency bars draw in paper, lime or amber on the tile.

### Activity Banner
Band in the state's tone fill (lime = halftone ground), Archivo title 28 (50 big), mono detail at 82% opacity, progress capsule in the tone's `on` colour at 20% track. Same StateStep.

### Navigation
Native sidebar List with SF symbols and a badge for the pending boot count; toolbar buttons for Control Plane and show/hide rail (sidebar.right). No custom navigation chrome.

## Do's and Don'ts

### Do:
- **Do** keep the State Rail visible beside every page; when hidden, show the state pill in the sidebar foot.
- **Do** set page titles, state words and big numbers in Archivo 900 at 112% width through `BFont.display`; values, paths, logs and commands in `BFont.mono`.
- **Do** use the paired colours (`text`, `muted`, `leafText`, `alertText`, `amberText`, `ground`, `surface`, `rule`) on the work area so both appearances stay legible; use fixed colours only for the stage, console and Tones.
- **Do** give every state change the two-frame step and the unseen ink underline; never an eased fade.
- **Do** make anything that writes the phone alert red and gate it with a confirmation.
- **Do** put an empty state on the lime stage with what is missing and how to get it.
- **Do** keep Panels flat: surface fill, 1 pt rule, 12 pt corners.
- **Do** scale the Control Plane with `s`; its colours are the ink set, not the paired set.

### Don't:
- **Don't** put the phone's state in a card among cards, or hide it behind a section.
- **Don't** add shadows, blurs or gradients; depth is tone and hairline.
- **Don't** put lime marks on the lime rail; use ink.
- **Don't** use leaf, amber, alert or lime decoratively; they are state.
- **Don't** set display type in the system face or numbers in SF Pro.
- **Don't** nest Panels or wrap a Panel in a second container.
- **Don't** fade, slide or spring state changes; no eased animation on the state word.
- **Don't** hard-code light-only colours on the work area; they break the dark appearance.

## Not canonized

- `Label12` (mono caps tracked section labels) is recorded as the in-panel heading it is used as, not as a kicker above titles; future pages must not place it above `PageHeader` as an eyebrow.
- One-off literals not promoted to rules: `#1d1d1b` tile fill, `#8d8c85` quiet tone, and per-view sizes (`BootView`, `DashboardView`) that use SwiftUI system fonts for body copy.
