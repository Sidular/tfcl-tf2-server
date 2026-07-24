# TFCL TF2 Competitive Server image
#
# Layers the TFCL-branded match/scrim configs, whitelist fallbacks, UGC league
# configs, the ETF2L Fours Passtime whitelist addition, a TFCL SourceMod
# plugin bundle, a boot-time TF2/SourceMod update check (see
# tfcl-entrypoint.sh below), and the maps.tfcleague.com map-download-source
# override on top of the upstream melkortf/tf2-competitive image (which
# already bakes in RGL.gg + ETF2L configs, TFTrue, demos.tf/logs.tf
# uploaders, mapdownloader, and everything else documented in
# https://github.com/melkortf/tf2-servers).
#
# This produces TWO published tags from the SAME Dockerfile, selected via the
# PLUGIN_DIR build arg (see .github/workflows/build-push.yml, which runs this
# build twice - once per tag):
#   :latest        (PLUGIN_DIR=plugins,             default) - self-service
#                   on-demand /servers page on play.tfcleague.com. Plugin
#                   bundle: tfclqol.smx + tfclupdater.smx + updater.smx.
#   :match-server  (PLUGIN_DIR=plugins-match-server) - TFCL Prime match
#                   bookings via /api/match-servers on play.tfcleague.com.
#                   SAME base bundle PLUS tfcl_matchserver.smx (ESEA-style
#                   ready-up/warmup/live/match-end reporting - see
#                   play.tfcleague.com's sourcemod-plugin/README.md for the
#                   full ConVar contract this plugin expects). The two
#                   plugin bundles are never mixed - tfcl_matchserver.smx is
#                   ONLY present in plugins-match-server/, never in plugins/.
# Both tags otherwise share 100% of the same configs/whitelists/entrypoint -
# there is no gameplay-format split here (that's still controlled entirely
# by which server.cfg/servercfgfile the game server is launched with),
# only a plugin-bundle split.
#
# This image is pulled fresh on every on-demand/match-booked Vultr server
# boot (see webapp's src/lib/vultr-relay.ts). NOTE: contrary to this repo's
# original assumption, the base image's `-autoupdate` srcds flag does NOT
# actually perform a steamcmd update on modern SteamPipe installs - see
# tfcl-entrypoint.sh's comment for the full explanation and citation. The
# ENTRYPOINT override below is what actually gives us "auto-update at boot".
FROM ghcr.io/melkortf/tf2-competitive:latest

ARG PLUGIN_DIR=plugins

# --- TFCL / UGC / ETF2L format configs + whitelist fallbacks --------------
# tfcl_*.cfg, tfcl_whitelist_*.txt, emptymapcycle.txt (from
# Sidular/TFCL-Server-Config), ugc_*.cfg + item_whitelist_ugc_*.txt (from
# quanticc/ugc-configs, mirrored in Sidular/TFCL-Server-Docker), and
# etf2l_pt_whitelist.txt (from ETF2L/gameserver-configs). RGL.gg and the rest
# of the ETF2L set are already baked into the base image - nothing to add.
# Identical for both tags.
COPY cfg/ /home/tf2/server/tf/cfg/

# --- TFCL SourceMod plugin bundle ------------------------------------------
# Selected via PLUGIN_DIR (see header comment above). Both plugins/ and
# plugins-match-server/ ship the same base three files:
#   tfclqol.smx - QoL tweaks (tfcl_cast slot-lock, etc.), compiled from
#     Sidular/TFCL-Server-Config's tfclqol.sp with SourceMod 1.11's spcomp.
#   tfclupdater.smx - self-updater that syncs cfg/whitelist changes from
#     Sidular/server-resources-updater (branch: updater) every 6h or via
#     RCON sm_tfcl_cfgsync, without needing a rebuild for cfg-only changes.
#   updater.smx - the base SourceMod "Updater" plugin tfclupdater.smx
#     depends on (not shipped by the base image itself).
# plugins-match-server/ additionally ships tfcl_matchserver.smx - see the
# header comment above.
COPY ${PLUGIN_DIR}/*.smx /home/tf2/server/tf/addons/sourcemod/plugins/

# --- Map download source override ------------------------------------------
# sm_map_download_base defaults to https://fastdl.serveme.tf/maps in the base
# image's stock sourcemod.cfg; TFCL serves its own map mirror instead. This
# MUST be appended (not COPYed over the base file), since the base
# sourcemod.cfg already carries the stock SourceMod core cvars (sm_show_activity,
# sm_menu_sounds, etc.) that need to stay intact.
COPY sourcemod-overrides/sourcemod.cfg /home/tf2/sourcemod-override.cfg
RUN cat /home/tf2/sourcemod-override.cfg >> /home/tf2/server/tf/cfg/sourcemod/sourcemod.cfg && \
    rm /home/tf2/sourcemod-override.cfg

# Ownership: the base image's plugin/cfg files are chowned to the "tf2" user
# (see melkortf/tf2-servers tf2-competitive/Dockerfile's `COPY --chown=tf2`);
# match that here so file perms are consistent for anything the server or
# its plugins write back to these paths at runtime.
USER root
RUN chown -R tf2:tf2 /home/tf2/server/tf/cfg /home/tf2/server/tf/addons/sourcemod/plugins
USER tf2

# --- Boot-time TF2/SourceMod auto-update ------------------------------------
# Wraps the base image's entrypoint.sh with a real steamcmd update check run
# on every container start (the base image's `-autoupdate` srcds flag alone
# does NOT do this on modern SteamPipe installs - see tfcl-entrypoint.sh for
# the full explanation). install_tf2.sh (steamcmd + retries) and the
# HOME/SERVER_DIR env vars it needs are already present in the base image.
COPY --chown=tf2:tf2 --chmod=755 tfcl-entrypoint.sh /home/tf2/tfcl-entrypoint.sh
ENTRYPOINT ["/home/tf2/tfcl-entrypoint.sh"]
CMD ["+sv_pure", "1", "+map", "cp_badlands", "+maxplayers", "24"]

# Widen the base image's HEALTHCHECK start-period (20s) - a real steamcmd
# update can take well over 20s if Valve has actually shipped a new TF2
# build (vs. the near-instant no-op re-validate on the common case where
# nothing changed), so the tighter base-image grace period would otherwise
# flap the container to "unhealthy" during a real update download. This is
# purely cosmetic for `docker ps`/`docker inspect` - nothing in vultr-relay.ts
# or the webapp's RCON-based readiness polling depends on Docker health
# status, so this doesn't change actual boot/readiness behavior.
HEALTHCHECK --interval=30s --timeout=30s --start-period=5m --retries=3 CMD [ "./healthcheck.sh" ]
