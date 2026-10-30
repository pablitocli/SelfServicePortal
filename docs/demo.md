# Online demo

The online demo is a static build of the real web UI (`web/`) with sample data. A small script
(`demo/src/demo-mock.js`) answers the portal API (`/api/*`) inside the browser, so there is no server and
**no automation runs**: submitted requests go through a simulated job (queued, running with a live log,
succeeded with a sample result), approvals work, and the sample reports open in a viewer. Settings saved in
Admin are not stored, and sign-out, MFA enrollment and file downloads are disabled.

## Build

```bash
python3 tools/build_demo.py            # output: demo/dist/
python3 -m http.server -d demo/dist    # preview on http://localhost:8000
```

The build copies `web/assets`, inlines `portal.css`, takes the header markup from `web/index.html` and applies
two small patches to `app.js` (sign-out and report links). It fails if those patch targets change, so the
demo cannot silently drift from the UI; CI runs it on every push.

## Publish

| Host | How |
|---|---|
| Netlify (from Git) | *Add new site > Import an existing project*, pick the repository. `netlify.toml` already sets the build command and the `demo/dist` folder. |
| Netlify (manual) | Build locally and drag the `demo/dist` folder to *Deploy manually*. |
| GitHub Pages / any static host | Publish the contents of `demo/dist`. |

The demo sends `noindex` headers (`netlify.toml`) and ships a `robots.txt` that disallows crawling.

## Sample data

| Path | Content |
|---|---|
| `demo/src/data/capture.json` | API responses captured from a lab instance (catalog, admin views, lookups). No credentials. |
| `demo/src/data/branding.json` | Branding shown in the header (organization, colours). |
| `demo/src/reports/*.html` | Reports produced by the offline handler tests. |
| `demo/src/demo-mock.js` | Inventory for lookups, seeded requests, simulated job logs and results. |

To refresh the captured data after UI or catalog changes, run a lab instance and save the responses of the
endpoints listed in `capture.json` with the same keys.
