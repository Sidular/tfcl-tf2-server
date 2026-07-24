# tfcl-tf2-server

Custom TF2 Competitive server image for TFCL (TF2 Competitive League)'s
Vultr-hosted PUG/tournament/match servers.

## What this is

`FROM ghcr.io/melkortf/tf2-competitive:latest`, with TFCL's branded
configs/whitelists, a SourceMod plugin bundle, and a map-download-source
override layered on top. Published to `ghcr.io/sidular/tfcl-tf2-server` as
**two tags built from the same Dockerfile**:

| Tag | Used by | Plugin bundle |
| --- | --- | --- |
| `:latest` | play.tfcleague.com's self-service on-demand `/servers` page | `tfclqol.smx` + `tfclupdater.smx` + `updater.smx` |
| `:match-server` | play.tfcleague.com's TFCL Prime match-booking API (`/api/match-servers`) - replaces serveme.tf for these bookings | same three, **plus** `tfcl_matchserver.smx` (ESEA-style ready-up/warmup/live + match-end reporting) |

Both tags share 100% of the same `cfg/`, whitelists, map-download override,
and boot-time update entrypoint - the ONLY difference is which plugin bundle
directory gets baked in (`plugins/` vs `plugins-match-server/`, selected via
the `PLUGIN_DIR` build arg - see the Dockerfile's header comment and
`.github/workflows/build-push.yml`, which builds both tags on every push).
`tfcl_matchserver.smx`'s full ConVar contract and source
(`tfcl_matchserver.sp`) live in play.tfcleague.com's own repo under
`sourcemod-plugin/` - this repo only carries the **compiled** `.smx`, kept in
sync by hand whenever that source changes (see "Updating the plugin bundle"
below).

This replaces TFCL's old workflow of provisioning on-demand Vultr servers
from a 50GB pre-baked disk snapshot (see the webapp's `src/lib/vultr-relay.ts`
and `VULTR_SNAPSHOT_ID`). Instead, servers now boot from a stock Vultr
"Docker on Ubuntu" marketplace image via a small cloud-init `user_data`
script that just runs `docker pull` + `docker run` against the appropriate
tag for the booking type.

### Why

- **Speed**: pulling this image's compressed ~2GB layers takes ~50-80s
  end-to-end, vs. the old snapshot's documented 5-30 minute disk-clone
  restore - a 4-20x speedup, confirmed via live testing across three
  separate Vultr instances/locations.
- **Auto-update**: unlike the old snapshot approach (where the disk image
  itself could silently drift out of date with no update path at all short
  of re-baking the whole snapshot), every container boot now runs an actual
  steamcmd `app_update` check before launching srcds - see "Auto-update at
  boot" below for exactly how and why.

## What's layered on top of the base image

- **`cfg/`** - TFCL match/scrim/koth/stopwatch configs and whitelists (from
  [Sidular/TFCL-Server-Config](https://github.com/Sidular/TFCL-Server-Config)),
  UGC league configs + whitelists, and the ETF2L Fours Passtime whitelist
  addition. (RGL.gg and the rest of the ETF2L set are already baked into the
  base image - not duplicated here.)
- **`plugins/`** - the `:latest` (on-demand `/servers`) SourceMod plugin
  bundle:
  - `tfclqol.smx` - QoL tweaks, compiled from `tfclqol.sp` source.
  - `tfclupdater.smx` - self-updater that syncs cfg/whitelist changes from
    [Sidular/server-resources-updater](https://github.com/Sidular/server-resources-updater)
    (branch: `updater`) periodically or via RCON, without requiring an image
    rebuild for cfg-only changes.
  - `updater.smx` - the base SourceMod "Updater" plugin (by GoD-Tony/Tk) that
    `tfclupdater.smx` depends on. **Not shipped by the base image** (which
    only ships the `updater.ext.so` extension + its include) - compiled from
    source here to fill that gap.
- **`plugins-match-server/`** - the `:match-server` (TFCL Prime bookings)
  SourceMod plugin bundle: the SAME `tfclqol.smx` + `tfclupdater.smx` +
  `updater.smx` as `plugins/`, plus `tfcl_matchserver.smx` - ESEA-style
  `.ready`/`.unready`/`.notready`, roster/subs handling, a configurable
  "lo3" (live-on-three) warmup restart sequence, a "MATCH LIVE" center-text
  display, match-end detection, and a 1-hour no-show timeout with staged
  chat warnings. Source (`tfcl_matchserver.sp`) and the full ConVar
  contract this plugin expects from the Worker live in
  play.tfcleague.com's own repo under `sourcemod-plugin/` - see that repo's
  `sourcemod-plugin/README.md` for the complete build/integration/testing
  writeup. This directory only carries the compiled `.smx` (see "Updating
  the plugin bundle" below for how to re-sync it).
- **`sourcemod-overrides/sourcemod.cfg`** - appended onto the base image's
  existing `sourcemod.cfg` to override `sm_map_download_base` from the
  upstream default (`fastdl.serveme.tf`) to `https://maps.tfcleague.com`, so
  the `mapdownloader` plugin fetches any non-baked map (which is almost all
  of them - the base image only ships `cp_badlands` + a few `mge_*` maps
  locally) from TFCL's own map mirror.
- **`tfcl-entrypoint.sh`** - overrides the base image's `ENTRYPOINT` to run a
  real steamcmd update check before every launch. See "Auto-update at boot"
  below for why this is necessary.

## Auto-update at boot

**This is not handled by the base image alone.** The base
`melkortf/tf2-competitive` image launches srcds with a `-autoupdate` flag,
but that flag is a legacy pre-SteamPipe srcds option that does **not**
actually perform a steamcmd validate/update on modern installs - it's a
no-op left over from the old WON/pre-2013 update mechanism (confirmed via
community reports, e.g.
[this AlliedModders thread](https://forums.alliedmods.net/showthread.php?t=340369):
"the only thing the game does with the `-autoupdate` launch option is shut
off the server the next time hibernation starts... it doesn't actually
update anything itself"). The base image's *actual* TF2 install only ever
gets refreshed by its own `install_tf2.sh` script (`steamcmd
+login anonymous +app_update ${APP_ID}`), and that only runs **once**, at
Docker image *build* time (baked into `amd64.Dockerfile`/`i386.Dockerfile`) -
never again at container boot.

Without anything extra, that means pulling `:latest` and starting a fresh
container gets you whatever TF2/SourceMod build was current the last time
this image was rebuilt (CI rebuilds on push to `main`, weekly cron, and
manual dispatch - see `.github/workflows/build-push.yml`), which can silently
drift up to a week stale between rebuilds - not the current Steam build.

**Fix**: `tfcl-entrypoint.sh` overrides the base image's `ENTRYPOINT` and
re-runs that exact same `install_tf2.sh` steamcmd step on every container
start, before handing off to the base image's own `entrypoint.sh`. This is a
fast no-op re-validate in the common case (nothing changed since the image
was built) and a real download in the case where Valve has shipped an update
since then - giving genuine "auto-update at boot," which the `-autoupdate`
flag alone never provided.

## Boot-time configuration

Server identity/secrets are passed as plain Docker env vars at `docker run`
time; the base image's `entrypoint.sh` turns them into `server.cfg` via its
own `envsubst`-based templating - no custom scripting needed on top:

| Env var             | Purpose                                   |
|----------------------|--------------------------------------------|
| `SERVER_HOSTNAME`     | idle/default hostname (`TFCL Server`)     |
| `SERVER_PASSWORD`     | `sv_password`                             |
| `RCON_PASSWORD`       | `rcon_password`                           |
| `SERVER_TOKEN`        | GSLT -> `+sv_setsteamaccount` on launch    |
| `DOWNLOAD_URL`        | `sv_downloadurl` (client-facing FastDL)   |
| `DEMOS_TF_APIKEY`     | demos.tf auto-upload API key              |
| `LOGS_TF_APIKEY`      | logs.tf auto-upload API key               |

Default idle state matches the previous snapshot setup: hostname
`TFCL Server`, default map `cp_process_f12`, `sv_pure 1`, `maxplayers 24`.

## Updating the plugin bundle

Both `plugins/` and `plugins-match-server/` carry **compiled** `.smx`
files only - there's no SourcePawn source or `spcomp` build step in this
repo. To pick up a plugin change:

1. Compile the updated `.sp` -> `.smx` in its source-of-truth repo:
   - `tfclqol.sp` / `tfclupdater.sp` - `Sidular/TFCL-Server-Config`.
   - `tfcl_matchserver.sp` (and `tfcl_reservation.sp`, once that one is
     wired in here too) - play.tfcleague.com's own repo, under
     `sourcemod-plugin/` (see that directory's README.md for the exact
     `spcomp` invocation and include paths).
2. Copy the resulting `.smx` into **both** `plugins/` and
   `plugins-match-server/` if it's one of the three shared files
   (`tfclqol.smx`/`tfclupdater.smx`/`updater.smx`), or into
   **`plugins-match-server/` only** if it's `tfcl_matchserver.smx` (this
   file must never be copied into `plugins/` - the two bundles are
   deliberately not identical).
3. Commit + push to `main` - CI rebuilds and republishes both tags
   automatically (see "CI" below).

## Building locally

```bash
# :latest (on-demand /servers) - PLUGIN_DIR defaults to plugins/, no build-arg needed:
docker build -t tfcl-tf2-server:test .

# :match-server (TFCL Prime bookings) - pass PLUGIN_DIR explicitly:
docker build --build-arg PLUGIN_DIR=plugins-match-server -t tfcl-tf2-server:test-match .

docker run -d --name tfcl-test --network host \
  -e SERVER_HOSTNAME="TFCL Server" \
  -e RCON_PASSWORD=changeme \
  -e SERVER_PASSWORD= \
  -e SERVER_TOKEN= \
  tfcl-tf2-server:test \
  +map cp_process_f12 +maxplayers 24
```

## CI

`.github/workflows/build-push.yml` runs the build TWICE on every push to
`main`, on a weekly schedule (to pick up upstream base-image/plugin
changes), and on manual dispatch - once with the default `PLUGIN_DIR`
(publishing `ghcr.io/sidular/tfcl-tf2-server:latest` +
`:${{ github.sha }}`), and once with `PLUGIN_DIR=plugins-match-server`
(publishing `:match-server` + `:match-server-${{ github.sha }}`). Both
runs share the same `cfg/`/whitelists/entrypoint - only the plugin bundle
COPY differs (see the Dockerfile's header comment). Day-to-day
TF2/SourceMod updates don't require a rebuild at all for either tag -
they're picked up automatically at container boot via
`tfcl-entrypoint.sh` (see "Auto-update at boot" above) - **not** via the
base image's `-autoupdate` flag, which doesn't actually do this.
