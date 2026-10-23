# Dilated contributor instructions

## Purpose

Dilated is a macOS 26 menu bar app that keeps the Mac awake: timed and indefinite
sessions, triggers, and closed-lid mode through a privileged helper. Apple
Silicon only, distributed as a notarized Developer ID build outside the Mac App
Store.

## Repository layout

- `.planning/` is ignored local planning and evidence. It is never published,
  and no build, test, or runtime may depend on it.

## Commits

Plain Conventional Commits, `<type>(scope): <description>`, no emoji, no AI
attribution trailer.
