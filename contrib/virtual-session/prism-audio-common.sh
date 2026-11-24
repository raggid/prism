#!/usr/bin/env bash
# Shared, idempotent PulseAudio/PipeWire lifecycle helpers for Prism sessions.
#
# This file is sourced by capture-mode scripts. It deliberately parses state
# files as data instead of sourcing them as shell code.

prism_audio_state_get() {
  local file="${1:?state file required}"
  local key="${2:?state key required}"

  case "$key" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  awk -v wanted="$key" '
    {
      separator = index($0, "=")
      if (separator < 2) {
        invalid = 1
        next
      }
      key = substr($0, 1, separator - 1)
      if (key !~ /^[A-Za-z0-9_]+$/ || ++seen[key] != 1) {
        invalid = 1
        next
      }
      if (key == wanted) {
        value = substr($0, separator + 1)
        found = 1
      }
    }
    END {
      if (invalid || !found) exit 1
      print value
    }
  ' "$file"
}

prism_audio_atomic_write() {
  local target="${1:?state path required}"
  local temporary="${target}.tmp.$$"

  umask 077
  if ! cat > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$target"
}

prism_audio_module_exists() {
  local module="${1:?module id required}"
  local modules

  modules="$(pactl list short modules 2>/dev/null)" || return 2
  printf '%s\n' "$modules" |
    awk -v wanted="$module" '$1 == wanted {found=1} END {exit !found}'
}

## @brief Test whether an exact PulseAudio or PipeWire sink is available.
##
## @param sink Exact sink name.
## @return Zero when pactl reports the sink.
prism_audio_sink_available() {
  local sink="${1:-}"

  [ -n "$sink" ] || return 1
  pactl list short sinks 2>/dev/null |
    awk -v wanted="$sink" '$2 == wanted {found=1} END {exit !found}'
}

## @brief Test whether a sink belongs to Prism (never a real output).
##
## @param sink Exact sink name.
## @return Zero for Prism capture/session sinks.
prism_audio_is_prism_sink() {
  case "${1:-}" in
    prism-stream | prism-headless | prism-virtual | sink-prism-*) return 0 ;;
  esac
  return 1
}

## @brief Print the first real (ALSA/Bluetooth) output sink, if any.
prism_audio_first_real_sink() {
  pactl list short sinks 2>/dev/null |
    awk '$2 ~ /^(alsa_output|bluez_output)\./ {print $2; exit}'
}

## @brief Identify the desktop's real output at stream start.
##
## The current default is used unless it is a Prism sink (e.g. left over from
## an earlier session or switched by Prism at stream start); then the
## configured prism_default_sink, then the first real output.
## @return Zero and the sink on stdout, or nonzero when none exists.
prism_audio_physical_sink() {
  local current preferred

  current="$(pactl get-default-sink 2>/dev/null || true)"
  if [ -n "$current" ] && ! prism_audio_is_prism_sink "$current" &&
    prism_audio_sink_available "$current"; then
    printf '%s\n' "$current"
    return 0
  fi
  preferred="$(sed -n 's/^prism_default_sink *= *//p' \
    "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
  if [ -n "$preferred" ] && ! prism_audio_is_prism_sink "$preferred" &&
    prism_audio_sink_available "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi
  current="$(prism_audio_first_real_sink)"
  [ -n "$current" ] || return 1
  printf '%s\n' "$current"
}

## @brief Select an available desktop sink without choosing a Prism sink.
##
## @param preferred User-configured preferred sink.
## @param fallback Sink recorded before the capture session.
## @return Zero and the selected sink on stdout, or nonzero when none exists.
prism_audio_choose_restore_sink() {
  local preferred="${1:-}"
  local fallback="${2:-}"
  local current

  # Never "restore" to a Prism sink: once recorded as the physical output it
  # would be carried from session to session.
  if ! prism_audio_is_prism_sink "$preferred" && prism_audio_sink_available "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi
  if ! prism_audio_is_prism_sink "$fallback" && prism_audio_sink_available "$fallback"; then
    printf '%s\n' "$fallback"
    return 0
  fi

  current="$(pactl get-default-sink 2>/dev/null || true)"
  if [ -n "$current" ] && ! prism_audio_is_prism_sink "$current" &&
    prism_audio_sink_available "$current"; then
    printf '%s\n' "$current"
    return 0
  fi
  # Last resort: the first real output, so the desktop is not left on a
  # Prism sink after the stream.
  current="$(prism_audio_first_real_sink)"
  [ -n "$current" ] || return 1
  printf '%s\n' "$current"
}

## @brief Restore an available desktop sink with a bounded retry.
##
## @param sink Exact available sink name.
## @return Zero after verification, otherwise nonzero after one second.
prism_restore_default_sink() {
  local sink="${1:-}"

  [ -n "$sink" ] || return 0
  echo "restoring default sink: $sink"
  for _ in $(seq 1 10); do
    if prism_audio_sink_available "$sink"; then
      pactl set-default-sink "$sink" >/dev/null 2>&1 || true
      [ "$(pactl get-default-sink 2>/dev/null || true)" = "$sink" ] && return 0
    fi
    sleep 0.1
  done
  echo "WARN: could not restore default sink $sink" >&2
  return 1
}

prism_unload_module() {
  local module="${1:-}"
  local exists_status

  case "$module" in
    '' | *[!0-9]*) return 0 ;;
  esac
  prism_audio_module_exists "$module" || {
    exists_status=$?
    if [ "$exists_status" -eq 1 ]; then
      return 0
    fi
    echo "ERROR: could not inspect audio module $module" >&2
    return 1
  }
  pactl unload-module "$module" >/dev/null 2>&1 || return 1
  if prism_audio_module_exists "$module"; then
    echo "ERROR: audio module $module remains loaded" >&2
    return 1
  else
    exists_status=$?
    [ "$exists_status" -eq 1 ] || return 1
  fi
}

prism_unload_named_sink_modules() {
  local sink="${1:?sink required}" listing
  local module failed=0
  local -a modules=()

  if ! listing="$(pactl list short modules 2>/dev/null)"; then
    echo "ERROR: could not inspect null-sink modules for $sink" >&2
    return 1
  fi
  mapfile -t modules < <(
    printf '%s\n' "$listing" |
      awk -v token="sink_name=$sink" '
        $2 == "module-null-sink" {
          for (i = 3; i <= NF; ++i) {
            if ($i == token) {
              print $1
              break
            }
          }
        }
      '
  )
  for module in "${modules[@]}"; do
    prism_unload_module "$module" || failed=1
  done
  return "$failed"
}

prism_unload_loopback_modules() {
  local source="${1:-}" listing
  local sink="${2:?destination sink required}"
  local module failed=0
  local -a modules=()

  if ! listing="$(pactl list short modules 2>/dev/null)"; then
    echo "ERROR: could not inspect loopbacks routed to $sink" >&2
    return 1
  fi
  mapfile -t modules < <(
    printf '%s\n' "$listing" |
      awk -v source_token="source=$source" -v sink_token="sink=$sink" '
        $2 == "module-loopback" {
          source_found = (source_token == "source=")
          sink_found = 0
          for (i = 3; i <= NF; ++i) {
            if ($i == source_token) source_found = 1
            if ($i == sink_token) sink_found = 1
          }
          if (source_found && sink_found) print $1
        }
      '
  )
  for module in "${modules[@]}"; do
    prism_unload_module "$module" || failed=1
  done
  return "$failed"
}

prism_unload_prism_capture_loopbacks() {
  prism_unload_loopback_modules "" prism-stream
}

prism_audio_remove_owned_state() {
  local state="${1:?state path required}"
  local loop_module="${2:-}"
  local current

  current="$(prism_audio_state_get "$state" loop_module 2>/dev/null || true)"
  if [ -n "$loop_module" ] && [ "$current" = "$loop_module" ]; then
    rm -f "$state"
  fi
}
