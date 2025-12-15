#!/usr/bin/env bash
# fnos-autofan.sh — fnOS Auto Fan for QNAP TS-464C2 (and similar)
#
# One-click install/repair for:
# - qnap8528 kernel module (build via repo build.sh, skip_hw_check=true)
# - module auto-load at boot (systemd qnap8528-load.service)
# - robust fan control daemon (EMA + hysteresis + rate limit + min hold)
#
# Usage:
#   sudo bash fnos-autofan.sh              # install/repair (default)
#   sudo bash fnos-autofan.sh --status     # show current status
#   sudo bash fnos-autofan.sh --safe-max   # stop fan daemon + set fan to max PWM
#   sudo bash fnos-autofan.sh --uninstall  # remove fan daemon + disable driver autoload (+ remove fan2go leftovers)
#
# Optional env vars:
#   QNAP8528_REPO_URL=https://github.com/gzxiexl/qnap8528.git
#   QNAP8528_DIR=/opt/qnap8528             # defaults to <script_dir>/qnap8528 if writable, else /opt/qnap8528
#   PURGE_REPO=1                           # with --uninstall, also remove repo dir
#   MIN_PWM=76  MAX_PWM=255
#   INTERVAL=5  HYST_C=2  MIN_HOLD_SEC=10  MAX_STEP=12
#   EMA_NUM=3   EMA_DEN=4
#
# Notes:
# - Install/repair requires: git, docker, systemd, modprobe.
# - Status/safe-max/uninstall do NOT require git/docker.
# - This script does NOT embed any user-specific information.

set -euo pipefail

SELF_NAME="$(basename "${0}")"
SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"

QNAP8528_REPO_URL="${QNAP8528_REPO_URL:-https://github.com/gzxiexl/qnap8528.git}"

# Default repo dir: use script dir if writable, else /opt
DEFAULT_REPO_DIR="${SCRIPT_DIR}/qnap8528"
if [[ ! -w "${SCRIPT_DIR}" ]]; then
  DEFAULT_REPO_DIR="/opt/qnap8528"
fi
QNAP8528_DIR="${QNAP8528_DIR:-${DEFAULT_REPO_DIR}}"
PURGE_REPO="${PURGE_REPO:-0}"

# Fan daemon params (safe defaults based on TS-464C2 measurements)
MIN_PWM="${MIN_PWM:-76}"
MAX_PWM="${MAX_PWM:-255}"
INTERVAL="${INTERVAL:-5}"
HYST_C="${HYST_C:-2}"
MIN_HOLD_SEC="${MIN_HOLD_SEC:-10}"
MAX_STEP="${MAX_STEP:-12}"
EMA_NUM="${EMA_NUM:-3}"
EMA_DEN="${EMA_DEN:-4}"

# When uninstalling, optionally set a fixed safe PWM before unloading driver.
# Set to 0 to skip. You may override: SAFE_UNINSTALL_PWM=200
SAFE_UNINSTALL_PWM="${SAFE_UNINSTALL_PWM:-200}"

FAN_DAEMON_PATH="/usr/local/sbin/qnap-fan-daemon.sh"
FAN_SERVICE_PATH="/etc/systemd/system/qnap-fan-daemon.service"
MODPROBE_CONF_PATH="/etc/modprobe.d/qnap8528.conf"
DRIVER_SERVICE_PATH="/etc/systemd/system/qnap8528-load.service"
MODULES_LOADD_PATH="/etc/modules-load.d/qnap8528.conf"

MODE="install"

_ts() { date '+%F %T'; }
log() { echo -e "[$(_ts)] [+] $*"; }
warn() { echo -e "[$(_ts)] [!] $*" >&2; }
die() { echo -e "[$(_ts)] [x] $*" >&2; exit 1; }

STAGE="init"
on_err() {
  local rc=$?
  warn "FAILED at stage: ${STAGE}"
  warn "Last command: ${BASH_COMMAND}"
  warn "Return code: ${rc}"
  warn "Hints:"
  warn "  - Kernel logs:  journalctl -k -b --no-pager | tail -n 200"
  warn "  - Driver svc:   systemctl status qnap8528-load.service --no-pager || true"
  warn "  - Fan svc:      systemctl status qnap-fan-daemon.service --no-pager || true"
  exit $rc
}
trap on_err ERR

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root: sudo bash ${SELF_NAME}"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run() {
  log "CMD: $*"
  "$@"
}

usage() {
  cat <<EOF
fnOS auto fan one-click

Usage:
  sudo bash ${SELF_NAME}                  Install/repair (default)
  sudo bash ${SELF_NAME} --status         Show status
  sudo bash ${SELF_NAME} --safe-max       Stop fan daemon + set max PWM (${MAX_PWM})
  sudo bash ${SELF_NAME} --uninstall      Uninstall fan daemon + disable driver autoload

Env:
  QNAP8528_REPO_URL=${QNAP8528_REPO_URL}
  QNAP8528_DIR=${QNAP8528_DIR}
  PURGE_REPO=1 (with --uninstall, delete repo dir)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) MODE="status"; shift ;;
      --safe-max) MODE="safe-max"; shift ;;
      --uninstall) MODE="uninstall"; shift ;;
      -h|--help) MODE="help"; shift ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
  done
}

check_prereqs_basic() {
  STAGE="check_prereqs_basic"
  log "Checking basic prerequisites..."

  for c in uname systemctl modprobe; do
    have_cmd "$c" || die "Missing required command: $c"
  done
  systemctl >/dev/null 2>&1 || die "systemctl not available; this script assumes systemd-based fnOS."

  log "Kernel: $(uname -r)"
}

check_prereqs_install() {
  STAGE="check_prereqs_install"
  log "Checking install prerequisites (git + docker)..."

  have_cmd git || die "Missing git. Install git first."
  have_cmd docker || die "Missing docker. Install/enable Docker in fnOS first."

  log "Docker: $(docker --version 2>/dev/null || true)"
  log "Git:    $(git --version 2>/dev/null || true)"
}

find_hwmon_by_name() {
  local target="$1"
  for d in /sys/class/hwmon/hwmon*; do
    if [[ "$(cat "$d/name" 2>/dev/null || true)" == "$target" ]]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

is_driver_visible() {
  # Note: grep -q only suppresses output; exit-code behavior is identical to plain grep.
  [[ -d /sys/module/qnap8528 ]] && return 0
  grep -q '^qnap8528[[:space:]]' /proc/modules 2>/dev/null && return 0
  lsmod 2>/dev/null | grep -q '^qnap8528[[:space:]]' && return 0
  return 1
}

ensure_repo() {
  STAGE="ensure_repo"

  log "Ensuring qnap8528 repo in: ${QNAP8528_DIR}"

  if [[ -d "${QNAP8528_DIR}/.git" ]]; then
    log "Repo exists; updating..."
    (
      cd "${QNAP8528_DIR}"
      git fetch --all --prune || true

      # Figure out default branch robustly.
      local ref branch
      ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      branch="${ref#origin/}"

      if [[ -z "${branch}" ]]; then
        if git show-ref --verify --quiet refs/remotes/origin/main; then
          branch="main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
          branch="master"
        else
          branch=""
        fi
      fi

      if [[ -n "${branch}" ]]; then
        git checkout -f "${branch}" || true
        git reset --hard "origin/${branch}" || true
      else
        # Fallback: just hard reset to current HEAD.
        git reset --hard HEAD || true
      fi
    ) || warn "Repo update failed; continuing with existing content."

  else
    log "Cloning repo..."
    run mkdir -p "${QNAP8528_DIR}"
    run git clone "${QNAP8528_REPO_URL}" "${QNAP8528_DIR}"
  fi

  [[ -f "${QNAP8528_DIR}/build.sh" ]] || die "build.sh not found in repo (${QNAP8528_DIR})."
  run chmod +x "${QNAP8528_DIR}/build.sh"

  if [[ -d "${QNAP8528_DIR}/.git" ]]; then
    log "Repo HEAD: $(cd "${QNAP8528_DIR}" && git rev-parse --short HEAD 2>/dev/null || true)"
  fi
}

build_and_install_driver() {
  STAGE="build_and_install_driver"
  log "Building/installing qnap8528 kernel module (skip_hw_check=true)..."
  (cd "${QNAP8528_DIR}" && ./build.sh skip_hw_check=true)
}

ensure_modprobe_options() {
  STAGE="ensure_modprobe_options"
  log "Writing modprobe options: ${MODPROBE_CONF_PATH}"
  echo "options qnap8528 skip_hw_check=true" > "${MODPROBE_CONF_PATH}"
  log "modprobe options now: $(cat "${MODPROBE_CONF_PATH}" 2>/dev/null || true)"
}

ensure_module_loaded() {
  STAGE="ensure_module_loaded"
  log "Ensuring module is loaded (modprobe)..."
  modprobe -r qnap8528 >/dev/null 2>&1 || true
  run modprobe qnap8528 skip_hw_check=true

  # Verify via /sys/hwmon (stronger signal than lsmod for fan control)
  if find_hwmon_by_name qnap8528 >/dev/null 2>&1; then
    log "qnap8528 hwmon present after modprobe (OK)"
  else
    warn "qnap8528 hwmon not found yet; checking module visibility..."
    is_driver_visible || die "qnap8528 did not become visible and hwmon not present."
  fi
}

write_driver_service() {
  STAGE="write_driver_service"
  log "Installing/enabling qnap8528-load.service (boot auto-load)..."

  cat > "${DRIVER_SERVICE_PATH}" <<EOF
[Unit]
Description=Load qnap8528 Kernel Module
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/sbin/modprobe qnap8528 skip_hw_check=true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  run systemctl daemon-reload
  run systemctl enable --now qnap8528-load.service
  log "qnap8528-load.service: enabled=$(systemctl is-enabled qnap8528-load.service 2>/dev/null || echo '?') active=$(systemctl is-active qnap8528-load.service 2>/dev/null || echo '?')"

  # Also write modules-load.d as a hint (no params). Options are supplied via modprobe.d.
  echo "qnap8528" > "${MODULES_LOADD_PATH}" || true
}

write_fan_daemon() {
  STAGE="write_fan_daemon"
  log "Writing fan daemon to ${FAN_DAEMON_PATH}..."
  log "Params: MIN_PWM=${MIN_PWM} MAX_PWM=${MAX_PWM} INTERVAL=${INTERVAL}s HYST_C=${HYST_C}C MIN_HOLD_SEC=${MIN_HOLD_SEC}s MAX_STEP=${MAX_STEP} EMA=${EMA_NUM}/${EMA_DEN}"

  cat > "${FAN_DAEMON_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

MIN_PWM=${MIN_PWM}
MAX_PWM=${MAX_PWM}
INTERVAL=${INTERVAL}
HYST_C=${HYST_C}
MIN_HOLD_SEC=${MIN_HOLD_SEC}
MAX_STEP=${MAX_STEP}
EMA_NUM=${EMA_NUM}
EMA_DEN=${EMA_DEN}

log() { echo "[qnap-fan] \$(date '+%F %T') \$*"; }

find_hwmon_by_name() {
  local target="\$1"
  for d in /sys/class/hwmon/hwmon*; do
    [[ "\$(cat "\$d/name" 2>/dev/null || true)" == "\$target" ]] && { echo "\$d"; return 0; }
  done
  return 1
}

read_temp_mC() {
  local f="\$1" v
  v="\$(cat "\$f" 2>/dev/null || echo 0)"
  # filter: <5C or >110C invalid
  if [[ "\$v" -lt 5000 || "\$v" -gt 110000 ]]; then echo 0; else echo "\$v"; fi
}

max_temp_mC() {
  local m=0 v f d
  # CPU package
  if [[ -n "\${H_CPU:-}" && -e "\$CPU_T" ]]; then
    v="\$(read_temp_mC "\$CPU_T")"; (( v > m )) && m=\$v
  fi
  # qnap8528 temp1/temp6
  for f in "\$H_QNAP/temp1_input" "\$H_QNAP/temp6_input"; do
    [[ -e "\$f" ]] || continue
    v="\$(read_temp_mC "\$f")"; (( v > m )) && m=\$v
  done
  # all nvme hwmon
  for d in /sys/class/hwmon/hwmon*; do
    [[ "\$(cat "\$d/name" 2>/dev/null || true)" == "nvme" ]] || continue
    for f in "\$d"/temp*_input; do
      [[ -e "\$f" ]] || continue
      v="\$(read_temp_mC "\$f")"; (( v > m )) && m=\$v
    done
  done
  echo "\$m"
}

pwm_target_for_tempC() {
  local tC="\$1"
  if   (( tC < 40 )); then echo "\$MIN_PWM"
  elif (( tC < 50 )); then echo 110
  elif (( tC < 60 )); then echo 150
  elif (( tC < 70 )); then echo 200
  else echo "\$MAX_PWM"; fi
}

exec 9>/run/qnap-fan-daemon.lock
flock -n 9 || exit 0

H_QNAP="\$(find_hwmon_by_name qnap8528)"
PWM="\$H_QNAP/pwm1"
RPM="\$H_QNAP/fan1_input"

H_CPU="\$(find_hwmon_by_name coretemp || true)"
CPU_T="\$H_CPU/temp1_input"

last_pwm="\$(cat "\$PWM" 2>/dev/null || echo "\$MIN_PWM")"
last_set_ts="\$(date +%s)"
ema_mC=0

log "Started. qnap=\$H_QNAP cpu=\${H_CPU:-none} pwm=\$PWM rpm=\$RPM"

while true; do
  raw_mC="\$(max_temp_mC)"
  if (( raw_mC <= 0 )); then
    echo "\$MAX_PWM" > "\$PWM"
    last_pwm="\$MAX_PWM"; last_set_ts="\$(date +%s)"
    sleep "\$INTERVAL"; continue
  fi

  if (( ema_mC == 0 )); then
    ema_mC=\$raw_mC
  else
    ema_mC=\$(( (ema_mC*EMA_NUM + raw_mC*(EMA_DEN-EMA_NUM)) / EMA_DEN ))
  fi

  tC=\$((ema_mC/1000))
  target="\$(pwm_target_for_tempC "\$tC")"

  # hysteresis around 50/60/70 boundaries
  if (( target != last_pwm )); then
    if (( last_pwm <= 110 && target >= 150 )); then (( tC < 50 + HYST_C )) && target="\$last_pwm"; fi
    if (( last_pwm >= 150 && target <= 110 )); then (( tC > 50 - HYST_C )) && target="\$last_pwm"; fi
    if (( last_pwm <= 150 && target >= 200 )); then (( tC < 60 + HYST_C )) && target="\$last_pwm"; fi
    if (( last_pwm >= 200 && target <= 150 )); then (( tC > 60 - HYST_C )) && target="\$last_pwm"; fi
    if (( last_pwm <= 200 && target >= 255 )); then (( tC < 70 + HYST_C )) && target="\$last_pwm"; fi
    if (( last_pwm >= 255 && target <= 200 )); then (( tC > 70 - HYST_C )) && target="\$last_pwm"; fi
  fi

  now="\$(date +%s)"
  if (( now - last_set_ts < MIN_HOLD_SEC )); then
    sleep "\$INTERVAL"; continue
  fi

  new_pwm="\$last_pwm"
  if (( target > last_pwm )); then
    delta=\$((target - last_pwm)); (( delta > MAX_STEP )) && delta=\$MAX_STEP
    new_pwm=\$((last_pwm + delta))
  elif (( target < last_pwm )); then
    delta=\$((last_pwm - target)); (( delta > MAX_STEP )) && delta=\$MAX_STEP
    new_pwm=\$((last_pwm - delta))
  fi

  (( new_pwm < MIN_PWM )) && new_pwm=\$MIN_PWM
  (( new_pwm > MAX_PWM )) && new_pwm=\$MAX_PWM

  if (( new_pwm != last_pwm )); then
    echo "\$new_pwm" > "\$PWM"
    last_pwm="\$new_pwm"; last_set_ts="\$now"
  fi

  sleep "\$INTERVAL"
done
EOF

  chmod +x "${FAN_DAEMON_PATH}"
}

write_fan_service() {
  STAGE="write_fan_service"
  log "Writing systemd service to ${FAN_SERVICE_PATH}..."

  cat > "${FAN_SERVICE_PATH}" <<EOF
[Unit]
Description=QNAP fan daemon (qnap8528 pwm control)
Wants=qnap8528-load.service
After=qnap8528-load.service

[Service]
Type=simple
ExecStart=${FAN_DAEMON_PATH}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  run systemctl daemon-reload
}

enable_fan_service() {
  STAGE="enable_fan_service"
  log "Enabling and starting fan daemon..."
  run systemctl enable --now qnap-fan-daemon.service
  log "qnap-fan-daemon.service: enabled=$(systemctl is-enabled qnap-fan-daemon.service 2>/dev/null || echo '?') active=$(systemctl is-active qnap-fan-daemon.service 2>/dev/null || echo '?')"
}

status_report() {
  STAGE="status"
  echo "===== fnOS autofan status ====="
  echo "Time:   $(_ts)"
  echo "Kernel: $(uname -r)"
  echo "Script: ${SELF_NAME} (dir: ${SCRIPT_DIR})"
  echo "Repo  : ${QNAP8528_DIR}"
  echo

  local H_Q H_C
  H_Q="$(find_hwmon_by_name qnap8528 || true)"
  H_C="$(find_hwmon_by_name coretemp || true)"

  echo "[Driver]"
  if is_driver_visible; then
    echo "  module: visible"
    echo "  lsmod : $(lsmod 2>/dev/null | grep '^qnap8528[[:space:]]' | head -n 1 || true)"
  else
    echo "  module: not visible via /sys/module,/proc/modules,lsmod"
  fi
  if [[ -f "${MODPROBE_CONF_PATH}" ]]; then
    echo "  modprobe: ${MODPROBE_CONF_PATH} -> $(cat "${MODPROBE_CONF_PATH}" 2>/dev/null || true)"
  else
    echo "  modprobe: (missing)"
  fi
  # Detect service robustly:
  # - file exists in /etc/systemd/system (strong)
  # - systemctl can "cat" it (strong)
  # list-unit-files can lag without daemon-reload or be affected by systemd caching.
  local svc_src="" svc_installed=0
  [[ -f "${DRIVER_SERVICE_PATH}" ]] && svc_src="file:${DRIVER_SERVICE_PATH}"
  if systemctl cat qnap8528-load.service >/dev/null 2>&1; then
    svc_installed=1
    [[ -z "${svc_src}" ]] && svc_src="systemd"
  fi
  if (( svc_installed == 1 )); then
    echo "  service: qnap8528-load.service (installed; ${svc_src}) enabled=$(systemctl is-enabled qnap8528-load.service 2>/dev/null || true) active=$(systemctl is-active qnap8528-load.service 2>/dev/null || true)"
  else
    echo "  service: qnap8528-load.service (not installed)"
  fi

  echo
  echo "[Fan daemon]"
  # Detect fan service robustly (same idea as driver service)
  local fan_svc_src="" fan_svc_installed=0
  [[ -f "${FAN_SERVICE_PATH}" ]] && fan_svc_src="file:${FAN_SERVICE_PATH}"
  if systemctl cat qnap-fan-daemon.service >/dev/null 2>&1; then
    fan_svc_installed=1
    [[ -z "${fan_svc_src}" ]] && fan_svc_src="systemd"
  fi
  if (( fan_svc_installed == 1 )); then
    echo "  service: qnap-fan-daemon.service (installed; ${fan_svc_src}) enabled=$(systemctl is-enabled qnap-fan-daemon.service 2>/dev/null || true) active=$(systemctl is-active qnap-fan-daemon.service 2>/dev/null || true)"
  else
    echo "  service: qnap-fan-daemon.service (not installed)"
  fi
  echo "  daemon : ${FAN_DAEMON_PATH} $( [[ -x "${FAN_DAEMON_PATH}" ]] && echo '(present)' || echo '(missing)' )"

  echo
  echo "[Sensors]"
  if [[ -n "$H_Q" ]]; then
    echo "  qnap8528 hwmon: $H_Q"
    echo "    pwm1       : $(cat "$H_Q/pwm1" 2>/dev/null || echo N/A)"
    echo "    fan1_input : $(cat "$H_Q/fan1_input" 2>/dev/null || echo N/A) RPM"
    echo "    temp1_input: $(cat "$H_Q/temp1_input" 2>/dev/null || echo N/A) mC"
    echo "    temp6_input: $(cat "$H_Q/temp6_input" 2>/dev/null || echo N/A) mC"
  else
    echo "  qnap8528 hwmon: NOT FOUND"
  fi
  if [[ -n "$H_C" ]]; then
    echo "  coretemp hwmon: $H_C"
    echo "    package temp1_input: $(cat "$H_C/temp1_input" 2>/dev/null || echo N/A) mC"
  else
    echo "  coretemp hwmon: NOT FOUND"
  fi

  echo
  echo "[Repo]"
  if [[ -d "${QNAP8528_DIR}" ]]; then
    echo "  dir: ${QNAP8528_DIR}"
    if [[ -d "${QNAP8528_DIR}/.git" ]]; then
      echo "  head: $(cd "${QNAP8528_DIR}" && git rev-parse --short HEAD 2>/dev/null || true)"
    else
      echo "  head: (not a git repo?)"
    fi
  else
    echo "  dir: (missing)"
  fi

  echo
  echo "[Summary]"
  if [[ -n "$H_Q" && -e "$H_Q/pwm1" ]]; then
    echo "  hwmon interface: PRESENT (strongest signal that qnap8528 is working)"
  else
    echo "  hwmon interface: MISSING"
  fi
  echo "================================"
}

safe_max() {
  STAGE="safe-max"
  log "SAFE-MAX: stopping fan daemon (if running) and setting PWM=${MAX_PWM}"

  systemctl stop qnap-fan-daemon.service >/dev/null 2>&1 || true
  pkill -f "${FAN_DAEMON_PATH}" >/dev/null 2>&1 || true

  local H
  H="$(find_hwmon_by_name qnap8528 || true)"
  [[ -n "$H" ]] || die "qnap8528 hwmon not found; driver may be broken."
  [[ -w "$H/pwm1" ]] || die "pwm1 is not writable: $H/pwm1"

  echo "${MAX_PWM}" > "$H/pwm1"
  log "Set $H/pwm1 to ${MAX_PWM}. RPM now: $(cat "$H/fan1_input" 2>/dev/null || echo '?')"
  warn "To resume automatic control: run install (default) or: systemctl start qnap-fan-daemon.service"
}

remove_fan2go_leftovers() {
  STAGE="remove_fan2go_leftovers"
  log "Removing fan2go leftovers (if any)..."

  systemctl disable --now fan2go.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fan2go.service >/dev/null 2>&1 || true
  rm -rf /etc/fan2go >/dev/null 2>&1 || true
  rm -f /usr/bin/fan2go >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

set_pwm_if_possible() {
  # Best-effort: set pwm1 on qnap8528 hwmon if available.
  local pwm="$1" H
  [[ "${pwm}" =~ ^[0-9]+$ ]] || return 0
  (( pwm <= 0 )) && return 0

  H="$(find_hwmon_by_name qnap8528 || true)"
  [[ -n "${H}" ]] || return 0
  [[ -w "${H}/pwm1" ]] || return 0

  echo "${pwm}" > "${H}/pwm1" 2>/dev/null || return 0
  log "Set safe PWM during uninstall: ${H}/pwm1=${pwm} (rpm=$(cat "${H}/fan1_input" 2>/dev/null || echo '?'))"
}

clamp_pwm() {
  local v="$1" lo="$2" hi="$3"
  [[ "${v}" =~ ^[0-9]+$ ]] || { echo "${lo}"; return 0; }
  (( v < lo )) && v=$lo
  (( v > hi )) && v=$hi
  echo "${v}"
}

uninstall_all() {
  STAGE="uninstall"
  log "Uninstall: removing fan daemon + disabling driver autoload (+ fan2go leftovers)"

  # Stop/disable fan daemon first (avoid a third-party changing PWM while we operate)
  systemctl disable --now qnap-fan-daemon.service >/dev/null 2>&1 || true
  pkill -f "${FAN_DAEMON_PATH}" >/dev/null 2>&1 || true

  # Before removing the driver, set a safe fixed PWM so the fan won't be left at a too-low value.
  # This is best-effort and only works while qnap8528 hwmon is still present.
  if [[ "${SAFE_UNINSTALL_PWM}" != "0" ]]; then
    local safe_pwm
    safe_pwm="$(clamp_pwm "${SAFE_UNINSTALL_PWM}" "${MIN_PWM}" "${MAX_PWM}")"
    set_pwm_if_possible "${safe_pwm}" || true
  fi

  # Remove daemon + unit
  rm -f "${FAN_SERVICE_PATH}" >/dev/null 2>&1 || true
  rm -f "${FAN_DAEMON_PATH}" >/dev/null 2>&1 || true

  # Disable/remove driver autoload
  systemctl disable --now qnap8528-load.service >/dev/null 2>&1 || true
  rm -f "${DRIVER_SERVICE_PATH}" >/dev/null 2>&1 || true
  rm -f "${MODULES_LOADD_PATH}" >/dev/null 2>&1 || true

  # Remove modprobe options
  rm -f "${MODPROBE_CONF_PATH}" >/dev/null 2>&1 || true

  run systemctl daemon-reload

  # Remove fan2go leftovers too
  remove_fan2go_leftovers || true

  # Attempt to unload module (after PWM is set)
  if is_driver_visible; then
    warn "Attempting to unload qnap8528 (may fail if in use)..."
    modprobe -r qnap8528 >/dev/null 2>&1 || warn "modprobe -r qnap8528 failed (can be OK)."
  fi

  # Optional repo purge
  if [[ "${PURGE_REPO}" == "1" ]]; then
    warn "PURGE_REPO=1 set; removing repo directory: ${QNAP8528_DIR}"
    rm -rf "${QNAP8528_DIR}" >/dev/null 2>&1 || true
  else
    log "Repo kept at ${QNAP8528_DIR} (set PURGE_REPO=1 to delete on uninstall)"
  fi

  warn "Uninstall complete. Fan PWM was set (best-effort) to SAFE_UNINSTALL_PWM=${SAFE_UNINSTALL_PWM} before unloading the driver."
  warn "If you need emergency full speed, do it BEFORE uninstall: sudo bash ${SELF_NAME} --safe-max"
}

self_check() {
  STAGE="self_check"
  log "Running self-check..."

  local H
  H="$(find_hwmon_by_name qnap8528 || true)"
  [[ -n "$H" ]] || die "qnap8528 hwmon not found. Driver not working."
  [[ -e "$H/pwm1" ]] || die "pwm1 not found under $H."
  [[ -e "$H/fan1_input" ]] || die "fan1_input not found under $H."

  log "qnap8528 hwmon: $H"
  log "PWM now: $(cat "$H/pwm1" 2>/dev/null || echo '?')"
  log "RPM now: $(cat "$H/fan1_input" 2>/dev/null || echo '?')"

  log "qnap8528-load.service: enabled=$(systemctl is-enabled qnap8528-load.service 2>/dev/null || echo '?') active=$(systemctl is-active qnap8528-load.service 2>/dev/null || echo '?')"
  log "qnap-fan-daemon.service: enabled=$(systemctl is-enabled qnap-fan-daemon.service 2>/dev/null || echo '?') active=$(systemctl is-active qnap-fan-daemon.service 2>/dev/null || echo '?')"
}

install_or_repair() {
  STAGE="install_or_repair"
  log "Starting install/repair..."
  log "Repo dir: ${QNAP8528_DIR}"

  check_prereqs_basic
  check_prereqs_install

  ensure_repo
  build_and_install_driver
  ensure_modprobe_options
  ensure_module_loaded

  write_driver_service

  write_fan_daemon
  write_fan_service
  enable_fan_service

  self_check
  log "Done. Driver and fan daemon should now be installed and running."
}

main() {
  need_root
  parse_args "$@"

  case "${MODE}" in
    help) usage ;;
    status)
      check_prereqs_basic
      status_report
      ;;
    safe-max)
      check_prereqs_basic
      safe_max
      ;;
    uninstall)
      check_prereqs_basic
      uninstall_all
      ;;
    install)
      install_or_repair
      ;;
    *) die "Unknown mode: ${MODE}" ;;
  esac
}

main "$@"
