#!/usr/bin/env bash
# Shared LM Studio home resolver — sourced by install / remove / make-stub-* so they
# ALL target the SAME home the running app scans (honours ~/.lmstudio-home-pointer).
# Sets LMSTUDIO_HOME. Read-only; never writes.
#
# Usage:  source scripts/lmstudio-home.sh   (then use $LMSTUDIO_HOME)
resolve_lmstudio_home() {
  local home_dir="${HOME}"
  if [ -f "${home_dir}/.lmstudio-home-pointer" ]; then
    LMSTUDIO_HOME="$(tr -d '[:space:]' < "${home_dir}/.lmstudio-home-pointer")"
  else
    LMSTUDIO_HOME="${home_dir}/.lmstudio"
  fi
  export LMSTUDIO_HOME
}
resolve_lmstudio_home
