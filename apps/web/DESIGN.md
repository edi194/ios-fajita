# Design

The visual system of bergamota.zesmoi.com.br, as built (2026-10-24). Approved by the user over several preview
rounds; the reference they pinned was a 1960s magazine pop-collage (halftone ground, giant white numerals behind
a black-and-white halftone cutout).

## World

A printed collage. The ground is a flat lime field with a halftone dot screen; the subject is a real photograph
or painting cut out along its edge and printed in black-and-white halftone; huge white numerals sit behind the
subject, tucked under its silhouette on both sides. Working surfaces (sheets, panels) are off-white paper laid on
the ground with a soft drop shadow.

## Tokens (`src/styles/base.css`)

| Token | Value | Use |
| --- | --- | --- |
| `--ground` | `#d7e98a` | page ground |
| `--ground-dot` | `#c6dc72` | halftone screen: 1.6 px dots on a 7 px grid (`--halftone`) |
| `--paper` | `#f4f3ec` | sheets, panels, the cutout's paper white |
| `--paper-line` | `#d8d6cb` | rules inside sheets |
| `--ink` | `#161616` | text, the cutout's ink, secondary buttons |
| `--ink-soft` / `--ink-faint` | `#4a4a42` / `#8a897e` | secondary text / disabled |
| `--white` | `#ffffff` | giant numerals, step numbers |
| `--leaf` / `--leaf-deep` | `#1a5933` / `#0f3a20` | the one action colour: primary buttons, active path, progress |
| `--warn` | `#c23a1a` | the destructive confirm (write a partition) |
| `--lift` | `0 30px 60px -30px rgba(22,22,22,.45)` | paper on the ground |

## Type

- Display and UI: **Archivo** variable (self-hosted, `@fontsource-variable/archivo`, wdth + wght axes). Headlines
  850, giant numerals 900 at `font-stretch: 112%`, tracking -0.03 to -0.04em.
- Data, code, protocol log: **JetBrains Mono** variable.

## Signature elements

- **Giant numerals**: the current iOS generation ("2" "6") at 600+ px behind the portrait. `src/lib/hug.ts`
  reads the cutout's alpha in the numerals' band and places them 7% inside the silhouette on both sides.
- **Step rail**: the flasher's steps as giant white numerals with the step name beside them; done steps are
  struck through, upcoming ones are faded.
- **Progress numeral**: while flashing, the percentage is a giant white numeral in the corner.
- **Committed choice**: the selected partition is a solid frame on white; the alternatives stay dashed.

## Identity

Isaac Newton, after Godfrey Kneller (1689, public domain): `public/img/newton.webp` (cutout, transparent) and
the favicon (`public/favicon.svg`, head crop on the lime screen in a rounded square). No colour on the figure.

## Rules

- One action colour (leaf). Red only for the confirm that writes a partition.
- No Apple imagery or logos, no iPhone renders; no third-party trademarks as decoration.
- Imagery is a real public-domain photograph or painting, cut out from its own alpha, never a geometric mask.
