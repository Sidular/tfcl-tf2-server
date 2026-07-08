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
- **Auto-update**: the base `melkortf/tf2-competitive` image's `entrypoint.sh`
  runs steamcmd with `-autoupdate` on every container start, so pulling
  `:latest` and starting a fresh container gets the current TF2/SourceMod
  build for free - no custom update logic needed, unlike the snapshot
  approach where the disk image itself could silently drift out of date.

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
schedule (to pick up upstream base-image changes), and on manual dispatch.
Day-to-day TF2/SourceMod updates don't require a rebuild at all - they're
picked up automatically at container boot via `-autoupdate`.
