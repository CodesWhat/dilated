# Dilated website studies

Gas Station is the selected direction: yellow and red packaging, Barlow
Condensed headings, and the pixel eyes. The font switcher and other studies
remain available for comparison.

A buildless, self-contained design study. Serve `dist/` from any static HTTP
server. `dist/` is also the publication artifact; no installation or build is
needed.

From the repo root, `python3 -m http.server 5173 --bind 127.0.0.1 --directory website/dist`
serves a local preview at `http://127.0.0.1:5173`. Stop the foreground server
with Ctrl-C when finished.

- `?concept=gas-station`: Gas Station, yellow and red retail packaging, with Barlow
  Condensed. The product box is original artwork, not a replica of a retail brand.
- `?concept=night`: Night shift, a dark panoramic desktop and shift ledger, with
  Fraunces.
- `?concept=field`: Field notes, an editorial specimen plate and marginal notes,
  with Instrument Serif.

The font control swaps all display headings. Each direction remembers its own
font choice locally. Links include `concept` and `font` when changed. All text
faces and fonts are self-hosted under the SIL Open Font License, included beside
the font files. Barlow Condensed and Fraunces come from the official Google Fonts
repository. Instrument Sans, Instrument Serif, and JetBrains Mono reuse the
Mouthtype website's licensed font assets.

- [Barlow Condensed source and license](https://github.com/google/fonts/tree/main/ofl/barlowcondensed)
- [Fraunces source and license](https://github.com/google/fonts/tree/main/ofl/fraunces)
- Font notices are included in `dist/assets/fonts/OFL-*.txt`.

The 16-pixel eyes use the existing Dilated bug-eyes geometry. Three exportable
1024-viewBox SVG app-icon studies live under `dist/assets/icon-*.svg`. The Gas Station treatment
is the native app icon. Its canonical artwork is `design/app-icon/gas-station.svg`;
regenerate the `.icns` with `swift design/app-icon/generate.swift`.
The SVG paths preserve the awake-frame geometry from
`design/menubar/glyphs.json`; the package, backgrounds, and icon treatments are
original Dilated compositions. Static hosting uses the checked-in assets and
doesn't need the app source or any private planning files.

The awake timer is an interactive illustration. It doesn't alter Mac power
settings. Availability copy reflects the M1 development preview. There is no
public-download button or release claim.
The GitHub destination is labeled as a private preview repository. The CLI
notes are included on the page so the site doesn't depend on an unpublished
development branch.

Run behavior checks with `node --test website/tests/state.test.mjs` from the repo
root. Run `node --check website/dist/app.mjs` for a syntax check.

The live Chrome check covered all three directions on desktop and at 390px,
all nine direction/typeface combinations at 390px without horizontal overflow,
the preview timer, font selection, icon selection and SVG download target,
clipboard feedback, and expandable CLI notes. The browser reported no errors or
warnings. Reduced motion disables transitions and the tilted package hover.
