# TFCL TF2 Competitive Server image
#
# Layers the TFCL-branded match/scrim configs, whitelist fallbacks, UGC league
# configs, the ETF2L Fours Passtime whitelist addition, the TFCL SourceMod
# plugin bundle (QoL tweaks + self-updater), and the maps.tfcleague.com
# map-download-source override on top of the upstream melkortf/tf2-competitive
# image (which already bakes in RGL.gg + ETF2L configs, TFTrue, demos.tf/logs.tf
# uploaders, mapdownloader, and everything else documented in
# https://github.com/melkortf/tf2-servers).
#
# This image is pulled fresh on every on-demand Vultr server boot (see
# webapp's src/lib/vultr-relay.ts), so the base image's built-in `-autoupdate`
# steamcmd flag (baked into its entrypoint.sh) re-validates/updates the TF2
# install on every container start - this is what gives us "auto-update at
# boot" for free, without any extra logic in this Dockerfile or the boot
# script.
FROM ghcr.io/melkortf/tf2-competitive:latest

# --- TFCL / UGC / ETF2L format configs + whitelist fallbacks --------------
# tfcl_*.cfg, tfcl_whitelist_*.txt, emptymapcycle.txt (from
# Sidular/TFCL-Server-Config), ugc_*.cfg + item_whitelist_ugc_*.txt (from
# quanticc/ugc-configs, mirrored in Sidular/TFCL-Server-Docker), and
# etf2l_pt_whitelist.txt (from ETF2L/gameserver-configs). RGL.gg and the rest
# of the ETF2L set are already baked into the base image - nothing to add.
COPY cfg/ /home/tf2/server/tf/cfg/

# --- TFCL SourceMod plugin bundle ------------------------------------------
# tfclqol.smx - QoL tweaks (tfcl_cast slot-lock, etc.), compiled from
#   Sidular/TFCL-Server-Config's tfclqol.sp with SourceMod 1.11's spcomp.
# tfclupdater.smx - self-updater that syncs cfg/whitelist changes from
#   Sidular/server-resources-updater (branch: updater) every 6h or via RCON
#   sm_tfcl_cfgsync, without needing a snapshot/image rebuild for cfg-only
#   changes. Depends on the "Updater" SourceMod extension, which is already
#   present in the base image (addons/sourcemod/extensions/updater.ext.so).
COPY plugins/*.smx /home/tf2/server/tf/addons/sourcemod/plugins/

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
