# Vendored browser modules

The site has no build step, so these ES modules are copied from their npm packages unchanged. Neither file has bare-specifier imports or dynamic `import()`, so a browser loads them as they are.

| File | Source package | Version | Source file | sha256 |
| --- | --- | --- | --- | --- |
| `posthog-js-1.449.2.mjs` | `posthog-js` | 1.449.2 | `dist/module.slim.no-external.js` | `576c2c662b6729437bef4a5e43e81dcf96d84fd7cc0da0fc325d86db03a30d03` |
| `web-vitals-6.2.1.mjs` | `web-vitals` | 6.2.1 | `dist/web-vitals.js` | `bdf421fcbd62c2572c8b09096572262496e2bc54289bcae80c9fe94f6ca6769d` |

The PostHog build is the slim, no-external variant: it has no session recording, surveys or other lazy-loaded extensions, and it never injects remote scripts.

Licenses: `posthog-js-LICENSE` and `web-vitals-LICENSE`, copied from the packages.

To update, run `npm pack <package>@<version>` in an empty directory outside the repo, copy the source file over, and update the version, name and hash here and in `analytics/client.mjs`.
