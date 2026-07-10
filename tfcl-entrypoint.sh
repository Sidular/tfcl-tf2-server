#!/bin/bash
#
# tfcl-entrypoint.sh
#
# Wraps the base ghcr.io/melkortf/tf2-competitive image's own entrypoint.sh
# with an ACTUAL TF2/SourceMod update step run at container *boot* time.
#
# WHY THIS EXISTS: the base entrypoint.sh launches srcds_run_64 with the
# `-autoupdate` flag, but that flag is a legacy pre-SteamPipe srcds option
# that does NOT perform a steamcmd validate/update on modern (SteamPipe-era)
# installs - it's a no-op carried over from the old WON/pre-2013 update
# mechanism. Confirmed via community reports, e.g.
# https://forums.alliedmods.net/showthread.php?t=340369: "the only thing the
# game does with the -autoupdate launch option is shut off the server the
# next time hibernation starts... it doesn't actually update anything
# itself." The base image's ACTUAL TF2 install only ever gets refreshed by
# its own install_tf2.sh script (steamcmd `app_update ${APP_ID}`), and that
# only runs ONCE - at Docker image *build* time (see amd64.Dockerfile /
# i386.Dockerfile's `RUN ... && $HOME/install_tf2.sh`) - never again at
# container boot.
#
# End result without this wrapper: pulling `ghcr.io/sidular/tfcl-tf2-server
# :latest` and starting a fresh container does NOT get you the current Steam
# build of TF2/SourceMod - it gets you whatever build was baked in at the
# last image rebuild (our CI only rebuilds on push to main / weekly cron /
# manual dispatch - see .github/workflows/build-push.yml), which can be
# stale by up to a week. This directly contradicts the "auto-update at boot
# for free" assumption baked into this repo's original README and into the
# webapp's vultr-relay.ts comments.
#
# Fix: re-run the base image's own install_tf2.sh (the exact same steamcmd
# `app_update` step it uses at build time - a fast no-op re-validate if
# already current, a real download if Valve has shipped an update) on every
# container start, BEFORE handing off to the base entrypoint.sh. This is the
# only thing that actually forces srcds to pick up an update automatically.
set -u

echo "[tfcl-updater] Checking Steam for TF2/SourceMod updates before launch..."
if "${HOME}/install_tf2.sh"; then
  echo "[tfcl-updater] Update check complete - TF2 install is current."
else
  # install_tf2.sh already retries steamcmd 3x internally on its own (see
  # that script) - if it still failed after that, don't crash-loop the
  # whole container over what's likely a transient steamcmd/network hiccup.
  # Log it loudly and boot with whatever TF2 build is already on disk rather
  # than leaving the server down entirely; the next reservation's fresh
  # container will simply retry.
  echo "[tfcl-updater] WARNING: steamcmd update check failed after retries - booting with the existing on-disk install instead of failing startup." >&2
fi

exec "${SERVER_DIR}/entrypoint.sh" "$@"
