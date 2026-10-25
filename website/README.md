# Dilated website

Gas Station is the main landing page: yellow and red packaging, Barlow Condensed
headings, and the selected pixel-eyes app icon. Barlow Condensed is fixed for the
selected direction. The masthead wordmark uses the same Barlow Condensed ExtraBold
Italic font file as the native app. The earlier sketchbook disclosure and footer link have been
removed; alternate layout source and icon assets remain local references.

This is buildless HTML, CSS, and JavaScript. Serve `dist/` from any static HTTP
server; it is the complete publication artifact. Assets and release-data paths
are relative, so the page can also be served from a subdirectory. Hosting and
domain setup are handled separately.

The current local review runs at `http://127.0.0.1:5173/`, serving `dist/`.
The review server has a two-hour deadline. Hosting is intended for Vercel after
local review; no Vercel deployment has been performed.

## Release availability

The checked-in page is in testing, with no app download. It doesn't claim that
closed-lid hardware acceptance, installation, or upgrade checks are complete.
The interactive timer is an illustration and doesn't change Mac power settings.

`app.mjs` fetches `./releases/latest.json` without caching. That file is intentionally
absent until an accepted public release is published. Missing, unreadable, or
invalid metadata leaves the testing copy and links in place. The hidden app
download has no `href` in the HTML.

The release pipeline owns this metadata. An accepted record must contain:

- `released: true`
- A semantic `version` and a positive integer `build` (string or number)
- `downloadURL`, a page-relative path or an HTTPS URL without embedded credentials
- `sha256`, the download's 64-character hexadecimal SHA-256 checksum
- `minimumMacOS`, a dotted version of 26.0 or later
- `architecture: "arm64"`
- Optional `prerelease` (boolean, default false) and `unverified` (array of strings, default empty). A prerelease relabels the download as a beta and lists the unverified checks in a caveat line.

Relative download paths resolve against the page URL, not the metadata file.
For example, `./releases/Dilated.dmg` works when the site is hosted at `/` or
`/dilated/`. Successful validation reveals the Mac download links, version,
build, system requirements, and a collapsible checksum. The publication pipeline
must verify the actual release artifact before publishing the record; the
frontend validates metadata and displays the checksum.

## Studies and assets

Direct study links remain available:

- `?concept=gas-station`: the selected yellow and red packaging direction
- `?concept=night`: a dark desktop and shift ledger, defaulting to Fraunces
- `?concept=field`: an editorial specimen plate, defaulting to Instrument Serif

Each layout keeps its chosen display face. The typeface picker has been removed;
old font query parameters and saved choices no longer override the design. The fonts are
self-hosted under the SIL Open Font License, with notices beside the files.
Barlow Condensed and Fraunces come from the official Google Fonts repository;
Instrument Sans, Instrument Serif, and JetBrains Mono use the Mouthtype site's
licensed assets.

- [Barlow Condensed source and license](https://github.com/google/fonts/tree/main/ofl/barlowcondensed)
- [Fraunces source and license](https://github.com/google/fonts/tree/main/ofl/fraunces)
- Font notices: `dist/assets/fonts/OFL-*.txt`

The original pixel eyes preserve the awake-frame geometry from
`design/menubar/glyphs.json`. The selected icon's canonical artwork is
`design/app-icon/gas-station.svg`; `swift design/app-icon/generate.swift`
regenerates the native icon and synchronizes its website SVG. The other SVGs
remain browser-only icon studies. Static hosting needs no app source or private
planning files.

## Verification

Run all behavior checks with `node --test website/tests/*.test.mjs` from the repo
root. Syntax checks are `node --check website/dist/app.mjs`,
`node --check website/dist/state.mjs`, and `node --check website/dist/release.mjs`.

The earlier page passed CUA Chrome checks on desktop and at 390px. All nine
layout/typeface combinations fit at 390px without horizontal overflow. Timer
start/stop, CLI copy feedback, expandable notes, study controls, and the icon SVG
target were exercised. In-memory HTTP fixtures verified that accepted release
data reveals all three download links, version, build, requirements, and checksum;
bad data preserves the testing state. No release metadata fixture is stored in
`dist/`, and no actual app download or public deployment was tested in this pass.
Reduced motion disables transitions and the tilted package hover.


## Current local review

The utility/hero labels, section numbers, sketchbook and its footer link were
removed. The phrase strip scrolls a seamless repeated group, pauses on hover or
focus, has an explicit pause/resume control, and stays still with reduced motion.
The release section presents the yellow icon on a dark Dock tray. The interactive
preview uses the exact lidded menu bar frame while stopped, and open eyes while
awake. Its closed/open state was exercised in local Chrome; seven Node checks
and JavaScript syntax checks pass. The replacement menu was checked at 390×844 and 320×844 in local Chrome. Current progress and outstanding work are in the private roadmap.

The preview card has since been replaced by a clickable sample menu bar and
native-style dropdown. Keep Awake starts indefinitely; Stop pauses automation;
preset durations preserve that pause until Resume. Display preference and Quit
are simulated locally. Outside click, Escape, arrow keys and focus return are
supported. Current verification is 11 passing Node tests plus desktop Chrome
interaction checks. Chrome checks at 390×844 and 320×844 confirmed the open and paused menus fit,
along with the facts label, terminal panel and Dock tray.
Awake Facts is white, and the command example is a dark terminal panel.
