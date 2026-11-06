# Dilated for Raycast

Development extension for the Developer ID build of [Dilated](https://dilated.app).
It calls the installed CLI directly, with argument arrays and an eight-second
response deadline. It does not change triggers, resume paused automation, use
closed-lid mode or run a background refresh.

- **Start Awake Session** starts an indefinite hold labeled Raycast.
- **Keep Awake for Minutes** starts a timed hold for a positive whole number of minutes.
- **Show Awake Status** reports active holds and the automation pause state.
- **Stop All Awake Sessions** performs Dilated's global Stop, ending every hold
  and pausing automation until Resume automation is chosen in Dilated.

Install the command line tool from Dilated Settings first. The extension defaults
to `~/.local/bin/dilated`, matching the app installer. A full custom executable
path can be entered in the extension's CLI Path preference. Paths containing
spaces and apostrophes work. A missing tool, paused automation or ended hold is
reported without retrying or creating a replacement hold.

Run `bash integrations/raycast/scripts/check.sh` from the repository root to
install the locked dependencies, test the CLI adapter, lint and build. Node 24 is
used in CI. The minimatch override pins the patched release for
[GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249); remove it
when the Raycast and lint dependencies accept the fixed version themselves.

For local development, run `npm --prefix integrations/raycast run dev`. Raycast
loads the four commands; stop the development process with Ctrl-C afterward.

This extension follows Raycast's [manifest](https://developers.raycast.com/information/manifest),
[command lifecycle](https://developers.raycast.com/information/lifecycle) and
[preferences](https://developers.raycast.com/api-reference/preferences) contracts.
The icon is extracted from Dilated's existing application artwork.

## Delivery status

The CLI fixture tests and extension build pass. Raycast dev mode was driven
against the verified beta.11 app with a separate temporary state directory:
Start created a Raycast hold, Status showed it, and Stop cleared it and persisted
automation pause. Timed arguments and paused/ended replies have fixture coverage;
the timed command's native error presentation has not been verified. Test app and
development processes exited. The local development extension was disabled and
its temporary CLI Path cleared; its uninstall popover did not complete removal.

Full lint currently fails its author lookup because `scttbnsn` is not a registered
Raycast profile. The app is signed out, so the actual publishing username needs
confirmation. No author validation is disabled. This is not submitted to the
Raycast Store.
