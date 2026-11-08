---
version: 1
slug: "bergamota"
primary_target: "Bergamota"
related_targets: []
---

# Bergamota main window (and Control Plane, sheets)

Scope: the whole macOS app, redesign (user, 2026-10-26: "redesign the entire app"). Mode: operate. Audience: the project owner on their Mac, plus agents acting through the CLI whose actions the window must make legible. Task: know the phone's state at a glance, see what is happening and what is next, act through gated controls. Constraints: native SwiftUI controls and navigation (NavigationSplitView, Forms, SF Symbols), macOS 26 target, behaviour and file API untouched. Performance gets its own sidebar section (user, 2026-10-26).

## Direction contract

THESIS: The phone never leaves the window. A lime state rail beside every section carries the phone's state, what is running and the next boot; it refuses the dashboard-of-cards where the phone's state is one card among many.

OWN-WORLD: paper work area (ink in dark appearance), ink type, a lime rail with the identity's 14 pt halftone dots and Newton's halftone rising from its foot into an ink console panel; leaf green primary actions, alert red for danger, ABL fastboot amber. Archivo 900 at 112% width for state words and page titles, JetBrains Mono for values and data, SF Pro for labels and controls.

STORY: A glance at the rail answers "what is the phone doing and what happens next"; the work area does the section's job; anything that writes the phone is red and asks first.

FIRST VIEWPORT: native sidebar (200 pt) | Dashboard on paper: Archivo title, Detection and Mac side panels side by side, the device panel below | rail (340 pt): state pill, the state in Archivo 52 pt, serial and since in mono, the activity line, Newton, and the ink panel at the foot with NEXT items and Send now.

FORM: The State Rail, second on my ordered list, dealt by the roll. seed:2ac5316d2c1ae29a. Signature move: a state change steps the rail's word and pill in two frames and holds an ink underline under the changed state word (lime would vanish on the lime rail) until the window is next brought forward; no eased fades.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
