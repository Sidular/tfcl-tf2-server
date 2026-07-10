# tfcl-tf2-server

Custom TF2 Competitive server image for TFCL (TF2 Competitive League)'s
on-demand Vultr PUG/tournament servers.

## What this is

`FROM ghcr.io/melkortf/tf2-competitive:latest`, with TFCL's branded
configs/whitelists, SourceMod plugin bundle, and map-download-source override
layered on top. Published to `ghcr.io/sidular/tfcl-tf2-server`.

This replaces TFCL's old workflow of provisioning on-demand Vultr servers
from a 50GB pre-baked disk snapshot (see the webapp's `src/lib/vultr-relay.ts`
and `VULTR_SNAPSHOT_ID`). Instead, on-demand servers now boot from a stock
Vultr "Docker on Ubuntu" marketplace image via a small cloud-init `user_data`
script that just runs `docker pull` + `docker run` against this image.

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
- **`plugins/`** - the TFCL SourceMod plugin bundle:
  - `tfclqol.smx` - QoL tweaks, compiled from `tfclqol.sp` source.
  - `tfclupdater.smx` - self-updater that syncs cfg/whitelist changes from
    [Sidular/server-resources-updater](https://github.com/Sidular/server-resources-updater)
    (branch: `updater`) periodically or via RCON, without requiring an image
    rebuild for cfg-only changes.
  - `updater.smx` - the base SourceMod "Updater" plugin (by GoD-Tony/Tk) that
    `tfclupdater.smx` depends on. **Not shipped by the base image** (which
    only ships the `updater.ext.so` extension + its include) - compiled from
    source here to fill that gap.
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

## Building locally

```bash
docker build -t tfcl-tf2-server:test .
docker run -d --name tfcl-test --network host \
  -e SERVER_HOSTNAME="TFCL Server" \
  -e RCON_PASSWORD=changeme \
  -e SERVER_PASSWORD= \
  -e SERVER_TOKEN= \
  tfcl-tf2-server:test \
  +map cp_process_f12 +maxplayers 24
```

## CI

`.github/workflows/build-push.yml` builds and pushes to
`ghcr.io/sidular/tfcl-tf2-server:latest` on every push to `main`, on a weekly
schedule (to pick up upstream base-image/plugin changes), and on manual
dispatch. Day-to-day TF2/SourceMod updates don't require a rebuild at all -
they're picked up automatically at container boot via `tfcl-entrypoint.sh`
(see "Auto-update at boot" above) - **not** via the base image's
`-autoupdate` flag, which doesn't actually do this.
