#!/usr/bin/env bash
set -euo pipefail

# Bash equivalent of jobber-dunstify-sink.py:
# - reads Jobber RunRec JSON from stdin
# - optionally suppresses no-op notifications (JOBBER_NOOP marker)
# - sends a notification via dunstify
#
# Requires: jq, base64, dunstify

NOOP_MARKER="JOBBER_NOOP"

raw="$(cat)"
if [[ -z "${raw}" ]]; then
  echo "jobber-dunstify-sink: no stdin" >&2
  exit 2
fi

if ! echo "${raw}" | jq -e . >/dev/null 2>&1; then
  echo "jobber-dunstify-sink: invalid JSON" >&2
  exit 2
fi

job_name="$(echo "${raw}" | jq -r '.job.name // "<unknown job>"')"
job_cmd="$(echo "${raw}" | jq -r '.job.command // ""')"
job_time="$(echo "${raw}" | jq -r '.job.time // ""')"
status="$(echo "${raw}" | jq -r '.job.status // ""')"
succeeded="$(echo "${raw}" | jq -r '.succeeded // false')"
fate="$(echo "${raw}" | jq -r '.fate // ""')"

stdout="$(
  echo "${raw}" | jq -r '
    if (.stdout? != null) then .stdout
    elif (.stdoutBase64? != null) then .stdoutBase64
    else "" end
  '
)"
stdout_is_b64="$(echo "${raw}" | jq -r '(.stdoutBase64? != null)')"
if [[ "${stdout_is_b64}" == "true" && -n "${stdout}" ]]; then
  if ! stdout="$(printf '%s' "${stdout}" | base64 -d 2>/dev/null)"; then
    stdout="<stdoutBase64 present but failed to decode>"
  fi
fi

stderr="$(
  echo "${raw}" | jq -r '
    if (.stderr? != null) then .stderr
    elif (.stderrBase64? != null) then .stderrBase64
    else "" end
  '
)"
stderr_is_b64="$(echo "${raw}" | jq -r '(.stderrBase64? != null)')"
if [[ "${stderr_is_b64}" == "true" && -n "${stderr}" ]]; then
  if ! stderr="$(printf '%s' "${stderr}" | base64 -d 2>/dev/null)"; then
    stderr="<stderrBase64 present but failed to decode>"
  fi
fi

# Practical third state: suppress notifications if marker is present on success.
if [[ "${succeeded}" == "true" ]]; then
  if [[ "${stdout}" == *"${NOOP_MARKER}"* || "${stderr}" == *"${NOOP_MARKER}"* ]]; then
    exit 0
  fi
fi

urgency="critical"
summary="Jobber: ${job_name} failed"
if [[ "${succeeded}" == "true" ]]; then
  urgency="normal"
  summary="Jobber: ${job_name} succeeded"
fi

body_lines=()
[[ -n "${status}" ]] && body_lines+=("Status: ${status}")
[[ -n "${fate}" ]] && body_lines+=("Fate: ${fate}")
[[ -n "${job_time}" ]] && body_lines+=("Schedule: ${job_time}")
[[ -n "${job_cmd}" ]] && body_lines+=("Cmd: ${job_cmd}")

if [[ "${succeeded}" != "true" && -n "${stderr//[[:space:]]/}" ]]; then
  body_lines+=("")
  body_lines+=("Stderr:")
  body_lines+=("${stderr}")
elif [[ "${succeeded}" == "true" && -n "${stdout//[[:space:]]/}" ]]; then
  body_lines+=("")
  body_lines+=("Stdout:")
  body_lines+=("${stdout}")
fi

body=""
if ((${#body_lines[@]} > 0)); then
  body="$(printf "%s\n" "${body_lines[@]}")"
fi

# Best-effort DBus env fallback.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
  if [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  fi
fi
export DISPLAY="${DISPLAY:-:1}"

dunstify="/opt/dunst/dunstify"
command -v "${dunstify}" >/dev/null 2>&1 || dunstify="dunstify"

if [[ -n "${body}" ]]; then
  exec "${dunstify}" -a jobber -u "${urgency}" -p "${summary}" "${body}"
else
  exec "${dunstify}" -a jobber -u "${urgency}" -p "${summary}"
fi
