#!/bin/bash
# GLM-5.3-Flash + Project Maya installer for Ubuntu 26.04 LTS (Resolute Raccoon), x86_64,
# Server or Desktop.
#
#   bash install-glm-maya.sh [options]     install or update in place
#   bash install-glm-maya.sh --uninstall   uninstall
#
# Compiling the engine, downloading the model and writing the engine configuration are left
# to Maya's own setup (maya.sh).  This installer adds the CUDA toolkit and the other apt
# packages, the service user, the systemd unit, the nginx site, ufw rules, GPU and network
# interface selection and uninstall.
#
# See README.md or --help for the options.

set -euo pipefail
umask 022

readonly GLMMAYAINS_APP_NAME="glm-maya"
readonly GLMMAYAINS_CONF_DIR="/etc/$GLMMAYAINS_APP_NAME"
readonly GLMMAYAINS_CONF_FILE="$GLMMAYAINS_CONF_DIR/install.conf"
readonly GLMMAYAINS_ENV_FILE="$GLMMAYAINS_CONF_DIR/maya.env"
readonly GLMMAYAINS_NGINX_KEY_FILE="$GLMMAYAINS_CONF_DIR/nginx-key.conf"
readonly GLMMAYAINS_UNIT="$GLMMAYAINS_APP_NAME.service"
readonly GLMMAYAINS_UNIT_DIR="/etc/systemd/system"
readonly GLMMAYAINS_NGINX_SITE="/etc/nginx/sites-available/$GLMMAYAINS_APP_NAME"
readonly GLMMAYAINS_NGINX_LINK="/etc/nginx/sites-enabled/$GLMMAYAINS_APP_NAME"
readonly GLMMAYAINS_LOGROTATE_FILE="/etc/logrotate.d/$GLMMAYAINS_APP_NAME"
readonly GLMMAYAINS_MARKER=".$GLMMAYAINS_APP_NAME-installation"

# Project Maya release (pinned).  The archive of the tag is downloaded with curl; it is not
# verified with a checksum (GitHub does not guarantee that generated archives stay
# byte-identical).  Everything else is downloaded and verified by Maya's setup.
readonly GLMMAYAINS_MAYA_VERSION="1.1.63"
readonly GLMMAYAINS_MAYA_URL="https://github.com/mw00/project-maya/archive/refs/tags/v$GLMMAYAINS_MAYA_VERSION.tar.gz"
# The model as it is shown, and the name Maya's server gives it (/v1/models).  Maya's --model
# takes the setup id of a quantization and the folders are named after Maya's key of it:
# see GLMMAYAINS_QUANT.
readonly GLMMAYAINS_MODEL="GLM-5.3-Flash"
readonly GLMMAYAINS_MODEL_NAME="glm-5.3-flash"
# Maya requires NVIDIA driver 580 or later when the engine is built with CUDA 13, and
# CUDA 13 cannot compile for a compute capability below 7.5 (RTX 20 series).
readonly GLMMAYAINS_NVIDIA_MIN_DRIVER="580"
readonly GLMMAYAINS_MIN_COMPUTE_CAP="7.5"
# The DFlash2 drafter: Maya offers it from compute capability 8.0 (RTX 30 series) only, and
# does not check that when --draft is given.  Its license is shown wherever it is selected.
readonly GLMMAYAINS_DRAFTER_MIN_COMPUTE_CAP="8.0"
readonly GLMMAYAINS_DRAFTER_LICENSE="CC BY-NC-ND 4.0, non-commercial use only"
# Maya's speed calibration (--drafting measure) and its tuning (--calibrate) do nothing
# when the GPU has more than this much memory (MiB) in use.
readonly GLMMAYAINS_GPU_BUSY_MIB=1024
# The units of deepseek-maya-installer-for-resolute and qwen-strata-installer-for-resolute:
# never run together with this service.
readonly GLMMAYAINS_EXCLUSIVE_UNITS="deepseek-maya.service qwen-strata.service"
# The units of plamo-3-translate-installer-for-resolute: this service is started after them.
readonly GLMMAYAINS_PLAMO_UNITS="plamo-3-translate-llama.service plamo-3-translate-uwsgi.service"

readonly GLMMAYAINS_BASE_PACKAGES="cuda-toolkit-13 build-essential python3 python3-venv nginx-full curl ca-certificates tar pciutils"
# Installed with --vision only: Maya reads video with ffmpeg and ffprobe.
readonly GLMMAYAINS_VISION_PACKAGES="ffmpeg"

# Quantizations: "<Maya's setup id (--model)> <Maya's key: the folder under models/ and, in
# lower case, the name of the configuration> <download, in units of 100 MB> <GPU memory +
# RAM for the whole model, GB>".  Figures from Maya 1.1.63 (maya.py, docs/MEMORY.md).
declare -A GLMMAYAINS_QUANT=(
  [Maya-XS]="glm-maya-xs Maya-XS-IQ1_S 734 80"
  [Maya-S24]="glm-maya-s24 Maya-S24 947 102"
  [Maya-S]="glm-maya-s Maya-S-v2-IQ2_XXS 965 104"
  [Maya-M]="glm-maya-m Maya-M 1160 124"
  [Maya-L]="glm-maya-l Maya-L 1563 164"
)
readonly GLMMAYAINS_QUANTS="Maya-XS Maya-S24 Maya-S Maya-M Maya-L"
# Maya's setup recommends Maya-S24 instead of Maya-S when no GPU has more memory than this
# (MiB; 24.5 GB).
readonly GLMMAYAINS_S24_MAX_VRAM_MIB=25088
# Disk space needed besides the model files: drafter, image encoder, pack, kept
# conversations, llama.cpp source, builds and .venv (bytes).
readonly GLMMAYAINS_EXTRA_DISK=$((20 * 1000 * 1000 * 1000))
# RAM (GiB) below which Maya is not expected to work (the minimum Maya names).
readonly GLMMAYAINS_MIN_RAM_GB=32
# Context sizes offered (256K, 512K, 768K, 1M).  None of them is among the choices of Maya's
# own setup (8K to 128K), which passes any number on; 768K is not mentioned by Maya at all.
readonly GLMMAYAINS_CTX_SIZES="262144 524288 786432 1048576"
# RAM a token of context takes for each conversation (bytes): the engine keeps the context
# in pinned RAM (KV streaming), 544 bytes in each of 11 attention layers with the 8-bit
# cache, rounded up to 6 KiB.  Derived from Maya's figures, not measured.
readonly GLMMAYAINS_CTX_BYTES=6144
# GLM's own levels and Maya's "none".  Maya also takes medium (= high), xhigh and auto
# (= max); they are not offered.
readonly GLMMAYAINS_THINKING_LEVELS="none low high max"
readonly GLMMAYAINS_DRAFTING_MODES="skip measure on"
# Seconds to wait for the service to load the model.
readonly GLMMAYAINS_HEALTH_TIMEOUT=3600

# Settings: KEY -> default.  Values come from options > environment > install.conf > default.
# GPU: empty = choose one GPU automatically (see validate_gpus).
readonly GLMMAYAINS_KEYS="DESTDIR USER QUANT GPU CTX_SIZE THINKING DRAFTING WEB_PORT MAYA_PORT INTERFACES WEB_API_KEY AGENT_API_KEY PARALLEL VISION"
declare -A GLMMAYAINS_DEFAULT=(
  [DESTDIR]=/opt/glm-maya [USER]=glmmaya [QUANT]=Maya-S [GPU]="" [CTX_SIZE]=524288
  [THINKING]=max [DRAFTING]=skip [WEB_PORT]=48080 [MAYA_PORT]=48081 [INTERFACES]=all
  [WEB_API_KEY]=no [AGENT_API_KEY]=no [PARALLEL]=1 [VISION]=yes
)
declare -A GLMMAYAINS_ARG=() GLMMAYAINS_VAL=() GLMMAYAINS_SAVED=() GLMMAYAINS_FROM_USER=()
GLMMAYAINS_ACTION=install
GLMMAYAINS_ASSUME_YES=no
GLMMAYAINS_OPEN_PORTS=""   # yes/no: open the port in ufw; empty: ask when ufw is active
GLMMAYAINS_CALIBRATE=""    # yes/no: Maya's tuning in this run; empty: no.  Never saved.
GLMMAYAINS_INTERACTIVE=no
[[ -t 0 ]] && GLMMAYAINS_INTERACTIVE=yes
GLMMAYAINS_UFW_RULES=""    # ufw rules added by the installer: PORT (any interface) or PORT@INTERFACE
GLMMAYAINS_API_KEY=""
GLMMAYAINS_TMP=""
GLMMAYAINS_MODEL_ID=""
GLMMAYAINS_N_CTX=""
GLMMAYAINS_EFFORT=""

# ---------------------------------------------------------------- utilities

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: bash $(basename "$0") [options]

Installs $GLMMAYAINS_MODEL with the Project Maya $GLMMAYAINS_MAYA_VERSION inference engine as a
systemd service behind nginx (web chat page and OpenAI/Anthropic-compatible API).
Values that are not given are asked interactively; when standard input is
not a terminal, defaults are used.  Re-running updates the installation.

Options asked interactively when not given (environment variable in brackets):
  --destdir DIR            install directory and home of the service user
                           [GLMMAYA_DESTDIR] (default ${GLMMAYAINS_DEFAULT[DESTDIR]})
  --user NAME              service user [GLMMAYA_USER] (default ${GLMMAYAINS_DEFAULT[USER]})
  --quant TYPE             Maya-XS, Maya-S24, Maya-S, Maya-M or Maya-L (Project
                           Maya's quantizations) [GLMMAYA_QUANT] (default ${GLMMAYAINS_DEFAULT[QUANT]})
  --gpu PCI                the GPU used by Maya, by PCI address such as 0000:03:00.0
                           [GLMMAYA_GPU] (default: the largest memory, then the most
                           free memory, then the lowest PCI address; asked when two
                           or more GPUs are usable)
  --ctx-size N             maximum context in tokens: 262144 (256K), 524288 (512K),
                           786432 (768K; not mentioned by the Maya project) or
                           1048576 (1M) [GLMMAYA_CTX_SIZE] (default ${GLMMAYAINS_DEFAULT[CTX_SIZE]})
  --thinking LEVEL         thinking level of requests that name none: none, low,
                           high or max [GLMMAYA_THINKING] (default ${GLMMAYAINS_DEFAULT[THINKING]})
  --drafting skip|measure|on
                           the DFlash2 drafter: skip = not used, nothing is
                           downloaded or measured; measure = Maya downloads it,
                           measures it (5 to 20 minutes) and keeps it only if it
                           is faster; on = used without measuring
                           [GLMMAYA_DRAFTING] (default ${GLMMAYAINS_DEFAULT[DRAFTING]})
                           The drafter's license is CC BY-NC-ND 4.0:
                           non-commercial use only.  It needs an RTX 30 series
                           GPU or newer and --parallel 1.
  --web-port PORT          web server (nginx) port [GLMMAYA_WEB_PORT] (default ${GLMMAYAINS_DEFAULT[WEB_PORT]})
  --interfaces all|IF[,IF...]
                           network interfaces on which the web server accepts
                           connections from other hosts [GLMMAYA_INTERFACES] (default
                           all; asked when two or more interfaces have addresses);
                           127.0.0.1 always works
  --web-api-key            require the API key for the web chat page
  --no-web-api-key         do not require it (default) [GLMMAYA_WEB_API_KEY=yes|no]
  --agent-api-key          require the API key for the API used by coding agents
  --no-agent-api-key       do not require it (default) [GLMMAYA_AGENT_API_KEY=yes|no]
                           The management paths always require the API key.
  --open-ports             open the web server port in ufw when ufw is active
  --no-open-ports          do not open ports in ufw [GLMMAYA_OPEN_PORTS=yes|no]
                           (default: ask when ufw is active)

Options that are never asked:
  --parallel N             requests answered at once, 1-8; each keeps a context of
                           its own in RAM [GLMMAYA_PARALLEL] (default ${GLMMAYAINS_DEFAULT[PARALLEL]})
  --vision                 build the image encoder and download its files so that
                           pictures and video can be read; installs ffmpeg
  --no-vision              text only [GLMMAYA_VISION=yes|no] (default ${GLMMAYAINS_DEFAULT[VISION]})
  --calibrate              let Maya tune the engine for this machine in this run
                           (10 to 15 minutes; needs the GPU free)
  --no-calibrate           do not (default) [GLMMAYA_CALIBRATE=yes|no]
                           Not remembered: give it again when it is wanted again.
  --maya-port PORT         port of Maya on 127.0.0.1 [GLMMAYA_MAYA_PORT] (default ${GLMMAYAINS_DEFAULT[MAYA_PORT]})

Actions:
  --yes                    answer yes to warnings, opening ufw ports and uninstalling
  --uninstall              uninstall
  -h, --help               show this help
EOF
}

yesno() {  # normalize yes/no; prints "yes", "no" or nothing
  case "${1,,}" in
    y|yes|true|1|on) echo yes ;;
    n|no|false|0|off) echo no ;;
  esac
}

trim() {  # print $1 without leading and trailing whitespace
  local GLMMAYAINS_s=$1
  GLMMAYAINS_s="${GLMMAYAINS_s#"${GLMMAYAINS_s%%[![:space:]]*}"}"
  GLMMAYAINS_s="${GLMMAYAINS_s%"${GLMMAYAINS_s##*[![:space:]]}"}"
  printf '%s' "$GLMMAYAINS_s"
}

# ask_yn "question" y|n -> returns 0 for yes.  Invalid input is asked again.
ask_yn() {
  local GLMMAYAINS_answer GLMMAYAINS_hint="[y/N]"
  [[ $2 != y ]] || GLMMAYAINS_hint="[Y/n]"
  while :; do
    read -r -p "$1 $GLMMAYAINS_hint " GLMMAYAINS_answer || die "no input"
    GLMMAYAINS_answer=$(trim "$GLMMAYAINS_answer")
    [[ -n $GLMMAYAINS_answer ]] || GLMMAYAINS_answer=$2
    case $(yesno "$GLMMAYAINS_answer") in
      yes) return 0 ;;
      no) return 1 ;;
    esac
    warn "answer yes or no"
  done
}

# confirm "question" -> returns 0 for yes.  --yes answers yes; non-interactive answers no.
confirm() {
  [[ $GLMMAYAINS_ASSUME_YES == yes ]] && return 0
  [[ $GLMMAYAINS_INTERACTIVE == yes ]] || return 1
  ask_yn "$1" n
}

# Warn about a problem and ask whether to continue.
warn_continue() {
  warn "$1"
  confirm "Continue anyway?" || die "aborted (use --yes to continue despite warnings)"
}

ask() {  # ask KEY "prompt" [extra help]: sets VAL[KEY] unless given by option/env
  local GLMMAYAINS_key=$1 GLMMAYAINS_prompt=$2 GLMMAYAINS_answer
  [[ -n ${GLMMAYAINS_FROM_USER[$GLMMAYAINS_key]:-} || $GLMMAYAINS_INTERACTIVE != yes ]] && return 0
  [[ -n ${3:-} ]] && printf '%s\n' "$3"
  read -r -p "$GLMMAYAINS_prompt [${GLMMAYAINS_VAL[$GLMMAYAINS_key]}]: " GLMMAYAINS_answer || die "no input"
  GLMMAYAINS_answer=$(trim "$GLMMAYAINS_answer")
  [[ -n $GLMMAYAINS_answer ]] && GLMMAYAINS_VAL[$GLMMAYAINS_key]=$GLMMAYAINS_answer
  return 0
}

ask_bool() {  # ask_bool KEY "question": sets VAL[KEY] to yes/no unless given by option/env
  local GLMMAYAINS_key=$1 GLMMAYAINS_default=n
  [[ -n ${GLMMAYAINS_FROM_USER[$GLMMAYAINS_key]:-} || $GLMMAYAINS_INTERACTIVE != yes ]] && return 0
  [[ ${GLMMAYAINS_VAL[$GLMMAYAINS_key]} != yes ]] || GLMMAYAINS_default=y
  if ask_yn "$2" "$GLMMAYAINS_default"; then
    GLMMAYAINS_VAL[$GLMMAYAINS_key]=yes
  else
    GLMMAYAINS_VAL[$GLMMAYAINS_key]=no
  fi
}

human() { numfmt --to=iec --suffix=B "$1"; }

service_exists() { [[ -f $GLMMAYAINS_UNIT_DIR/$1 ]]; }

# version_ge A B: is version A >= B (dotted numbers)?
version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]; }

# quant_field N [QUANT]: field N (1 Maya's setup id, 2 Maya's key, 3 download in units of
# 100 MB, 4 memory for the whole model in GB) of a quantization (default: the selected one).
quant_field() {
  local GLMMAYAINS_fields
  read -r -a GLMMAYAINS_fields <<<"${GLMMAYAINS_QUANT[${2:-${GLMMAYAINS_VAL[QUANT]}}]}"
  echo "${GLMMAYAINS_fields[$(($1 - 1))]}"
}

# quant_download [QUANT]: the download of a quantization in GB, e.g. "96.5".
quant_download() {
  local GLMMAYAINS_n
  GLMMAYAINS_n=$(quant_field 3 "${1:-}")
  echo "$((GLMMAYAINS_n / 10)).$((GLMMAYAINS_n % 10))"
}

# maya_name [QUANT]: the name Maya gives the files of a quantization in its tree: "maya-"
# and its key in lower case (maya.py, glm_config_path), e.g. maya-maya-s-v2-iq2_xxs.
maya_name() {
  local GLMMAYAINS_k
  GLMMAYAINS_k=$(quant_field 2 "${1:-}")
  echo "maya-${GLMMAYAINS_k,,}"
}

# ctx_label N: "512K" for 524288.
ctx_label() {
  if (($1 == 1048576)); then echo "1M"; else echo "$(($1 / 1024))K"; fi
}

# json_get FILE KEY...: print the value at a path of a JSON file ("-": standard input; a
# number is an index into a list); prints nothing when it is not there.  true and false are
# printed in lower case.
json_get() {
  python3 -I -c '
import json, sys
try:
    v = json.load(sys.stdin if sys.argv[1] == "-" else open(sys.argv[1], encoding="utf-8"))
    for k in sys.argv[2:]:
        v = v[int(k)] if isinstance(v, list) else v[k]
except Exception:
    sys.exit(0)
if isinstance(v, bool):
    v = "true" if v else "false"
print(json.dumps(v) if isinstance(v, (dict, list)) else v)
' "$@" 2>/dev/null || true
}

# config_arg FILE FLAG: print the value that follows FLAG in the engine arguments ("args")
# of a configuration of Maya; prints nothing when it is not there.
config_arg() {
  python3 -I -c '
import json, sys
try:
    a = json.load(open(sys.argv[1], encoding="utf-8"))["args"]
    print(a[a.index(sys.argv[2]) + 1])
except Exception:
    sys.exit(0)
' "$@" 2>/dev/null || true
}

cleanup_tmp() {
  [[ -z $GLMMAYAINS_TMP ]] || rm -rf "$GLMMAYAINS_TMP"
}

# ------------------------------------------------------------------ options

parse_args() {
  local GLMMAYAINS_opt GLMMAYAINS_key
  while (($#)); do
    GLMMAYAINS_opt=$1
    case $GLMMAYAINS_opt in
      --destdir|--user|--quant|--gpu|--ctx-size|--thinking|--drafting|--web-port|--maya-port|--interfaces|--parallel)
        (($# >= 2)) || die "$GLMMAYAINS_opt requires a value"
        GLMMAYAINS_key=${GLMMAYAINS_opt#--}; GLMMAYAINS_key=${GLMMAYAINS_key//-/_}; GLMMAYAINS_key=${GLMMAYAINS_key^^}
        GLMMAYAINS_ARG[$GLMMAYAINS_key]=$2; shift 2 ;;
      --destdir=*|--user=*|--quant=*|--gpu=*|--ctx-size=*|--thinking=*|--drafting=*|--web-port=*|--maya-port=*|--interfaces=*|--parallel=*)
        GLMMAYAINS_key=${GLMMAYAINS_opt%%=*}; GLMMAYAINS_key=${GLMMAYAINS_key#--}; GLMMAYAINS_key=${GLMMAYAINS_key//-/_}; GLMMAYAINS_key=${GLMMAYAINS_key^^}
        GLMMAYAINS_ARG[$GLMMAYAINS_key]=${GLMMAYAINS_opt#*=}; shift ;;
      --web-api-key) GLMMAYAINS_ARG[WEB_API_KEY]=yes; shift ;;
      --no-web-api-key) GLMMAYAINS_ARG[WEB_API_KEY]=no; shift ;;
      --agent-api-key) GLMMAYAINS_ARG[AGENT_API_KEY]=yes; shift ;;
      --no-agent-api-key) GLMMAYAINS_ARG[AGENT_API_KEY]=no; shift ;;
      --vision) GLMMAYAINS_ARG[VISION]=yes; shift ;;
      --no-vision) GLMMAYAINS_ARG[VISION]=no; shift ;;
      --calibrate) GLMMAYAINS_CALIBRATE=yes; shift ;;
      --no-calibrate) GLMMAYAINS_CALIBRATE=no; shift ;;
      --open-ports) GLMMAYAINS_OPEN_PORTS=yes; shift ;;
      --no-open-ports) GLMMAYAINS_OPEN_PORTS=no; shift ;;
      --yes|-y) GLMMAYAINS_ASSUME_YES=yes; shift ;;
      --uninstall) GLMMAYAINS_ACTION=uninstall; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $GLMMAYAINS_opt" ;;
    esac
  done
}

# install.conf is parsed, never sourced.
load_saved_config() {
  local GLMMAYAINS_line GLMMAYAINS_key GLMMAYAINS_value
  [[ -f $GLMMAYAINS_CONF_FILE ]] || return 0
  while IFS= read -r GLMMAYAINS_line || [[ -n $GLMMAYAINS_line ]]; do
    [[ $GLMMAYAINS_line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    GLMMAYAINS_key=${BASH_REMATCH[1]}; GLMMAYAINS_value=${BASH_REMATCH[2]}
    GLMMAYAINS_value=${GLMMAYAINS_value#\'}; GLMMAYAINS_value=${GLMMAYAINS_value%\'}
    GLMMAYAINS_SAVED[$GLMMAYAINS_key]=$GLMMAYAINS_value
  done < "$GLMMAYAINS_CONF_FILE"
}

# Merge options > environment > install.conf > default into VAL.
resolve_values() {
  local GLMMAYAINS_key GLMMAYAINS_env GLMMAYAINS_b
  for GLMMAYAINS_key in $GLMMAYAINS_KEYS; do
    GLMMAYAINS_env="GLMMAYA_$GLMMAYAINS_key"
    if [[ -n ${GLMMAYAINS_ARG[$GLMMAYAINS_key]:-} ]]; then
      GLMMAYAINS_VAL[$GLMMAYAINS_key]=${GLMMAYAINS_ARG[$GLMMAYAINS_key]}; GLMMAYAINS_FROM_USER[$GLMMAYAINS_key]=1
    elif [[ -n ${!GLMMAYAINS_env:-} ]]; then
      GLMMAYAINS_VAL[$GLMMAYAINS_key]=${!GLMMAYAINS_env}; GLMMAYAINS_FROM_USER[$GLMMAYAINS_key]=1
    elif [[ -n ${GLMMAYAINS_SAVED[$GLMMAYAINS_key]:-} ]]; then
      GLMMAYAINS_VAL[$GLMMAYAINS_key]=${GLMMAYAINS_SAVED[$GLMMAYAINS_key]}
    else
      GLMMAYAINS_VAL[$GLMMAYAINS_key]=${GLMMAYAINS_DEFAULT[$GLMMAYAINS_key]}
    fi
  done
  if [[ -z $GLMMAYAINS_OPEN_PORTS && -n ${GLMMAYA_OPEN_PORTS:-} ]]; then
    GLMMAYAINS_OPEN_PORTS=$(yesno "$GLMMAYA_OPEN_PORTS")
    [[ -n $GLMMAYAINS_OPEN_PORTS ]] || die "invalid value for GLMMAYA_OPEN_PORTS: $GLMMAYA_OPEN_PORTS (use yes or no)"
  fi
  # --calibrate is for this run only: it is not among the keys saved in install.conf.
  if [[ -z $GLMMAYAINS_CALIBRATE && -n ${GLMMAYA_CALIBRATE:-} ]]; then
    GLMMAYAINS_CALIBRATE=$(yesno "$GLMMAYA_CALIBRATE")
    [[ -n $GLMMAYAINS_CALIBRATE ]] || die "invalid value for GLMMAYA_CALIBRATE: $GLMMAYA_CALIBRATE (use yes or no)"
  fi
  [[ -n $GLMMAYAINS_CALIBRATE ]] || GLMMAYAINS_CALIBRATE=no
  for GLMMAYAINS_key in WEB_API_KEY AGENT_API_KEY VISION; do
    GLMMAYAINS_b=$(yesno "${GLMMAYAINS_VAL[$GLMMAYAINS_key]}")
    [[ -n $GLMMAYAINS_b ]] || die "invalid value for GLMMAYA_$GLMMAYAINS_key: ${GLMMAYAINS_VAL[$GLMMAYAINS_key]} (use yes or no)"
    GLMMAYAINS_VAL[$GLMMAYAINS_key]=$GLMMAYAINS_b
  done
  return 0
}

# ------------------------------------------------------------- GPU selection
#
# The model runs on one NVIDIA GPU.  It is selected by PCI address (stable across reboots)
# and converted to the nvidia-smi index, which is what Maya's --gpu takes, when Maya's
# setup is run.

# Print the makers of display controllers (nvidia, amd, intel) found on PCI.
gpu_vendors() {
  local GLMMAYAINS_dev GLMMAYAINS_class GLMMAYAINS_vendor
  for GLMMAYAINS_dev in /sys/bus/pci/devices/*; do
    [[ -r $GLMMAYAINS_dev/class && -r $GLMMAYAINS_dev/vendor ]] || continue
    GLMMAYAINS_class=$(<"$GLMMAYAINS_dev/class"); GLMMAYAINS_vendor=$(<"$GLMMAYAINS_dev/vendor")
    [[ $GLMMAYAINS_class == 0x03* ]] || continue
    case $GLMMAYAINS_vendor in
      0x10de) echo nvidia ;;
      0x1002) echo amd ;;
      0x8086) echo intel ;;
    esac
  done | sort -u
}

# normalize_pci ADDRESS: print a PCI address as dddd:bb:dd.f (lower case), or nothing if invalid.
normalize_pci() {
  local GLMMAYAINS_a=${1,,}
  [[ $GLMMAYAINS_a =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && GLMMAYAINS_a="0000:$GLMMAYAINS_a"
  [[ $GLMMAYAINS_a =~ ^([0-9a-f]{4,8}):([0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$ ]] || return 0
  printf '%04x:%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# Print "index<TAB>PCI address" for each NVIDIA GPU that answers to nvidia-smi.
nvidia_devices() {
  local GLMMAYAINS_out GLMMAYAINS_idx GLMMAYAINS_bus
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  GLMMAYAINS_out=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null) || return 0
  while IFS=, read -r GLMMAYAINS_idx GLMMAYAINS_bus; do
    GLMMAYAINS_idx=$(trim "$GLMMAYAINS_idx"); GLMMAYAINS_bus=$(normalize_pci "$(trim "$GLMMAYAINS_bus")")
    [[ $GLMMAYAINS_idx =~ ^[0-9]+$ && -n $GLMMAYAINS_bus ]] && printf '%s\t%s\n' "$GLMMAYAINS_idx" "$GLMMAYAINS_bus"
  done <<<"$GLMMAYAINS_out"
  return 0
}

# Print "nvidia<TAB>PCI address<TAB>total MiB<TAB>used MiB<TAB>name" for each GPU Maya can
# use (NVIDIA GPUs that answer to nvidia-smi).
gpu_candidates() {
  local GLMMAYAINS_out GLMMAYAINS_pci GLMMAYAINS_total GLMMAYAINS_used GLMMAYAINS_name
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  GLMMAYAINS_out=$(nvidia-smi --query-gpu=pci.bus_id,memory.total,memory.used,name --format=csv,noheader,nounits 2>/dev/null) || GLMMAYAINS_out=""
  while IFS=, read -r GLMMAYAINS_pci GLMMAYAINS_total GLMMAYAINS_used GLMMAYAINS_name; do
    GLMMAYAINS_pci=$(normalize_pci "$(trim "$GLMMAYAINS_pci")")
    GLMMAYAINS_total=$(trim "$GLMMAYAINS_total"); GLMMAYAINS_used=$(trim "$GLMMAYAINS_used")
    [[ -n $GLMMAYAINS_pci && $GLMMAYAINS_total =~ ^[0-9]+$ ]] || continue
    [[ $GLMMAYAINS_used =~ ^[0-9]+$ ]] || GLMMAYAINS_used=0
    printf 'nvidia\t%s\t%s\t%s\t%s\n' "$GLMMAYAINS_pci" "$GLMMAYAINS_total" "$GLMMAYAINS_used" "$(trim "$GLMMAYAINS_name")"
  done <<<"$GLMMAYAINS_out"
  return 0
}

# gpu_ranked CANDIDATES: sort the candidates by preference: the largest memory, then the
# most free memory, then the PCI address.
gpu_ranked() {
  [[ -n $1 ]] || return 0
  awk -F '\t' -v OFS='\t' '{print $0, $3 - $4}' <<<"$1" \
    | LC_ALL=C sort -t $'\t' -k1,1r -k3,3nr -k6,6nr -k2,2 | cut -f1-5
}

# gpu_selected CANDIDATES: print the candidate line of the GPU in VAL[GPU].
gpu_selected() {
  awk -F '\t' -v p="${GLMMAYAINS_VAL[GPU]}" '$2 == p' <<<"$1"
}

# Stop early when Maya has nothing to run on: it has no CPU-only engine.
require_gpu() {
  local GLMMAYAINS_vendors
  [[ -z $(gpu_candidates) ]] || return 0
  GLMMAYAINS_vendors=$(gpu_vendors | paste -sd, -)
  if [[ $GLMMAYAINS_vendors == *nvidia* ]]; then
    die "an NVIDIA GPU was found but nvidia-smi does not work; install the NVIDIA driver $GLMMAYAINS_NVIDIA_MIN_DRIVER or later first (e.g. sudo ubuntu-drivers install), reboot and re-run"
  fi
  die "no NVIDIA GPU was found (detected: ${GLMMAYAINS_vendors:-none}); this installer needs an NVIDIA GPU of the RTX 20 series or newer"
}

# Check VAL[GPU] (one PCI address) or choose the default GPU.
validate_gpus() {
  local GLMMAYAINS_v=${GLMMAYAINS_VAL[GPU],,} GLMMAYAINS_cands GLMMAYAINS_list GLMMAYAINS_a=""
  GLMMAYAINS_cands=$(gpu_candidates)
  [[ -n $GLMMAYAINS_cands ]] || die "no GPU that Maya can use was found"
  GLMMAYAINS_list=$(cut -f2 <<<"$GLMMAYAINS_cands")
  if [[ -n $GLMMAYAINS_v ]]; then
    [[ $GLMMAYAINS_v != all && $GLMMAYAINS_v != *,* && $GLMMAYAINS_v != *[[:space:]]* ]] \
      || die "--gpu takes one GPU: this installer runs the model on a single GPU (given: ${GLMMAYAINS_VAL[GPU]})"
    GLMMAYAINS_a=$(normalize_pci "$GLMMAYAINS_v")
    [[ -n $GLMMAYAINS_a ]] || die "invalid PCI address in --gpu: ${GLMMAYAINS_VAL[GPU]} (use e.g. 0000:03:00.0)"
    if ! grep -qx "$GLMMAYAINS_a" <<<"$GLMMAYAINS_list"; then
      if [[ -n ${GLMMAYAINS_FROM_USER[GPU]:-} ]]; then
        die "GPU $GLMMAYAINS_a is not an NVIDIA GPU that answers to nvidia-smi (usable: $(paste -sd' ' <<<"$GLMMAYAINS_list"))"
      fi
      warn "the saved GPU selection ($GLMMAYAINS_v) does not match this machine; choosing a GPU again"
      GLMMAYAINS_a=""
    fi
  fi
  [[ -n $GLMMAYAINS_a ]] || GLMMAYAINS_a=$(gpu_ranked "$GLMMAYAINS_cands" | sed -n '1p' | cut -f2)
  GLMMAYAINS_VAL[GPU]=$GLMMAYAINS_a
}

# Ask which GPU to use when two or more are usable.
prompt_gpus() {
  local GLMMAYAINS_cands GLMMAYAINS_pcis=() GLMMAYAINS_pci GLMMAYAINS_total GLMMAYAINS_used GLMMAYAINS_name GLMMAYAINS_i GLMMAYAINS_default="" GLMMAYAINS_answer
  [[ -z ${GLMMAYAINS_FROM_USER[GPU]:-} && $GLMMAYAINS_INTERACTIVE == yes ]] || return 0
  GLMMAYAINS_cands=$(gpu_candidates)
  while IFS=$'\t' read -r _ GLMMAYAINS_pci _; do
    [[ -n $GLMMAYAINS_pci ]] || continue
    GLMMAYAINS_pcis+=("$GLMMAYAINS_pci")
  done <<<"$GLMMAYAINS_cands"
  ((${#GLMMAYAINS_pcis[@]} >= 2)) || return 0
  echo "GPUs that Maya can use (the model runs on one of them):"
  GLMMAYAINS_i=0
  while IFS=$'\t' read -r _ GLMMAYAINS_pci GLMMAYAINS_total GLMMAYAINS_used GLMMAYAINS_name; do
    [[ -n $GLMMAYAINS_pci ]] || continue
    GLMMAYAINS_i=$((GLMMAYAINS_i + 1))
    printf '  %d) %s  %s (%s MiB, %s MiB in use)\n' "$GLMMAYAINS_i" "$GLMMAYAINS_pci" "$GLMMAYAINS_name" "$GLMMAYAINS_total" "$GLMMAYAINS_used"
  done <<<"$GLMMAYAINS_cands"
  for GLMMAYAINS_i in "${!GLMMAYAINS_pcis[@]}"; do
    [[ ${GLMMAYAINS_VAL[GPU]} != "${GLMMAYAINS_pcis[$GLMMAYAINS_i]}" ]] || GLMMAYAINS_default=$((GLMMAYAINS_i + 1))
  done
  while :; do
    read -r -p "GPU to use (one number) [$GLMMAYAINS_default]: " GLMMAYAINS_answer || die "no input"
    GLMMAYAINS_answer=$(trim "$GLMMAYAINS_answer")
    GLMMAYAINS_answer=${GLMMAYAINS_answer:-$GLMMAYAINS_default}
    if [[ $GLMMAYAINS_answer =~ ^[0-9]+$ ]] && ((GLMMAYAINS_answer >= 1 && GLMMAYAINS_answer <= ${#GLMMAYAINS_pcis[@]})); then
      GLMMAYAINS_VAL[GPU]=${GLMMAYAINS_pcis[$((GLMMAYAINS_answer - 1))]}
      break
    fi
    warn "answer one number between 1 and ${#GLMMAYAINS_pcis[@]}"
  done
  validate_gpus
}

gpu_label() {
  gpu_selected "$(gpu_candidates)" | awk -F '\t' '{printf "%s (%s, %s MiB)\n", $2, $5, $3}'
}

# Print the nvidia-smi index of the selected GPU, as Maya's --gpu takes it.
gpu_index() {
  local GLMMAYAINS_id
  GLMMAYAINS_id=$(awk -F '\t' -v p="${GLMMAYAINS_VAL[GPU]}" '$2 == p {print $1; exit}' <<<"$(nvidia_devices)")
  [[ -n $GLMMAYAINS_id ]] || die "GPU ${GLMMAYAINS_VAL[GPU]} was not found among the NVIDIA GPUs; re-run the installer and select the GPU again"
  echo "$GLMMAYAINS_id"
}

# Print the CUDA compute capability (e.g. 8.6) of the selected GPU, or nothing when
# nvidia-smi does not report it.
gpu_compute_cap() {
  local GLMMAYAINS_out GLMMAYAINS_pci GLMMAYAINS_cap
  GLMMAYAINS_out=$(nvidia-smi --query-gpu=pci.bus_id,compute_cap --format=csv,noheader 2>/dev/null) || return 0
  while IFS=, read -r GLMMAYAINS_pci GLMMAYAINS_cap; do
    GLMMAYAINS_pci=$(normalize_pci "$(trim "$GLMMAYAINS_pci")"); GLMMAYAINS_cap=$(trim "$GLMMAYAINS_cap")
    if [[ $GLMMAYAINS_pci == "${GLMMAYAINS_VAL[GPU]}" && $GLMMAYAINS_cap =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$GLMMAYAINS_cap"
      return 0
    fi
  done <<<"$GLMMAYAINS_out"
  return 0
}

# Print the NVIDIA driver version (the oldest if the GPUs disagree), or nothing.
nvidia_driver_version() {
  local GLMMAYAINS_v
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  GLMMAYAINS_v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || return 0
  GLMMAYAINS_v=$(grep -E '^[0-9]+(\.[0-9]+)*$' <<<"$GLMMAYAINS_v" | sort -V | head -n1 || true)
  echo "$GLMMAYAINS_v"
}

# ------------------------------------------------------- network interfaces
#
# nginx cannot bind to an interface, so the selected interfaces are turned into their
# current addresses when the configuration is written (re-run the installer if an address
# changes).  127.0.0.1 (and ::1) are always included so that local clients and the test at
# the end keep working.  ufw rules are limited with "in on IF".

# Print "interface<TAB>address address ..." for each interface with a global address
# (container and VM bridges excluded; temporary/deprecated IPv6 addresses skipped).
net_interfaces() {
  local GLMMAYAINS_out GLMMAYAINS_ifc GLMMAYAINS_fam GLMMAYAINS_addr GLMMAYAINS_rest GLMMAYAINS_order=()
  local -A GLMMAYAINS_addrs=()
  GLMMAYAINS_out=$(ip -o addr show scope global 2>/dev/null || true)
  while read -r _ GLMMAYAINS_ifc GLMMAYAINS_fam GLMMAYAINS_addr GLMMAYAINS_rest; do
    [[ -n $GLMMAYAINS_ifc && ( $GLMMAYAINS_fam == inet || $GLMMAYAINS_fam == inet6 ) ]] || continue
    [[ $GLMMAYAINS_rest == *temporary* || $GLMMAYAINS_rest == *deprecated* || $GLMMAYAINS_rest == *tentative* ]] && continue
    GLMMAYAINS_ifc=${GLMMAYAINS_ifc%%@*}
    case $GLMMAYAINS_ifc in lo|docker*|br-*|veth*|virbr*|lxdbr*|cni*) continue ;; esac
    [[ -n ${GLMMAYAINS_addrs[$GLMMAYAINS_ifc]+x} ]] || GLMMAYAINS_order+=("$GLMMAYAINS_ifc")
    GLMMAYAINS_addrs[$GLMMAYAINS_ifc]+="${GLMMAYAINS_addrs[$GLMMAYAINS_ifc]:+ }${GLMMAYAINS_addr%/*}"
  done <<<"$GLMMAYAINS_out"
  for GLMMAYAINS_ifc in "${GLMMAYAINS_order[@]}"; do
    printf '%s\t%s\n' "$GLMMAYAINS_ifc" "${GLMMAYAINS_addrs[$GLMMAYAINS_ifc]}"
  done
}

# Print the addresses of the selected interfaces, one per line (nothing for "all").
listen_addresses() {
  local GLMMAYAINS_list GLMMAYAINS_ifc GLMMAYAINS_addr_list=()
  [[ ${GLMMAYAINS_VAL[INTERFACES]} != all ]] || return 0
  GLMMAYAINS_list=$(net_interfaces)
  for GLMMAYAINS_ifc in ${GLMMAYAINS_VAL[INTERFACES]//,/ }; do
    read -r -a GLMMAYAINS_addr_list <<<"$(awk -F '\t' -v i="$GLMMAYAINS_ifc" '$1 == i {print $2}' <<<"$GLMMAYAINS_list")"
    ((${#GLMMAYAINS_addr_list[@]} == 0)) || printf '%s\n' "${GLMMAYAINS_addr_list[@]}"
  done
}

interfaces_label() {
  local GLMMAYAINS_list GLMMAYAINS_ifc GLMMAYAINS_out=""
  if [[ ${GLMMAYAINS_VAL[INTERFACES]} == all ]]; then echo "all"; return 0; fi
  GLMMAYAINS_list=$(net_interfaces)
  for GLMMAYAINS_ifc in ${GLMMAYAINS_VAL[INTERFACES]//,/ }; do
    GLMMAYAINS_out+="${GLMMAYAINS_out:+, }$GLMMAYAINS_ifc ($(awk -F '\t' -v i="$GLMMAYAINS_ifc" '$1 == i {gsub(/ /, ", ", $2); print $2}' <<<"$GLMMAYAINS_list"))"
  done
  echo "$GLMMAYAINS_out (and 127.0.0.1)"
}

validate_interfaces() {
  local GLMMAYAINS_v=${GLMMAYAINS_VAL[INTERFACES]} GLMMAYAINS_list GLMMAYAINS_ifc GLMMAYAINS_out=()
  if [[ -z $GLMMAYAINS_v || ${GLMMAYAINS_v,,} == all ]]; then GLMMAYAINS_VAL[INTERFACES]=all; return 0; fi
  GLMMAYAINS_list=$(net_interfaces | cut -f1)
  for GLMMAYAINS_ifc in ${GLMMAYAINS_v//,/ }; do
    [[ $GLMMAYAINS_ifc =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "invalid interface name: $GLMMAYAINS_ifc"
    if ! grep -qxF "$GLMMAYAINS_ifc" <<<"$GLMMAYAINS_list"; then
      if [[ -n ${GLMMAYAINS_FROM_USER[INTERFACES]:-} ]]; then
        die "interface $GLMMAYAINS_ifc has no global address (available: $(paste -sd' ' <<<"$GLMMAYAINS_list"))"
      fi
      warn "the saved interface selection ($GLMMAYAINS_v) does not match this machine; listening on all interfaces"
      GLMMAYAINS_VAL[INTERFACES]=all; return 0
    fi
    [[ " ${GLMMAYAINS_out[*]} " == *" $GLMMAYAINS_ifc "* ]] || GLMMAYAINS_out+=("$GLMMAYAINS_ifc")
  done
  GLMMAYAINS_VAL[INTERFACES]=$(IFS=,; echo "${GLMMAYAINS_out[*]}")
}

# Ask on which interfaces to accept connections when two or more have addresses.
prompt_interfaces() {
  local GLMMAYAINS_list GLMMAYAINS_names=() GLMMAYAINS_ifc GLMMAYAINS_addrs GLMMAYAINS_i GLMMAYAINS_default="" GLMMAYAINS_answer GLMMAYAINS_tok GLMMAYAINS_sel=() GLMMAYAINS_ok
  [[ -z ${GLMMAYAINS_FROM_USER[INTERFACES]:-} && $GLMMAYAINS_INTERACTIVE == yes ]] || return 0
  GLMMAYAINS_list=$(net_interfaces)
  [[ -n $GLMMAYAINS_list ]] || return 0
  while IFS=$'\t' read -r GLMMAYAINS_ifc GLMMAYAINS_addrs; do GLMMAYAINS_names+=("$GLMMAYAINS_ifc"); done <<<"$GLMMAYAINS_list"
  ((${#GLMMAYAINS_names[@]} >= 2)) || return 0
  echo "Network interfaces on which the web server accepts connections from other hosts"
  echo "(127.0.0.1 is always available on this machine):"
  GLMMAYAINS_i=0
  while IFS=$'\t' read -r GLMMAYAINS_ifc GLMMAYAINS_addrs; do
    GLMMAYAINS_i=$((GLMMAYAINS_i + 1))
    printf '  %d) %-12s %s\n' "$GLMMAYAINS_i" "$GLMMAYAINS_ifc" "${GLMMAYAINS_addrs// /, }"
  done <<<"$GLMMAYAINS_list"
  if [[ ${GLMMAYAINS_VAL[INTERFACES]} == all ]]; then
    GLMMAYAINS_default=all
  else
    for GLMMAYAINS_i in "${!GLMMAYAINS_names[@]}"; do
      [[ ",${GLMMAYAINS_VAL[INTERFACES]}," == *",${GLMMAYAINS_names[$GLMMAYAINS_i]},"* ]] && GLMMAYAINS_default+="${GLMMAYAINS_default:+,}$((GLMMAYAINS_i + 1))"
    done
  fi
  while :; do
    read -r -p "Interfaces (all, or numbers such as 1,2) [$GLMMAYAINS_default]: " GLMMAYAINS_answer || die "no input"
    GLMMAYAINS_answer=$(trim "$GLMMAYAINS_answer")
    GLMMAYAINS_answer=${GLMMAYAINS_answer:-$GLMMAYAINS_default}
    if [[ ${GLMMAYAINS_answer,,} == all ]]; then GLMMAYAINS_VAL[INTERFACES]=all; return 0; fi
    GLMMAYAINS_sel=(); GLMMAYAINS_ok=yes
    for GLMMAYAINS_tok in ${GLMMAYAINS_answer//,/ }; do
      if [[ $GLMMAYAINS_tok =~ ^[0-9]+$ ]] && ((GLMMAYAINS_tok >= 1 && GLMMAYAINS_tok <= ${#GLMMAYAINS_names[@]})); then
        GLMMAYAINS_ifc=${GLMMAYAINS_names[$((GLMMAYAINS_tok - 1))]}
        [[ " ${GLMMAYAINS_sel[*]} " == *" $GLMMAYAINS_ifc "* ]] || GLMMAYAINS_sel+=("$GLMMAYAINS_ifc")
      else
        GLMMAYAINS_ok=no
      fi
    done
    if [[ $GLMMAYAINS_ok == yes && ${#GLMMAYAINS_sel[@]} -gt 0 ]]; then
      GLMMAYAINS_VAL[INTERFACES]=$(IFS=,; echo "${GLMMAYAINS_sel[*]}")
      return 0
    fi
    warn "answer all, or numbers between 1 and ${#GLMMAYAINS_names[@]} separated by commas"
  done
}

# ------------------------------------------------------------------ prompts

# Does Maya's own setup recommend Maya-S24 instead of Maya-S here?  Its rule: no GPU has
# more than 24.5 GB.  The quantization is asked before the GPU, so every usable GPU counts,
# unless --gpu names one.
s24_recommended() {
  local GLMMAYAINS_only="" GLMMAYAINS_pci GLMMAYAINS_total GLMMAYAINS_n=0
  [[ -z ${GLMMAYAINS_FROM_USER[GPU]:-} ]] || GLMMAYAINS_only=$(normalize_pci "${GLMMAYAINS_VAL[GPU]}")
  while IFS=$'\t' read -r _ GLMMAYAINS_pci GLMMAYAINS_total _; do
    [[ -n $GLMMAYAINS_pci ]] || continue
    [[ -z ${GLMMAYAINS_FROM_USER[GPU]:-} || $GLMMAYAINS_pci == "$GLMMAYAINS_only" ]] || continue
    ((GLMMAYAINS_total <= GLMMAYAINS_S24_MAX_VRAM_MIB)) || return 1
    GLMMAYAINS_n=$((GLMMAYAINS_n + 1))
  done <<<"$(gpu_candidates)"
  ((GLMMAYAINS_n > 0))
}

prompt_values() {
  local GLMMAYAINS_q GLMMAYAINS_list=""
  [[ $GLMMAYAINS_INTERACTIVE == yes ]] || return 0
  ask DESTDIR "Install directory (becomes the home directory of the service user)"
  ask USER "Service user"
  if [[ -z ${GLMMAYAINS_FROM_USER[QUANT]:-} ]]; then
    for GLMMAYAINS_q in $GLMMAYAINS_QUANTS; do
      GLMMAYAINS_list+=$(printf '  %-9s download %5s GB, GPU memory + RAM for the whole model about %3s GB' "$GLMMAYAINS_q" "$(quant_download "$GLMMAYAINS_q")" "$(quant_field 4 "$GLMMAYAINS_q")")$'\n'
    done
    if s24_recommended; then
      GLMMAYAINS_list+="Maya's own setup recommends Maya-S24 instead of Maya-S for a GPU of 24 GB or less (about 14% faster there)."$'\n'
    fi
  fi
  ask QUANT "Quantization" "Quantizations of $GLMMAYAINS_MODEL by Project Maya (larger is closer to the original and needs more memory):"$'\n'"${GLMMAYAINS_list%$'\n'}"
  ask CTX_SIZE "Maximum context in tokens" "Context sizes: 262144 (256K), 524288 (512K), 786432 (768K; not mentioned by the Maya project), 1048576 (1M)"
  ask THINKING "Thinking level (none, low, high, max)"
  ask DRAFTING "Drafting (skip, measure, on)" "Drafting with the DFlash2 drafter, whose license is $GLMMAYAINS_DRAFTER_LICENSE:
  skip     no drafter; nothing is downloaded or measured
  measure  Maya downloads it (0.7 GB), measures it (5 to 20 minutes) and keeps it only if it is faster
  on       Maya downloads it and uses it without measuring"
  ask WEB_PORT "Web server port"
  ask_bool WEB_API_KEY "Require the API key for the web chat page?"
  ask_bool AGENT_API_KEY "Require the API key for the API used by coding agents?"
}

validate() {
  local GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_p GLMMAYAINS_q GLMMAYAINS_found="" GLMMAYAINS_t
  [[ $GLMMAYAINS_d == /* ]] || die "destdir must be an absolute path: $GLMMAYAINS_d"
  [[ $GLMMAYAINS_d =~ ^/[A-Za-z0-9._/-]+$ && $GLMMAYAINS_d != *//* && $GLMMAYAINS_d != */./* && $GLMMAYAINS_d != */../* && $GLMMAYAINS_d != */. && $GLMMAYAINS_d != */.. ]] \
    || die "destdir may contain only letters, digits and . _ - / : $GLMMAYAINS_d"
  GLMMAYAINS_d=${GLMMAYAINS_d%/}; GLMMAYAINS_VAL[DESTDIR]=$GLMMAYAINS_d
  case $GLMMAYAINS_d in
    ""|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/*|/var|/var/lib|/etc/*|/proc/*|/sys/*|/dev/*|/run/*|/boot/*|/root/*)
      die "destdir must not be a system directory: $GLMMAYAINS_d" ;;
  esac
  [[ ${GLMMAYAINS_VAL[USER]} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: ${GLMMAYAINS_VAL[USER]}"
  [[ ${GLMMAYAINS_VAL[USER]} != root ]] || die "the service user must not be root"
  for GLMMAYAINS_q in $GLMMAYAINS_QUANTS; do
    [[ ${GLMMAYAINS_q,,} != "${GLMMAYAINS_VAL[QUANT],,}" ]] || GLMMAYAINS_found=$GLMMAYAINS_q
  done
  [[ -n $GLMMAYAINS_found ]] || die "quantization must be one of: $GLMMAYAINS_QUANTS"
  GLMMAYAINS_VAL[QUANT]=$GLMMAYAINS_found
  [[ ${GLMMAYAINS_VAL[CTX_SIZE]} =~ ^[0-9]{1,7}$ ]] || die "context size must be one of: $GLMMAYAINS_CTX_SIZES (given: ${GLMMAYAINS_VAL[CTX_SIZE]})"
  GLMMAYAINS_VAL[CTX_SIZE]=$((10#${GLMMAYAINS_VAL[CTX_SIZE]}))
  [[ " $GLMMAYAINS_CTX_SIZES " == *" ${GLMMAYAINS_VAL[CTX_SIZE]} "* ]] || die "context size must be one of: $GLMMAYAINS_CTX_SIZES (given: ${GLMMAYAINS_VAL[CTX_SIZE]})"
  GLMMAYAINS_t=${GLMMAYAINS_VAL[THINKING],,}
  [[ $GLMMAYAINS_t =~ ^[a-z]+$ && " $GLMMAYAINS_THINKING_LEVELS " == *" $GLMMAYAINS_t "* ]] \
    || die "thinking level must be one of: $GLMMAYAINS_THINKING_LEVELS (given: ${GLMMAYAINS_VAL[THINKING]})"
  GLMMAYAINS_VAL[THINKING]=$GLMMAYAINS_t
  GLMMAYAINS_VAL[DRAFTING]=${GLMMAYAINS_VAL[DRAFTING],,}
  [[ ${GLMMAYAINS_VAL[DRAFTING]} =~ ^[a-z]+$ && " $GLMMAYAINS_DRAFTING_MODES " == *" ${GLMMAYAINS_VAL[DRAFTING]} "* ]] \
    || die "drafting must be one of: $GLMMAYAINS_DRAFTING_MODES (given: ${GLMMAYAINS_VAL[DRAFTING]})"
  [[ ${GLMMAYAINS_VAL[PARALLEL]} =~ ^[1-8]$ ]] || die "parallel must be a number from 1 to 8: ${GLMMAYAINS_VAL[PARALLEL]}"
  # Maya's engine decodes without the drafter when it answers several requests at once.
  [[ ${GLMMAYAINS_VAL[DRAFTING]} == skip || ${GLMMAYAINS_VAL[PARALLEL]} == 1 ]] \
    || die "--drafting ${GLMMAYAINS_VAL[DRAFTING]} cannot be combined with --parallel ${GLMMAYAINS_VAL[PARALLEL]}: the DFlash2 drafter works for one request at a time"
  for GLMMAYAINS_p in WEB_PORT MAYA_PORT; do
    [[ ${GLMMAYAINS_VAL[$GLMMAYAINS_p]} =~ ^[0-9]{1,5}$ ]] || die "invalid port number: ${GLMMAYAINS_VAL[$GLMMAYAINS_p]}"
    GLMMAYAINS_VAL[$GLMMAYAINS_p]=$((10#${GLMMAYAINS_VAL[$GLMMAYAINS_p]}))
    ((GLMMAYAINS_VAL[$GLMMAYAINS_p] >= 1 && GLMMAYAINS_VAL[$GLMMAYAINS_p] <= 65535)) || die "invalid port number: ${GLMMAYAINS_VAL[$GLMMAYAINS_p]}"
  done
  ((GLMMAYAINS_VAL[WEB_PORT] != GLMMAYAINS_VAL[MAYA_PORT])) || die "the web server port and the Maya port must differ"
  validate_gpus
  validate_interfaces
}

key_label() { if [[ $1 == yes ]]; then echo "required"; else echo "not required"; fi; }

thinking_label() { echo "${GLMMAYAINS_VAL[THINKING]}"; }

# The drafter's license is shown wherever the drafter is selected.
drafting_label() {
  case ${GLMMAYAINS_VAL[DRAFTING]} in
    measure) echo "measure (DFlash2 drafter, kept only if it is faster; license: $GLMMAYAINS_DRAFTER_LICENSE)" ;;
    on) echo "on (DFlash2 drafter; license: $GLMMAYAINS_DRAFTER_LICENSE)" ;;
    *) echo "skip (no drafter)" ;;
  esac
}

show_summary() {
  local GLMMAYAINS_ctx=${GLMMAYAINS_VAL[CTX_SIZE]} GLMMAYAINS_note="" GLMMAYAINS_vision="yes (image encoder; ffmpeg from apt for video)" GLMMAYAINS_tuning="no" GLMMAYAINS_others
  [[ $GLMMAYAINS_ctx != 786432 ]] || GLMMAYAINS_note="; not mentioned by the Maya project"
  [[ ${GLMMAYAINS_VAL[VISION]} == yes ]] || GLMMAYAINS_vision="no (text only)"
  [[ $GLMMAYAINS_CALIBRATE != yes ]] || GLMMAYAINS_tuning="yes (Maya's --calibrate, 10 to 15 minutes; this run only)"
  cat <<EOF

Installation settings:
  Install directory    : ${GLMMAYAINS_VAL[DESTDIR]}
  Service user         : ${GLMMAYAINS_VAL[USER]}
  Model                : $GLMMAYAINS_MODEL ${GLMMAYAINS_VAL[QUANT]} (download $(quant_download) GB)
  Engine               : Project Maya $GLMMAYAINS_MAYA_VERSION (compiled on this machine with CUDA 13)
  GPU                  : $(gpu_label)
  Context size         : $GLMMAYAINS_ctx tokens ($(ctx_label "$GLMMAYAINS_ctx")$GLMMAYAINS_note)
  Thinking             : $(thinking_label)
  Drafting             : $(drafting_label)
  Parallel requests    : ${GLMMAYAINS_VAL[PARALLEL]}
  Pictures             : $GLMMAYAINS_vision
  Tuning               : $GLMMAYAINS_tuning
  Web server           : port ${GLMMAYAINS_VAL[WEB_PORT]} (nginx)
  Listen on            : $(interfaces_label)
  Open ports in ufw    : $(ufw_label)
  Maya                 : 127.0.0.1:${GLMMAYAINS_VAL[MAYA_PORT]}
  API key, web page    : $(key_label "${GLMMAYAINS_VAL[WEB_API_KEY]}")
  API key, agents      : $(key_label "${GLMMAYAINS_VAL[AGENT_API_KEY]}")
  API key, management  : required (always)
EOF
  GLMMAYAINS_others=$(exclusive_units_in_use | paste -sd, -)
  if [[ -n $GLMMAYAINS_others ]]; then
    echo "  Other services       : ${GLMMAYAINS_others//,/, } will be stopped and disabled"
  fi
  echo
  if [[ $GLMMAYAINS_INTERACTIVE == yes && $GLMMAYAINS_ASSUME_YES != yes ]]; then
    confirm "Proceed with the installation?" || die "aborted"
  fi
}

# -------------------------------------------------------------- preflight

check_platform() {
  [[ $EUID -eq 0 ]] || die "run as root (e.g. sudo bash $0)"
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported (found $(uname -m))"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  local GLMMAYAINS_id GLMMAYAINS_version
  # Parse instead of sourcing, so that os-release cannot clash with our variables.
  GLMMAYAINS_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  GLMMAYAINS_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  [[ $GLMMAYAINS_id == ubuntu && $GLMMAYAINS_version == 26.04 ]] || die "only Ubuntu 26.04 is supported (found ${GLMMAYAINS_id:-?} ${GLMMAYAINS_version:-?})"
  if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    die "Ubuntu on WSL is not supported"
  fi
  command -v systemctl >/dev/null || die "systemd is required"
}

# port_in_use_by_others PORT [UNIT]: is TCP port PORT used by a process that does not
# belong to the systemd unit UNIT?
port_in_use_by_others() {
  local GLMMAYAINS_port=$1 GLMMAYAINS_unit=${2:-} GLMMAYAINS_listeners GLMMAYAINS_pids GLMMAYAINS_pid
  GLMMAYAINS_listeners=$(ss -Hltnp "sport = :$GLMMAYAINS_port" 2>/dev/null) || GLMMAYAINS_listeners=""
  [[ -n $GLMMAYAINS_listeners ]] || return 1
  [[ -n $GLMMAYAINS_unit ]] || return 0
  GLMMAYAINS_pids=$(grep -o 'pid=[0-9]*' <<<"$GLMMAYAINS_listeners" | cut -d= -f2 | sort -u || true)
  [[ -n $GLMMAYAINS_pids ]] || return 0
  for GLMMAYAINS_pid in $GLMMAYAINS_pids; do
    grep -qsF "/$GLMMAYAINS_unit" "/proc/$GLMMAYAINS_pid/cgroup" || return 0
  done
  return 1
}

port_free() { [[ -z $(ss -Hltn "sport = :$1" 2>/dev/null || true) ]]; }

existing_dir() {  # nearest existing ancestor of $1
  local GLMMAYAINS_d=$1
  while [[ ! -d $GLMMAYAINS_d ]]; do GLMMAYAINS_d=$(dirname "$GLMMAYAINS_d"); done
  echo "$GLMMAYAINS_d"
}

preflight() {
  local GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]} GLMMAYAINS_unit="" GLMMAYAINS_home GLMMAYAINS_need GLMMAYAINS_have GLMMAYAINS_avail GLMMAYAINS_mem GLMMAYAINS_vram GLMMAYAINS_driver GLMMAYAINS_cap GLMMAYAINS_ctx_bytes GLMMAYAINS_ctx_gb GLMMAYAINS_many="" GLMMAYAINS_note=""
  info "Checking prerequisites"

  # Ports.  The web port may be held by nginx only if it was ours before; the Maya port
  # only by our own service.
  [[ -f $GLMMAYAINS_NGINX_LINK && ${GLMMAYAINS_SAVED[WEB_PORT]:-} == "${GLMMAYAINS_VAL[WEB_PORT]}" ]] && GLMMAYAINS_unit=nginx.service
  if port_in_use_by_others "${GLMMAYAINS_VAL[WEB_PORT]}" "$GLMMAYAINS_unit"; then
    die "TCP port ${GLMMAYAINS_VAL[WEB_PORT]} is already in use: $(ss -Hltnp "sport = :${GLMMAYAINS_VAL[WEB_PORT]}" | head -n1)"
  fi
  if port_in_use_by_others "${GLMMAYAINS_VAL[MAYA_PORT]}" "$GLMMAYAINS_UNIT"; then
    die "TCP port ${GLMMAYAINS_VAL[MAYA_PORT]} is already in use: $(ss -Hltnp "sport = :${GLMMAYAINS_VAL[MAYA_PORT]}" | head -n1)"
  fi

  # Existing destdir must be empty or a previous installation (uninstall removes it).
  if [[ -d $GLMMAYAINS_d && ! -e $GLMMAYAINS_d/$GLMMAYAINS_MARKER ]] && [[ -n $(ls -A "$GLMMAYAINS_d") ]]; then
    die "$GLMMAYAINS_d exists and is not empty; choose another directory"
  fi

  # Maya's setup and maya.sh run as the service user with destdir as its home directory.
  if id -u "$GLMMAYAINS_u" >/dev/null 2>&1; then
    GLMMAYAINS_home=$(getent passwd "$GLMMAYAINS_u" | cut -d: -f6)
    [[ ${GLMMAYAINS_home%/} == "$GLMMAYAINS_d" ]] \
      || die "user $GLMMAYAINS_u exists and its home directory is ${GLMMAYAINS_home:-unset}, not $GLMMAYAINS_d; choose another user name or destdir (or change it with: usermod -d $GLMMAYAINS_d $GLMMAYAINS_u)"
  fi

  grep -qw avx2 /proc/cpuinfo || warn_continue "this CPU does not report AVX2, which this installer expects (Maya warns about such CPUs)"

  # GPU driver and GPU.  Drivers are never installed here.
  GLMMAYAINS_driver=$(nvidia_driver_version)
  [[ -n $GLMMAYAINS_driver ]] || die "nvidia-smi does not work; install the NVIDIA driver first (e.g. sudo ubuntu-drivers install), reboot and re-run"
  version_ge "$GLMMAYAINS_driver" "$GLMMAYAINS_NVIDIA_MIN_DRIVER" \
    || die "NVIDIA driver $GLMMAYAINS_driver is too old: the engine is compiled with CUDA 13, which needs driver $GLMMAYAINS_NVIDIA_MIN_DRIVER or later; update the driver (e.g. sudo ubuntu-drivers install), reboot and re-run"
  GLMMAYAINS_cap=$(gpu_compute_cap)
  if [[ -z $GLMMAYAINS_cap ]]; then
    [[ ${GLMMAYAINS_VAL[DRAFTING]} == skip ]] || GLMMAYAINS_note="; the DFlash2 drafter needs $GLMMAYAINS_DRAFTER_MIN_COMPUTE_CAP or higher (RTX 30 series or newer)"
    warn "nvidia-smi does not report the compute capability of GPU ${GLMMAYAINS_VAL[GPU]}; CUDA 13 needs $GLMMAYAINS_MIN_COMPUTE_CAP or higher (RTX 20 series or newer)$GLMMAYAINS_note"
  else
    version_ge "$GLMMAYAINS_cap" "$GLMMAYAINS_MIN_COMPUTE_CAP" \
      || die "GPU ${GLMMAYAINS_VAL[GPU]} has compute capability $GLMMAYAINS_cap: CUDA 13 cannot compile for less than $GLMMAYAINS_MIN_COMPUTE_CAP (an RTX 20 series GPU or newer is needed)"
    # Maya does not offer the drafter below this, and does not check it when --draft is given.
    [[ ${GLMMAYAINS_VAL[DRAFTING]} == skip ]] || version_ge "$GLMMAYAINS_cap" "$GLMMAYAINS_DRAFTER_MIN_COMPUTE_CAP" \
      || die "GPU ${GLMMAYAINS_VAL[GPU]} has compute capability $GLMMAYAINS_cap: the DFlash2 drafter (--drafting ${GLMMAYAINS_VAL[DRAFTING]}) needs $GLMMAYAINS_DRAFTER_MIN_COMPUTE_CAP or higher (an RTX 30 series GPU or newer); use --drafting skip"
  fi
  info "NVIDIA driver $GLMMAYAINS_driver, GPU $(gpu_label)${GLMMAYAINS_cap:+, compute capability $GLMMAYAINS_cap}"

  # Disk space: model files and the rest, minus what destdir already holds.
  GLMMAYAINS_need=$(($(quant_field 3) * 100 * 1000 * 1000 + GLMMAYAINS_EXTRA_DISK))
  GLMMAYAINS_have=0
  [[ ! -d $GLMMAYAINS_d ]] || GLMMAYAINS_have=$(($(du -sk "$GLMMAYAINS_d" 2>/dev/null | cut -f1) * 1024))
  GLMMAYAINS_need=$((GLMMAYAINS_need - GLMMAYAINS_have))
  GLMMAYAINS_avail=$(($(df --output=avail -k "$(existing_dir "$GLMMAYAINS_d")" | tail -n1) * 1024))
  if ((GLMMAYAINS_avail < GLMMAYAINS_need)); then
    warn_continue "not enough free disk space in $(existing_dir "$GLMMAYAINS_d"): $(human "$GLMMAYAINS_avail") available, about $(human "$GLMMAYAINS_need") more needed for ${GLMMAYAINS_VAL[QUANT]}"
  fi

  # Memory (MiB): RAM, and RAM plus the memory of the selected GPU against what holds the
  # whole model and the context, which the engine keeps in RAM for each conversation.
  GLMMAYAINS_mem=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))
  GLMMAYAINS_vram=$(gpu_selected "$(gpu_candidates)" | cut -f3)
  [[ $GLMMAYAINS_vram =~ ^[0-9]+$ ]] || GLMMAYAINS_vram=0
  GLMMAYAINS_ctx_bytes=$((GLMMAYAINS_VAL[CTX_SIZE] * GLMMAYAINS_CTX_BYTES * GLMMAYAINS_VAL[PARALLEL]))
  GLMMAYAINS_ctx_gb="$((GLMMAYAINS_ctx_bytes / 1000000000)).$((GLMMAYAINS_ctx_bytes / 100000000 % 10))"
  ((GLMMAYAINS_VAL[PARALLEL] == 1)) || GLMMAYAINS_many=" for ${GLMMAYAINS_VAL[PARALLEL]} conversations"
  if ((GLMMAYAINS_mem < GLMMAYAINS_MIN_RAM_GB * 1024)); then
    warn_continue "this machine has $((GLMMAYAINS_mem / 1024)) GB of RAM; Maya names $GLMMAYAINS_MIN_RAM_GB GB as the minimum"
  elif ((GLMMAYAINS_mem + GLMMAYAINS_vram < $(quant_field 4) * 1024 + GLMMAYAINS_ctx_bytes / 1048576)); then
    warn "this machine has $((GLMMAYAINS_mem / 1024)) GB of RAM and $((GLMMAYAINS_vram / 1024)) GB of GPU memory; ${GLMMAYAINS_VAL[QUANT]} is held whole from about $(quant_field 4) GB, and a context of $(ctx_label "${GLMMAYAINS_VAL[CTX_SIZE]}") takes about $GLMMAYAINS_ctx_gb GB of RAM more$GLMMAYAINS_many. Maya will keep as many experts as fit and read the rest from the SSD, which is much slower."
  fi
}

# ---------------------------------------------------------------- install

install_packages() {
  local GLMMAYAINS_missing=() GLMMAYAINS_p GLMMAYAINS_wanted=$GLMMAYAINS_BASE_PACKAGES
  [[ ${GLMMAYAINS_VAL[VISION]} != yes ]] || GLMMAYAINS_wanted+=" $GLMMAYAINS_VISION_PACKAGES"
  for GLMMAYAINS_p in $GLMMAYAINS_wanted; do
    [[ $(dpkg-query -W -f='${Status}' "$GLMMAYAINS_p" 2>/dev/null || true) == "install ok installed" ]] || GLMMAYAINS_missing+=("$GLMMAYAINS_p")
  done
  if ((${#GLMMAYAINS_missing[@]} == 0)); then
    info "Required packages are already installed"
  else
    info "Installing packages: ${GLMMAYAINS_missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${GLMMAYAINS_missing[@]}" \
      || die "apt-get install failed (cuda-toolkit-13 is in the multiverse component, the others in main and universe; are they enabled?)"
  fi
  # Maya looks for nvcc in PATH and in /usr/local/cuda*/bin.
  if ! command -v nvcc >/dev/null 2>&1 && [[ -z $(compgen -G '/usr/local/cuda*/bin/nvcc' || true) ]]; then
    die "nvcc was not found after installing cuda-toolkit-13 (expected /usr/local/cuda-13.*/bin/nvcc); Maya cannot compile its engine without it"
  fi
}

# The home directory of the service user is destdir.
ensure_user() {
  local GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]}
  if id -u "$GLMMAYAINS_u" >/dev/null 2>&1; then
    info "Using existing user $GLMMAYAINS_u"
  else
    info "Creating system user $GLMMAYAINS_u"
    useradd --system --user-group --no-create-home --home-dir "${GLMMAYAINS_VAL[DESTDIR]}" --shell /usr/sbin/nologin "$GLMMAYAINS_u"
  fi
}

# Everything in destdir belongs to the service user: Maya writes its configuration, its
# logs, .venv and the build inside its own tree, and the packs inside the model folders.
prepare_destdir() {
  local GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]}
  install -d -m 0755 "$GLMMAYAINS_d" "$GLMMAYAINS_d/models"
  touch "$GLMMAYAINS_d/$GLMMAYAINS_MARKER"
  chown -R "$GLMMAYAINS_u:$GLMMAYAINS_u" "$GLMMAYAINS_d"
}

# run_as USER HOME COMMAND [ARGS...]: run a command as the service user with a clean
# environment, HOME set to destdir and Maya's update check off.  The API key is never
# passed here: the service reads it from maya.env.
run_as() {
  local GLMMAYAINS_user=$1 GLMMAYAINS_home=$2
  shift 2
  (
    cd "$GLMMAYAINS_home" || exit 1
    # PYTHONUNBUFFERED: the progress of Maya's setup is shown as it happens (its output is a pipe).
    exec env -i "HOME=$GLMMAYAINS_home" "USER=$GLMMAYAINS_user" "LOGNAME=$GLMMAYAINS_user" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 "TERM=${TERM:-dumb}" MAYA_UPDATE_CHECK=0 PYTHONUNBUFFERED=1 \
      runuser -u "$GLMMAYAINS_user" -- "$@"
  )
}

maya_tree() { echo "${GLMMAYAINS_VAL[DESTDIR]}/project-maya"; }

# maya_config [QUANT], maya_log [QUANT]: the engine configuration Maya's setup writes for a
# quantization (default: the selected one) and the engine log beside it.
maya_config() { echo "$(maya_tree)/$(maya_name "${1:-}").json"; }
maya_log() { echo "$(maya_tree)/$(maya_name "${1:-}").log"; }

# Maya's setup and the engine need the GPU and the RAM, so the service is stopped first.
stop_service() {
  service_exists "$GLMMAYAINS_UNIT" || return 0
  # Always: a unit waiting for its automatic restart is neither active nor failed.
  info "Stopping $GLMMAYAINS_UNIT"
  systemctl stop "$GLMMAYAINS_UNIT" || die "cannot stop $GLMMAYAINS_UNIT"
}

# unit_in_use UNIT: is a unit of another installer running, starting, waiting for its
# automatic restart, or enabled at boot?
unit_in_use() {
  service_exists "$1" || return 1
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then return 0; fi
  case $(systemctl show -p ActiveState --value "$1" 2>/dev/null || true) in
    ""|inactive|failed) return 1 ;;
  esac
  return 0
}

# Print the units of the other installers that are in use, one per line.
exclusive_units_in_use() {
  local GLMMAYAINS_x
  for GLMMAYAINS_x in $GLMMAYAINS_EXCLUSIVE_UNITS; do
    if unit_in_use "$GLMMAYAINS_x"; then echo "$GLMMAYAINS_x"; fi
  done
}

# deepseek-maya and qwen-strata are not meant to run at the same time as this service: each
# needs a GPU and most of the RAM.  They are stopped and disabled before Maya's setup;
# --uninstall prints how to enable them again.  Their files are never touched.
disable_exclusive_units() {
  local GLMMAYAINS_x
  for GLMMAYAINS_x in $GLMMAYAINS_EXCLUSIVE_UNITS; do
    unit_in_use "$GLMMAYAINS_x" || continue
    info "Stopping and disabling $GLMMAYAINS_x (it does not run together with $GLMMAYAINS_UNIT)"
    systemctl disable --now "$GLMMAYAINS_x" || die "cannot stop $GLMMAYAINS_x"
  done
}

# Maya's speed calibration (--drafting measure) and its tuning (--calibrate) need the GPU to
# themselves: with more than 1 GiB of its memory in use (a desktop session is enough) Maya
# skips them with a warning and still ends without an error.  Checked after the services
# were stopped and before the hours of Maya's setup.
gpu_busy_check() {
  local GLMMAYAINS_used GLMMAYAINS_what="" GLMMAYAINS_then=""
  if [[ ${GLMMAYAINS_VAL[DRAFTING]} == measure ]]; then
    GLMMAYAINS_what="its speed calibration (--drafting measure)"
    GLMMAYAINS_then="; the installer then stops after Maya's setup, because the drafter was not measured"
  fi
  [[ $GLMMAYAINS_CALIBRATE != yes ]] || GLMMAYAINS_what+="${GLMMAYAINS_what:+ and }its tuning (--calibrate)"
  [[ -n $GLMMAYAINS_what ]] || return 0
  GLMMAYAINS_used=$(gpu_selected "$(gpu_candidates)" | cut -f4)
  [[ $GLMMAYAINS_used =~ ^[0-9]+$ ]] || return 0
  ((GLMMAYAINS_used > GLMMAYAINS_GPU_BUSY_MIB)) || return 0
  warn_continue "GPU ${GLMMAYAINS_VAL[GPU]} has $GLMMAYAINS_used MiB of its memory in use (a desktop session or another program?). Maya skips $GLMMAYAINS_what when more than $GLMMAYAINS_GPU_BUSY_MIB MiB is in use$GLMMAYAINS_then. Free the GPU, or re-run without these options."
}

wait_port_free() {  # wait_port_free PORT SECONDS
  local GLMMAYAINS_start=$SECONDS
  until port_free "$1"; do
    ((SECONDS - GLMMAYAINS_start < $2)) || return 1
    sleep 1
  done
}

# Download the archive of the pinned tag and extract it into <destdir>/project-maya.  A
# tree of the pinned version is reused (with its .venv, build and configuration).
install_maya() {
  local GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]} GLMMAYAINS_tree GLMMAYAINS_new GLMMAYAINS_old GLMMAYAINS_tar GLMMAYAINS_have="" GLMMAYAINS_f
  GLMMAYAINS_tree=$(maya_tree)
  [[ ! -f $GLMMAYAINS_tree/VERSION ]] || GLMMAYAINS_have=$(tr -d '[:space:]' < "$GLMMAYAINS_tree/VERSION")
  if [[ $GLMMAYAINS_have == "$GLMMAYAINS_MAYA_VERSION" && -f $GLMMAYAINS_tree/maya.sh && -f $GLMMAYAINS_tree/maya.py ]]; then
    info "Project Maya $GLMMAYAINS_MAYA_VERSION is already in $GLMMAYAINS_tree"
    return 0
  fi
  info "Downloading Project Maya $GLMMAYAINS_MAYA_VERSION ($GLMMAYAINS_MAYA_URL)"
  GLMMAYAINS_TMP=$(mktemp -d /tmp/glm-maya-install.XXXXXX)
  chmod 0755 "$GLMMAYAINS_TMP"
  GLMMAYAINS_tar="$GLMMAYAINS_TMP/project-maya.tar.gz"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --output "$GLMMAYAINS_tar" "$GLMMAYAINS_MAYA_URL" \
    || die "download failed: $GLMMAYAINS_MAYA_URL"
  chmod 0644 "$GLMMAYAINS_tar"
  # Extracted beside the final place and moved, so that an interrupted extraction is never
  # taken for an installed tree.
  GLMMAYAINS_new="$GLMMAYAINS_tree.new"; GLMMAYAINS_old="$GLMMAYAINS_tree.old"
  rm -rf --one-file-system "${GLMMAYAINS_new:?}" "${GLMMAYAINS_old:?}"
  run_as "$GLMMAYAINS_u" "$GLMMAYAINS_d" mkdir "$GLMMAYAINS_new" || die "cannot create $GLMMAYAINS_new"
  run_as "$GLMMAYAINS_u" "$GLMMAYAINS_d" tar -xzf "$GLMMAYAINS_tar" -C "$GLMMAYAINS_new" --strip-components=1 --no-same-owner </dev/null \
    || die "cannot extract Maya's archive into $GLMMAYAINS_new"
  cleanup_tmp; GLMMAYAINS_TMP=""
  [[ -f $GLMMAYAINS_new/VERSION && $(tr -d '[:space:]' < "$GLMMAYAINS_new/VERSION") == "$GLMMAYAINS_MAYA_VERSION" && -f $GLMMAYAINS_new/maya.sh && -f $GLMMAYAINS_new/maya.py ]] \
    || die "the downloaded archive is not Project Maya $GLMMAYAINS_MAYA_VERSION (see $GLMMAYAINS_new)"
  [[ -x $GLMMAYAINS_new/maya.sh ]] || run_as "$GLMMAYAINS_u" "$GLMMAYAINS_d" chmod 0755 "$GLMMAYAINS_new/maya.sh"
  if [[ -e $GLMMAYAINS_tree ]]; then
    # Another version, or an incomplete tree: replaced.  The configuration of the selected
    # quantization is carried over so that Maya's setup keeps what it keeps from "the config
    # before", and with it the settings saved through the web page.
    warn "replacing $GLMMAYAINS_tree (version ${GLMMAYAINS_have:-unknown}) with Project Maya $GLMMAYAINS_MAYA_VERSION; the engine is compiled again"
    mv "$GLMMAYAINS_tree" "$GLMMAYAINS_old"
    for GLMMAYAINS_f in "$(maya_name).json" "$(maya_name).shared-settings.json"; do
      [[ ! -f $GLMMAYAINS_old/$GLMMAYAINS_f || -L $GLMMAYAINS_old/$GLMMAYAINS_f ]] \
        || run_as "$GLMMAYAINS_u" "$GLMMAYAINS_d" cp -p "$GLMMAYAINS_old/$GLMMAYAINS_f" "$GLMMAYAINS_new/$GLMMAYAINS_f"
    done
  fi
  mv "$GLMMAYAINS_new" "$GLMMAYAINS_tree"
  rm -rf --one-file-system "${GLMMAYAINS_old:?}"
}

# Keep the API key across re-runs so that clients keep working.  maya.env is read by
# systemd (EnvironmentFile) and may be read by the service user; it also carries Maya's
# switches.  nginx-key.conf is included by the nginx site and defines $glmmaya_bearer.
# shellcheck disable=SC2016
write_key_files() {
  local GLMMAYAINS_key=""
  install -d -m 0755 "$GLMMAYAINS_CONF_DIR"
  [[ ! -f $GLMMAYAINS_ENV_FILE ]] || GLMMAYAINS_key=$(sed -n 's/^MAYA_API_KEY=//p;T;q' "$GLMMAYAINS_ENV_FILE")
  if [[ $GLMMAYAINS_key =~ ^[A-Za-z0-9_-]{24,128}$ ]]; then
    info "Keeping the existing API key"
  else
    info "Generating an API key"
    GLMMAYAINS_key="sk-glmmaya-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  fi
  GLMMAYAINS_API_KEY=$GLMMAYAINS_key
  ( umask 077
    printf '# Generated by install-glm-maya.sh; changes are overwritten on re-run.\nMAYA_API_KEY=%s\nMAYA_UPDATE_CHECK=0\nMAYA_MODEL_MANAGEMENT=0\n' "$GLMMAYAINS_key" > "$GLMMAYAINS_ENV_FILE.tmp"
    printf '# Generated by install-glm-maya.sh; changes are overwritten on re-run.\nset $glmmaya_bearer "Bearer %s";\n' "$GLMMAYAINS_key" > "$GLMMAYAINS_NGINX_KEY_FILE.tmp" )
  chown "root:${GLMMAYAINS_VAL[USER]}" "$GLMMAYAINS_ENV_FILE.tmp"
  chmod 0640 "$GLMMAYAINS_ENV_FILE.tmp"
  chown root:root "$GLMMAYAINS_NGINX_KEY_FILE.tmp"
  chmod 0600 "$GLMMAYAINS_NGINX_KEY_FILE.tmp"
  mv -f "$GLMMAYAINS_ENV_FILE.tmp" "$GLMMAYAINS_ENV_FILE"
  mv -f "$GLMMAYAINS_NGINX_KEY_FILE.tmp" "$GLMMAYAINS_NGINX_KEY_FILE"
}

# Run Maya's setup once as the service user, without questions and without starting the
# model: it creates .venv, fetches the llama.cpp source, compiles the engine, downloads and
# checks the model, builds the pack, compiles the image encoder and writes the configuration
# of the quantization (maya-<name>.json).  Every option below is needed:
#   --setup           without it a re-run with a configuration starts the server instead
#   --port            without it the setup writes port 8080 into the configuration
#   --draft           without it --yes takes the answer of the setup before
#   --drafting        with the drafter: without it the speed calibration runs (--yes measures)
#   --download-model  without it nothing is downloaded and the setup still exits with 0
# Maya checks neither --context (any number is passed on) nor, when --draft is given, the
# GPU for the drafter: validate and preflight are the only checks of both.
# The exit code is not trusted: Maya's setup also ends with 0 when it has done nothing, only
# warns when the image encoder does not build, and skips its speed calibration and its
# tuning when the GPU is in use.  What the service needs is therefore checked afterwards.
# The API key is not passed: the service reads MAYA_API_KEY from maya.env.
# shellcheck disable=SC2016
setup_maya() {
  local GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]} GLMMAYAINS_tree GLMMAYAINS_cfg GLMMAYAINS_log GLMMAYAINS_pack GLMMAYAINS_gpu GLMMAYAINS_args GLMMAYAINS_got GLMMAYAINS_start GLMMAYAINS_rc=0 GLMMAYAINS_exe GLMMAYAINS_kept GLMMAYAINS_failed GLMMAYAINS_cal
  GLMMAYAINS_tree=$(maya_tree)
  GLMMAYAINS_cfg=$(maya_config)
  GLMMAYAINS_log="$GLMMAYAINS_tree/maya-setup.log"
  GLMMAYAINS_cal="$GLMMAYAINS_d/.config/project-maya/calibration.json"
  GLMMAYAINS_gpu=$(gpu_index)
  wait_port_free "${GLMMAYAINS_VAL[MAYA_PORT]}" 60 || die "TCP port ${GLMMAYAINS_VAL[MAYA_PORT]} is still in use: $(ss -Hltnp "sport = :${GLMMAYAINS_VAL[MAYA_PORT]}" | head -n1)"
  GLMMAYAINS_args=(--setup --yes --plain --no-start --download-model
    --model "$(quant_field 1)"
    --gpu "$GLMMAYAINS_gpu" --context "${GLMMAYAINS_VAL[CTX_SIZE]}" --port "${GLMMAYAINS_VAL[MAYA_PORT]}"
    --models-dir "$GLMMAYAINS_d/models" --parallel "${GLMMAYAINS_VAL[PARALLEL]}")
  # skip: the model's own MTP block, which does not draft on one GPU.
  case ${GLMMAYAINS_VAL[DRAFTING]} in
    measure) GLMMAYAINS_args+=(--draft dflash2 --drafting measure) ;;
    on) GLMMAYAINS_args+=(--draft dflash2 --drafting on) ;;
    *) GLMMAYAINS_args+=(--draft mtp) ;;
  esac
  [[ ${GLMMAYAINS_VAL[VISION]} == yes ]] || GLMMAYAINS_args+=(--no-vision)
  [[ $GLMMAYAINS_CALIBRATE != yes ]] || GLMMAYAINS_args+=(--calibrate)
  GLMMAYAINS_args+=(--env MAYA_GLM_SLOT_KEEP=1)
  GLMMAYAINS_start=$(date +%s)
  info "Running maya.sh ${GLMMAYAINS_args[*]}"
  info "This compiles the engine (10 to 30 minutes at the first installation) and downloads the model ($(quant_download) GB for ${GLMMAYAINS_VAL[QUANT]}); it can take hours. Log: $GLMMAYAINS_log"
  # The log is written by the service user (tee), never by root inside a folder of that user.
  # ulimit: --drafting measure and --calibrate start the engine here, outside the unit and
  # its LimitMEMLOCK=infinity, and the engine pins its memory.
  ( ulimit -l unlimited 2>/dev/null || true
    run_as "$GLMMAYAINS_u" "$GLMMAYAINS_d" bash -o pipefail -c '"$@" 2>&1 | tee "$0"' "$GLMMAYAINS_log" "$GLMMAYAINS_tree/maya.sh" "${GLMMAYAINS_args[@]}" </dev/null ) || GLMMAYAINS_rc=$?
  ((GLMMAYAINS_rc == 0)) || die "Maya's setup failed (exit code $GLMMAYAINS_rc; see $GLMMAYAINS_log); fix the problem reported above and re-run the installer (downloads are resumed)"
  # Written in this run: a configuration left by an earlier run proves nothing.
  [[ -f $GLMMAYAINS_cfg && $(stat -c %Y "$GLMMAYAINS_cfg") -ge $GLMMAYAINS_start ]] \
    || die "Maya's setup did not write $GLMMAYAINS_cfg (see $GLMMAYAINS_log); it stops like this when it has not downloaded the model"
  GLMMAYAINS_got=$(json_get "$GLMMAYAINS_cfg" installer quant)
  [[ $GLMMAYAINS_got == "$(quant_field 2)" ]] \
    || die "$GLMMAYAINS_cfg is for the quantization '${GLMMAYAINS_got:-unknown}', not '$(quant_field 2)': Maya's setup did not finish (see $GLMMAYAINS_log)"
  [[ -x $GLMMAYAINS_tree/build/maya ]] || die "Maya's setup did not build $GLMMAYAINS_tree/build/maya (see $GLMMAYAINS_log)"
  # The pack is where the configuration says: Maya names it pack/, or pack-<name>/ when
  # pack/ belongs to other files of the same folder.
  GLMMAYAINS_pack=$(config_arg "$GLMMAYAINS_cfg" --glm-pack)
  [[ -n $GLMMAYAINS_pack && -f $GLMMAYAINS_pack/index.txt ]] \
    || die "Maya's setup did not build the pack ${GLMMAYAINS_pack:-of ${GLMMAYAINS_VAL[QUANT]}} (see $GLMMAYAINS_log)"
  if [[ ${GLMMAYAINS_VAL[VISION]} == yes ]]; then
    # Maya's setup only warns when the image encoder does not build, and leaves "vision" out.
    GLMMAYAINS_exe=$(json_get "$GLMMAYAINS_cfg" vision exe)
    [[ -n $GLMMAYAINS_exe && -x $GLMMAYAINS_exe ]] \
      || die "Maya's setup did not set up the image encoder (${GLMMAYAINS_exe:-no \"vision\" entry in $GLMMAYAINS_cfg}; see $GLMMAYAINS_log); fix the problem reported there and re-run, or re-run with --no-vision"
  fi
  if [[ ${GLMMAYAINS_VAL[DRAFTING]} == measure ]]; then
    # Maya writes the result only when it has measured ("kept": dflash2 or mtp); nothing
    # when the GPU was in use, "failed" when the measurement broke off.  In both cases the
    # configuration still drafts with DFlash2, and a start under systemd never measures.
    GLMMAYAINS_kept=$(json_get "$GLMMAYAINS_cfg" installer speed_calibration kept)
    GLMMAYAINS_failed=$(json_get "$GLMMAYAINS_cfg" installer speed_calibration failed)
    [[ -n $GLMMAYAINS_kept && -z $GLMMAYAINS_failed ]] \
      || die "Maya did not measure the DFlash2 drafter (${GLMMAYAINS_failed:-its speed calibration did not run; see the warning in $GLMMAYAINS_log}): the configuration uses the drafter unmeasured. Re-run with --drafting measure when the GPU is free, with --drafting on to use the drafter as it is, or with --drafting skip to leave it out"
    if [[ $GLMMAYAINS_kept == dflash2 ]]; then
      info "Speed calibration: the DFlash2 drafter is faster on this machine and is used"
    else
      info "Speed calibration: the DFlash2 drafter is not faster on this machine and is not used"
    fi
  fi
  if [[ $GLMMAYAINS_CALIBRATE == yes ]]; then
    # Maya's tuning never fails its setup; its result is kept in this file.
    [[ -f $GLMMAYAINS_cal && $(stat -c %Y "$GLMMAYAINS_cal") -ge $GLMMAYAINS_start ]] \
      || warn "Maya's tuning (--calibrate) did not finish (see $GLMMAYAINS_log): the engine keeps its own settings. Re-run with --calibrate when the GPU is free."
  fi
}

# Maya's setup has no option for the thinking level and writes "reasoning_effort": "max" on
# every run, so it is set here after each setup run.  A key left in the configuration
# ("api_key") would take the place of the one in maya.env when maya.py starts the server, so
# it is removed.  Maya's refusal ablation ("ablate", --ablate in "args") is left as Maya's
# setup wrote it.  Done as the service user, with the service stopped, through a temporary
# file.
set_thinking() {
  local GLMMAYAINS_cfg GLMMAYAINS_out
  GLMMAYAINS_cfg=$(maya_config)
  GLMMAYAINS_out=$(run_as "${GLMMAYAINS_VAL[USER]}" "${GLMMAYAINS_VAL[DESTDIR]}" python3 -I -c '
import json, os, sys
path, effort = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    sys.exit("not a JSON object: " + path)
cfg["reasoning_effort"] = effort
had_key = cfg.pop("api_key", None) is not None
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=1)
os.replace(tmp, path)
print("key-removed" if had_key else "ok")
' "$GLMMAYAINS_cfg" "${GLMMAYAINS_VAL[THINKING]}" </dev/null) || die "cannot set the thinking level in $GLMMAYAINS_cfg"
  [[ $GLMMAYAINS_out != key-removed ]] || warn "an API key in $GLMMAYAINS_cfg was removed; the key in $GLMMAYAINS_ENV_FILE is the one in use"
  info "Thinking level: $(thinking_label) (reasoning_effort in $GLMMAYAINS_cfg)"
}

# Each quantization has a configuration of its own, so a change of quantization leaves the
# old one beside the new one.  The configurations of the other quantizations are removed
# with what belongs to them (the settings before a change made in the web page, the settings
# saved there, the start script), each by its name; their logs stay.
remove_other_configs() {
  local GLMMAYAINS_tree GLMMAYAINS_q GLMMAYAINS_n GLMMAYAINS_f GLMMAYAINS_found=()
  GLMMAYAINS_tree=$(maya_tree)
  for GLMMAYAINS_q in $GLMMAYAINS_QUANTS; do
    [[ $GLMMAYAINS_q != "${GLMMAYAINS_VAL[QUANT]}" ]] || continue
    GLMMAYAINS_n=$(maya_name "$GLMMAYAINS_q")
    for GLMMAYAINS_f in "$GLMMAYAINS_n.json" "$GLMMAYAINS_n.json.prev" "$GLMMAYAINS_n.shared-settings.json" "run-$GLMMAYAINS_n.sh"; do
      [[ ! -e $GLMMAYAINS_tree/$GLMMAYAINS_f && ! -L $GLMMAYAINS_tree/$GLMMAYAINS_f ]] || GLMMAYAINS_found+=("$GLMMAYAINS_tree/$GLMMAYAINS_f")
    done
  done
  ((${#GLMMAYAINS_found[@]} > 0)) || return 0
  info "Removing the configurations of other quantizations: ${GLMMAYAINS_found[*]##*/}"
  run_as "${GLMMAYAINS_VAL[USER]}" "${GLMMAYAINS_VAL[DESTDIR]}" rm -f -- "${GLMMAYAINS_found[@]}" </dev/null \
    || die "cannot remove the configurations of other quantizations in $GLMMAYAINS_tree"
}

write_unit() {
  local GLMMAYAINS_u=${GLMMAYAINS_VAL[USER]} GLMMAYAINS_d=${GLMMAYAINS_VAL[DESTDIR]} GLMMAYAINS_tree GLMMAYAINS_groups="" GLMMAYAINS_g
  GLMMAYAINS_tree=$(maya_tree)
  for GLMMAYAINS_g in video render; do
    if getent group "$GLMMAYAINS_g" >/dev/null; then GLMMAYAINS_groups+=" $GLMMAYAINS_g"; fi
  done
  info "Writing the systemd unit"
  # KillMode=mixed: only maya.py gets SIGTERM; it stops its server and its engine in turn
  # (up to about 150 s; the engine saves its conversations and frees the GPU).
  # After= the plamo-3-translate services: Maya pins nearly all RAM that is free at its
  # start, so they come first.  The llama unit of plamo-3-translate stays "activating" until
  # its model is loaded, and a start of this unit waits for that.  Conflicts= deepseek-maya
  # and qwen-strata: starting one stops the other.  Both are ignored when those units are
  # not installed.
  # Sandboxing is light on purpose until tested on real hardware.
  cat > "$GLMMAYAINS_UNIT_DIR/$GLMMAYAINS_UNIT" <<EOF
# Generated by install-glm-maya.sh; changes are overwritten on re-run.
[Unit]
Description=$GLMMAYAINS_MODEL on Project Maya (maya.sh)
After=network-online.target $GLMMAYAINS_PLAMO_UNITS
Wants=network-online.target
Conflicts=$GLMMAYAINS_EXCLUSIVE_UNITS

[Service]
Type=simple
User=$GLMMAYAINS_u
Group=$GLMMAYAINS_u
${GLMMAYAINS_groups:+SupplementaryGroups=${GLMMAYAINS_groups# }
}WorkingDirectory=$GLMMAYAINS_tree
Environment=HOME=$GLMMAYAINS_d
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
EnvironmentFile=$GLMMAYAINS_ENV_FILE
ExecStart=$GLMMAYAINS_tree/maya.sh --config $(maya_config) --port ${GLMMAYAINS_VAL[MAYA_PORT]} --plain
Restart=on-failure
RestartSec=30
TimeoutStartSec=infinity
TimeoutStopSec=600
KillMode=mixed
LimitMEMLOCK=infinity
NoNewPrivileges=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$GLMMAYAINS_UNIT_DIR/$GLMMAYAINS_UNIT"
}

# Maya appends to the engine log for ever; rotate it in place.  Only the log of the selected
# quantization, by its name: maya-*.log would also match maya-setup.log.
write_logrotate() {
  cat > "$GLMMAYAINS_LOGROTATE_FILE" <<EOF
# Generated by install-glm-maya.sh; changes are overwritten on re-run.
$(maya_log) {
    su ${GLMMAYAINS_VAL[USER]} ${GLMMAYAINS_VAL[USER]}
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  chmod 0644 "$GLMMAYAINS_LOGROTATE_FILE"
}

# nginx_location PATH MODE [prefix]: print a location for an exact path, or with "prefix"
# for everything below PATH (which then ends with a slash).  MODE: add (nginx adds the API
# key), get (nginx adds it to GET requests only), chat (per request, see nginx_site) or
# pass (the client's own headers).  The URI in proxy_pass makes Maya see exactly the
# (normalized) path nginx matched.
# shellcheck disable=SC2016
nginx_location() {
  local GLMMAYAINS_auth="" GLMMAYAINS_up="http://127.0.0.1:${GLMMAYAINS_VAL[MAYA_PORT]}" GLMMAYAINS_match="= "
  [[ ${3:-} != prefix ]] || GLMMAYAINS_match=""
  case $2 in
    add) GLMMAYAINS_auth='        proxy_set_header Authorization $glmmaya_bearer;
        proxy_set_header X-Api-Key "";' ;;
    get) GLMMAYAINS_auth='        proxy_set_header Authorization $glmmaya_get_auth;
        proxy_set_header X-Api-Key $glmmaya_get_xkey;' ;;
    chat) GLMMAYAINS_auth='        proxy_set_header Authorization $glmmaya_chat_auth;
        proxy_set_header X-Api-Key $glmmaya_chat_xkey;' ;;
  esac
  if [[ -z $GLMMAYAINS_auth ]]; then
    printf '    location %s%s {\n        proxy_pass %s%s;\n    }\n' "$GLMMAYAINS_match" "$1" "$GLMMAYAINS_up" "$1"
  else
    # proxy_set_header is inherited only as a whole, so the server-level ones are repeated.
    printf '    location %s%s {\n        proxy_pass %s%s;\n        proxy_set_header Host $http_host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n%s\n    }\n' \
      "$GLMMAYAINS_match" "$1" "$GLMMAYAINS_up" "$1" "$GLMMAYAINS_auth"
  fi
}

# Print the nginx site.  Maya always has an API key; nginx adds it to the requests that
# may be made without one:
#   web page (/metrics, /attach, ...; GET of /settings, /mcp, ...)   unless --web-api-key
#   agents (/v1/messages, /v1/responses, /v1/models, ...)            unless --agent-api-key
#   /v1/chat/completions (used by both)      by both settings; when they differ, a request
#       counts as the web page's if the browser says so: Sec-Fetch-Site: same-origin, or
#       (browsers send Sec-Fetch-* only to HTTPS and localhost) an Origin equal to the Host.
#       Other clients can forge these headers.
# Everything else, including all management requests (POST of /settings, /api/context,
# ...), is passed on with the client's own headers, so Maya demands the key there.  Unknown
# paths therefore fail safe.
nginx_site() {
  local GLMMAYAINS_port=${GLMMAYAINS_VAL[WEB_PORT]} GLMMAYAINS_web=${GLMMAYAINS_VAL[WEB_API_KEY]} GLMMAYAINS_agent=${GLMMAYAINS_VAL[AGENT_API_KEY]}
  local GLMMAYAINS_listen GLMMAYAINS_a GLMMAYAINS_web_mode=add GLMMAYAINS_get_mode=get GLMMAYAINS_agent_mode=add GLMMAYAINS_chat_mode GLMMAYAINS_page GLMMAYAINS_p
  if [[ ${GLMMAYAINS_VAL[INTERFACES]} == all ]]; then
    GLMMAYAINS_listen="    listen $GLMMAYAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || GLMMAYAINS_listen+=$'\n'"    listen [::]:$GLMMAYAINS_port;"
  else
    GLMMAYAINS_listen="    listen 127.0.0.1:$GLMMAYAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || GLMMAYAINS_listen+=$'\n'"    listen [::1]:$GLMMAYAINS_port;"
    while read -r GLMMAYAINS_a; do
      [[ -n $GLMMAYAINS_a ]] || continue
      if [[ $GLMMAYAINS_a == *:* ]]; then GLMMAYAINS_listen+=$'\n'"    listen [$GLMMAYAINS_a]:$GLMMAYAINS_port;"
      else GLMMAYAINS_listen+=$'\n'"    listen $GLMMAYAINS_a:$GLMMAYAINS_port;"; fi
    done <<<"$(listen_addresses)"
  fi
  if [[ $GLMMAYAINS_web == yes ]]; then GLMMAYAINS_web_mode=pass; GLMMAYAINS_get_mode=pass; fi
  [[ $GLMMAYAINS_agent != yes ]] || GLMMAYAINS_agent_mode=pass
  if [[ $GLMMAYAINS_web == "$GLMMAYAINS_agent" ]]; then GLMMAYAINS_chat_mode=$GLMMAYAINS_web_mode; else GLMMAYAINS_chat_mode=chat; fi

  echo "# Generated by install-glm-maya.sh; changes are overwritten on re-run."
  echo "# API key: web page $(key_label "$GLMMAYAINS_web"), agents $(key_label "$GLMMAYAINS_agent"), management always required."
  if [[ $GLMMAYAINS_get_mode == get ]]; then
    # The paths the web page only reads: the key is added to GET, any other method keeps
    # the client's own headers (changing a setting is a management request).
    cat <<EOF

map \$request_method \$glmmaya_get_auth {
    default \$http_authorization;
    GET \$glmmaya_bearer;
}
map \$request_method \$glmmaya_get_xkey {
    default \$http_x_api_key;
    GET "";
}
EOF
  fi
  if [[ $GLMMAYAINS_chat_mode == chat ]]; then
    # 1 = the request comes from the web page; the key is added for that side only.
    GLMMAYAINS_page=1
    [[ $GLMMAYAINS_web != yes ]] || GLMMAYAINS_page=0
    cat <<EOF

map "\$http_sec_fetch_site|\$http_origin|\$http_host" \$glmmaya_from_page {
    default 0;
    "~^same-origin\\|" 1;
    "~^\\|https?://([^|]+)\\|\\1\$" 1;
}
map \$glmmaya_from_page \$glmmaya_chat_auth {
    default \$http_authorization;
    $GLMMAYAINS_page \$glmmaya_bearer;
}
map \$glmmaya_from_page \$glmmaya_chat_xkey {
    default \$http_x_api_key;
    $GLMMAYAINS_page "";
}
EOF
  fi
  cat <<EOF

server {
$GLMMAYAINS_listen
    server_name _;

    # Pictures, video and files are sent inline.
    client_max_body_size 256m;
    # Streamed answers; long generations and long waits for a free slot.
    proxy_buffering off;
    proxy_read_timeout 3660s;
    proxy_send_timeout 3660s;
    # Maya refuses a POST whose Origin does not equal the Host header, port included.
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Defines \$glmmaya_bearer ("Bearer <API key>"); readable by root only.
    include $GLMMAYAINS_NGINX_KEY_FILE;

    # The web page (/, /web/, /fonts/), /health and everything not listed below, with the
    # client's own headers: Maya demands the key for all of it but the page and /health.
    location / {
        proxy_pass http://127.0.0.1:${GLMMAYAINS_VAL[MAYA_PORT]};
    }

    # What the web page needs for chatting.
EOF
  for GLMMAYAINS_p in /metrics /attach /pdf /api/tokens /v1/strata/stream /v1/strata/cancel; do
    nginx_location "$GLMMAYAINS_p" "$GLMMAYAINS_web_mode"
  done
  printf '\n    # Read by the web page (GET); changing them (POST) is a management request.\n'
  for GLMMAYAINS_p in /settings /mcp /api/context /api/thinking-budget /api/turbo /api/savings /api/update; do
    nginx_location "$GLMMAYAINS_p" "$GLMMAYAINS_get_mode"
  done
  printf '\n    # Used by the web page and by agents.\n'
  nginx_location /v1/chat/completions "$GLMMAYAINS_chat_mode"
  printf '\n    # Used by agents.\n'
  for GLMMAYAINS_p in /v1/messages /v1/responses /v1/models /models /props /tokenize /detokenize; do
    nginx_location "$GLMMAYAINS_p" "$GLMMAYAINS_agent_mode"
  done
  nginx_location /v1/responses/ "$GLMMAYAINS_agent_mode" prefix
  echo "}"
}

write_nginx() {
  info "Writing nginx site configuration"
  nginx_site > "$GLMMAYAINS_NGINX_SITE"
  chmod 0644 "$GLMMAYAINS_NGINX_SITE"
  ln -sfn "$GLMMAYAINS_NGINX_SITE" "$GLMMAYAINS_NGINX_LINK"
  if ! nginx -t 2>&1; then
    # Do not leave a broken site enabled: it would stop other sites from being reloaded.
    rm -f "$GLMMAYAINS_NGINX_LINK"
    die "nginx configuration test failed; the site $GLMMAYAINS_APP_NAME was disabled again (see $GLMMAYAINS_NGINX_SITE)"
  fi
}

start_services() {
  local GLMMAYAINS_u
  info "Starting services"
  systemctl daemon-reload
  systemctl enable "$GLMMAYAINS_UNIT" nginx.service
  systemctl reset-failed "$GLMMAYAINS_UNIT" 2>/dev/null || true
  # The start waits for units this one is ordered after while they are being started.
  for GLMMAYAINS_u in $GLMMAYAINS_PLAMO_UNITS; do
    [[ $(systemctl show -p ActiveState --value "$GLMMAYAINS_u" 2>/dev/null || true) != activating ]] \
      || info "$GLMMAYAINS_u is still starting (loading its model); $GLMMAYAINS_UNIT is started when it has finished"
  done
  systemctl restart "$GLMMAYAINS_UNIT" || {
    journalctl -u "$GLMMAYAINS_UNIT" -n 30 --no-pager >&2 || true
    die "failed to start $GLMMAYAINS_UNIT"
  }
  if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
  else
    systemctl start nginx.service
  fi
}

# --------------------------------------------------------------------- ufw

ufw_active() {
  local GLMMAYAINS_status
  command -v ufw >/dev/null 2>&1 || return 1
  GLMMAYAINS_status=$(ufw status 2>/dev/null) || return 1
  grep -q '^Status: active$' <<<"$GLMMAYAINS_status"
}

# Print the ufw rules needed for the web server: PORT, or PORT@INTERFACE when the
# interfaces are restricted.  Maya itself listens on 127.0.0.1 only.
ufw_wanted_rules() {
  local GLMMAYAINS_ifc GLMMAYAINS_p=${GLMMAYAINS_VAL[WEB_PORT]}
  if [[ ${GLMMAYAINS_VAL[INTERFACES]} == all ]]; then
    echo "$GLMMAYAINS_p"
  else
    for GLMMAYAINS_ifc in ${GLMMAYAINS_VAL[INTERFACES]//,/ }; do echo "$GLMMAYAINS_p@$GLMMAYAINS_ifc"; done
  fi
}

# Print the wanted rules that ufw does not allow yet (a rule for all interfaces covers
# every interface).
ufw_closed_ports() {
  local GLMMAYAINS_status GLMMAYAINS_r GLMMAYAINS_p GLMMAYAINS_ifc
  GLMMAYAINS_status=$(ufw status 2>/dev/null || true)
  while read -r GLMMAYAINS_r; do
    [[ -n $GLMMAYAINS_r ]] || continue
    GLMMAYAINS_p=${GLMMAYAINS_r%%@*}
    grep -Eq "^$GLMMAYAINS_p(/tcp)?[[:space:]]+ALLOW" <<<"$GLMMAYAINS_status" && continue
    if [[ $GLMMAYAINS_r == *@* ]]; then
      GLMMAYAINS_ifc=${GLMMAYAINS_r#*@}
      grep -Eq "^$GLMMAYAINS_p(/tcp)? on ${GLMMAYAINS_ifc//./\\.}[[:space:]]+ALLOW" <<<"$GLMMAYAINS_status" && continue
    fi
    echo "$GLMMAYAINS_r"
  done <<<"$(ufw_wanted_rules)"
}

# Human-readable form of rules: "48080/tcp, 48080/tcp on bond0".
ufw_rules_text() {
  local GLMMAYAINS_r GLMMAYAINS_text=""
  for GLMMAYAINS_r in "$@"; do
    if [[ $GLMMAYAINS_r == *@* ]]; then GLMMAYAINS_text+="${GLMMAYAINS_text:+, }${GLMMAYAINS_r%%@*}/tcp on ${GLMMAYAINS_r#*@}"
    else GLMMAYAINS_text+="${GLMMAYAINS_text:+, }$GLMMAYAINS_r/tcp"; fi
  done
  echo "$GLMMAYAINS_text"
}

# ufw arguments for a rule (used with "ufw" and "ufw delete").
ufw_rule_args() {
  if [[ $1 == *@* ]]; then
    echo "allow in on ${1#*@} to any port ${1%%@*} proto tcp"
  else
    echo "allow ${1}/tcp"
  fi
}

# Ask about ufw together with the other questions.  configure_ufw asks again only if
# this was not answered (e.g. ufw was enabled after the questions).
prompt_ufw() {
  local GLMMAYAINS_ports
  [[ -z $GLMMAYAINS_OPEN_PORTS && $GLMMAYAINS_INTERACTIVE == yes && $GLMMAYAINS_ASSUME_YES != yes ]] || return 0
  ufw_active || return 0
  GLMMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  [[ -n $GLMMAYAINS_ports ]] || return 0
  # shellcheck disable=SC2086
  if confirm "ufw is active. Allow incoming $(ufw_rules_text $GLMMAYAINS_ports)?"; then
    GLMMAYAINS_OPEN_PORTS=yes
  else
    GLMMAYAINS_OPEN_PORTS=no
  fi
}

ufw_label() {
  local GLMMAYAINS_ports
  if ! ufw_active; then echo "no (ufw is not active)"; return 0; fi
  GLMMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  # shellcheck disable=SC2086
  GLMMAYAINS_ports=$(ufw_rules_text $GLMMAYAINS_ports)
  if [[ -z $GLMMAYAINS_ports ]]; then echo "no (already allowed)"
  elif [[ $GLMMAYAINS_OPEN_PORTS == yes || ( -z $GLMMAYAINS_OPEN_PORTS && $GLMMAYAINS_ASSUME_YES == yes ) ]]; then echo "yes ($GLMMAYAINS_ports)"
  elif [[ $GLMMAYAINS_OPEN_PORTS == no ]]; then echo "no ($GLMMAYAINS_ports stay closed)"
  else echo "ask later ($GLMMAYAINS_ports)"
  fi
}

configure_ufw() {
  local GLMMAYAINS_ports GLMMAYAINS_p GLMMAYAINS_wanted GLMMAYAINS_kept=""
  GLMMAYAINS_UFW_RULES=${GLMMAYAINS_SAVED[UFW_RULES]:-}
  ufw_active || return 0
  # Remove rules this installer added earlier that are no longer wanted (another port,
  # or a rule for all interfaces after restricting the interfaces).
  GLMMAYAINS_wanted=" $(ufw_wanted_rules | paste -sd' ' -) "
  for GLMMAYAINS_p in $GLMMAYAINS_UFW_RULES; do
    if [[ $GLMMAYAINS_wanted == *" $GLMMAYAINS_p "* ]]; then
      GLMMAYAINS_kept+="${GLMMAYAINS_kept:+ }$GLMMAYAINS_p"
    else
      # shellcheck disable=SC2046
      ufw delete $(ufw_rule_args "$GLMMAYAINS_p") >/dev/null 2>&1 || true
      info "Removed the ufw rule for $(ufw_rules_text "$GLMMAYAINS_p") added by a previous installation"
    fi
  done
  GLMMAYAINS_UFW_RULES=$GLMMAYAINS_kept
  GLMMAYAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  if [[ -z $GLMMAYAINS_ports ]]; then
    info "ufw already allows the required port(s)"
    return 0
  fi
  # shellcheck disable=SC2086
  if [[ $GLMMAYAINS_OPEN_PORTS == yes ]] ||
     { [[ -z $GLMMAYAINS_OPEN_PORTS ]] && confirm "ufw is active. Allow incoming $(ufw_rules_text $GLMMAYAINS_ports)?"; }; then
    for GLMMAYAINS_p in $GLMMAYAINS_ports; do
      # shellcheck disable=SC2046
      ufw $(ufw_rule_args "$GLMMAYAINS_p") comment "$GLMMAYAINS_APP_NAME" >/dev/null
      [[ " $GLMMAYAINS_UFW_RULES " == *" $GLMMAYAINS_p "* ]] || GLMMAYAINS_UFW_RULES=${GLMMAYAINS_UFW_RULES:+$GLMMAYAINS_UFW_RULES }$GLMMAYAINS_p
    done
    # shellcheck disable=SC2086
    info "Allowed $(ufw_rules_text $GLMMAYAINS_ports) in ufw"
  else
    # shellcheck disable=SC2086
    warn "ufw is active and $(ufw_rules_text $GLMMAYAINS_ports) were not allowed; other hosts cannot connect"
  fi
}

save_config() {
  local GLMMAYAINS_key
  install -d -m 0755 "$GLMMAYAINS_CONF_DIR"
  {
    echo "# Written by install-glm-maya.sh; used as defaults on re-run and by --uninstall."
    for GLMMAYAINS_key in $GLMMAYAINS_KEYS; do printf "%s='%s'\n" "$GLMMAYAINS_key" "${GLMMAYAINS_VAL[$GLMMAYAINS_key]}"; done
    printf "UFW_RULES='%s'\n" "$GLMMAYAINS_UFW_RULES"
  } > "$GLMMAYAINS_CONF_FILE.tmp"
  chmod 0644 "$GLMMAYAINS_CONF_FILE.tmp"
  mv -f "$GLMMAYAINS_CONF_FILE.tmp" "$GLMMAYAINS_CONF_FILE"
}

# -------------------------------------------------------------------- tests

# http_code URL [curl options...]: print the HTTP status of a GET.
http_code() {
  local GLMMAYAINS_url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$GLMMAYAINS_url" || true
}

# Maya's server opens its port only after the engine is ready; /health then says
# "status": "ok" and "unloaded": false.
wait_health() {
  local GLMMAYAINS_url="http://127.0.0.1:${GLMMAYAINS_VAL[MAYA_PORT]}/health" GLMMAYAINS_start GLMMAYAINS_body=""
  info "Waiting for Maya to load the model (up to ${GLMMAYAINS_HEALTH_TIMEOUT}s; a start takes minutes)"
  GLMMAYAINS_start=$SECONDS
  while :; do
    GLMMAYAINS_body=$(curl -s --fail --max-time 5 "$GLMMAYAINS_url" 2>/dev/null || true)
    if [[ -n $GLMMAYAINS_body && $(json_get - status <<<"$GLMMAYAINS_body") == ok && $(json_get - unloaded <<<"$GLMMAYAINS_body") == false ]]; then
      break
    fi
    # Restart=on-failure would hide a crash; any restart or inactive state is a failure.
    if [[ $(systemctl show -p ActiveState --value "$GLMMAYAINS_UNIT") != active ||
          $(systemctl show -p NRestarts --value "$GLMMAYAINS_UNIT") != 0 ]]; then
      journalctl -u "$GLMMAYAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Maya is not running (see journalctl -u $GLMMAYAINS_UNIT and $(maya_log))"
    fi
    if ((SECONDS - GLMMAYAINS_start > GLMMAYAINS_HEALTH_TIMEOUT)); then
      journalctl -u "$GLMMAYAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Maya did not become ready within ${GLMMAYAINS_HEALTH_TIMEOUT}s"
    fi
    sleep 5
  done
  GLMMAYAINS_MODEL_ID=$(json_get - model <<<"$GLMMAYAINS_body")
  GLMMAYAINS_N_CTX=$(json_get - max_context <<<"$GLMMAYAINS_body")
  GLMMAYAINS_EFFORT=$(json_get - defaults reasoning_effort <<<"$GLMMAYAINS_body")
  info "Maya is ready ($((SECONDS - GLMMAYAINS_start))s): model ${GLMMAYAINS_MODEL_ID:-unknown}, context ${GLMMAYAINS_N_CTX:-unknown}, thinking ${GLMMAYAINS_EFFORT:-unknown} (set: $(thinking_label))"
}

# effort_level WORD: a thinking level in the four words of --thinking, as Maya's server
# maps the other spellings it accepts (serve/frontend.py, EFFORT).
effort_level() {
  case ${1,,} in
    medium) echo high ;;
    xhigh|maximum|auto|default) echo max ;;
    off|minimal|disabled|false) echo none ;;
    *) echo "${1,,}" ;;
  esac
}

# The thinking level a request gets when it names none: the configuration's (shown by
# /health), unless a holder of the API key saved one in the settings of the web page.  Maya
# keeps that beside the configuration (maya-<name>.shared-settings.json) and reports it in
# GET /settings; it takes the place of the configuration's until it is cleared there.  Only
# warnings, also when /settings cannot be read: what the server reports here has not been
# seen on real hardware.
check_thinking() {
  local GLMMAYAINS_base=$1 GLMMAYAINS_auth=$2 GLMMAYAINS_out GLMMAYAINS_shared
  if [[ -n $GLMMAYAINS_EFFORT && $(effort_level "$GLMMAYAINS_EFFORT") != "${GLMMAYAINS_VAL[THINKING]}" ]]; then
    warn "Maya reports the thinking level '$GLMMAYAINS_EFFORT', not '${GLMMAYAINS_VAL[THINKING]}' as set with --thinking (see reasoning_effort in $(maya_config))"
  fi
  GLMMAYAINS_out=$(curl -s --fail --max-time 20 -H "$GLMMAYAINS_auth" "$GLMMAYAINS_base/settings" 2>/dev/null || true)
  if [[ -z $GLMMAYAINS_out ]]; then
    warn "cannot read $GLMMAYAINS_base/settings: not checked whether a thinking level saved in the settings of the web page takes the place of --thinking ${GLMMAYAINS_VAL[THINKING]}"
    return 0
  fi
  GLMMAYAINS_shared=$(json_get - defaults reasoning_effort <<<"$GLMMAYAINS_out")
  if [[ -n $GLMMAYAINS_shared && $(effort_level "$GLMMAYAINS_shared") != "${GLMMAYAINS_VAL[THINKING]}" ]]; then
    warn "the thinking level '$GLMMAYAINS_shared' was saved in the settings of the web page and takes the place of --thinking ${GLMMAYAINS_VAL[THINKING]} for requests that name none; clear it in the page's settings (with the API key), or delete $(maya_tree)/$(maya_name).shared-settings.json and restart $GLMMAYAINS_UNIT"
  fi
}

# expect_code DESCRIPTION EXPECTED URL [curl options...]
expect_code() {
  local GLMMAYAINS_what=$1 GLMMAYAINS_want=$2 GLMMAYAINS_got
  shift 2
  GLMMAYAINS_got=$(http_code "$@")
  [[ $GLMMAYAINS_got == "$GLMMAYAINS_want" ]] || die "test failed: $GLMMAYAINS_what: HTTP ${GLMMAYAINS_got:-none}, expected $GLMMAYAINS_want"
  info "Test passed: $GLMMAYAINS_what (HTTP $GLMMAYAINS_got)"
}

smoke_test() {
  local GLMMAYAINS_base="http://127.0.0.1:${GLMMAYAINS_VAL[WEB_PORT]}" GLMMAYAINS_auth GLMMAYAINS_want GLMMAYAINS_out GLMMAYAINS_code GLMMAYAINS_ctx
  wait_health
  GLMMAYAINS_auth="Authorization: Bearer $GLMMAYAINS_API_KEY"
  info "Testing through the web server (port ${GLMMAYAINS_VAL[WEB_PORT]})"
  expect_code "/health" 200 "$GLMMAYAINS_base/health"
  expect_code "web page" 200 "$GLMMAYAINS_base/"
  expect_code "management path /status without the API key is refused" 401 "$GLMMAYAINS_base/status"
  expect_code "management path /status with the API key" 200 "$GLMMAYAINS_base/status" -H "$GLMMAYAINS_auth"
  GLMMAYAINS_want=200; [[ ${GLMMAYAINS_VAL[WEB_API_KEY]} != yes ]] || GLMMAYAINS_want=401
  expect_code "/metrics without the API key (web page: $(key_label "${GLMMAYAINS_VAL[WEB_API_KEY]}"))" "$GLMMAYAINS_want" "$GLMMAYAINS_base/metrics"
  GLMMAYAINS_want=200; [[ ${GLMMAYAINS_VAL[AGENT_API_KEY]} != yes ]] || GLMMAYAINS_want=401
  expect_code "/v1/models without the API key (agents: $(key_label "${GLMMAYAINS_VAL[AGENT_API_KEY]}"))" "$GLMMAYAINS_want" "$GLMMAYAINS_base/v1/models"
  GLMMAYAINS_out=$(curl -s --fail --max-time 20 -H "$GLMMAYAINS_auth" "$GLMMAYAINS_base/v1/models") || die "test failed: /v1/models with the API key"
  GLMMAYAINS_ctx=$(json_get - data 0 context_length <<<"$GLMMAYAINS_out")
  [[ $GLMMAYAINS_ctx == "${GLMMAYAINS_VAL[CTX_SIZE]}" ]] \
    || die "test failed: /v1/models reports the context size ${GLMMAYAINS_ctx:-none}, expected ${GLMMAYAINS_VAL[CTX_SIZE]}"
  info "Test passed: /v1/models reports the context size $GLMMAYAINS_ctx"
  check_thinking "$GLMMAYAINS_base" "$GLMMAYAINS_auth"
  info "Requesting a short chat completion"
  GLMMAYAINS_out=$(curl -s -w '\n%{http_code}' --max-time 900 -H 'Content-Type: application/json' -H "$GLMMAYAINS_auth" \
    -d "{\"model\": \"${GLMMAYAINS_MODEL_ID:-$GLMMAYAINS_MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello.\"}], \"max_tokens\": 32}" \
    "$GLMMAYAINS_base/v1/chat/completions") || die "cannot connect to the web server on port ${GLMMAYAINS_VAL[WEB_PORT]}"
  GLMMAYAINS_code=${GLMMAYAINS_out##*$'\n'}; GLMMAYAINS_out=${GLMMAYAINS_out%$'\n'*}
  [[ $GLMMAYAINS_code == 200 ]] || die "chat completion test failed (HTTP $GLMMAYAINS_code): ${GLMMAYAINS_out:0:500}"
  info "Test passed: chat completion (HTTP 200)"
}

# Offer to delete the model files of other quantizations: only their own folders,
# models/<Maya's key>/, each with its pack, its kept conversations and its files of the
# image encoder.  What the quantizations share (GLM-5.3-Flash-DFlash2/, refusal-directions/)
# is never offered.  A folder that a symbolic link elsewhere points into is kept.  Asked
# only interactively: --yes does not delete downloads.
cleanup_old_models() {
  local GLMMAYAINS_base="${GLMMAYAINS_VAL[DESTDIR]}/models" GLMMAYAINS_q GLMMAYAINS_dir
  [[ $GLMMAYAINS_INTERACTIVE == yes ]] || return 0
  for GLMMAYAINS_q in $GLMMAYAINS_QUANTS; do
    [[ $GLMMAYAINS_q != "${GLMMAYAINS_VAL[QUANT]}" ]] || continue
    GLMMAYAINS_dir="$GLMMAYAINS_base/$(quant_field 2 "$GLMMAYAINS_q")"
    [[ -d $GLMMAYAINS_dir && ! -L $GLMMAYAINS_dir ]] || continue
    if [[ -n $(find "$GLMMAYAINS_base" -path "$GLMMAYAINS_dir" -prune -o -type l -lname "$GLMMAYAINS_dir/*" -print -quit 2>/dev/null) ]]; then
      warn "the model files of $GLMMAYAINS_q in $GLMMAYAINS_dir are used by another folder through symbolic links; not offered for deletion"
      continue
    fi
    if ask_yn "Delete the unused model files of $GLMMAYAINS_q ($(du -sh "$GLMMAYAINS_dir" 2>/dev/null | cut -f1))?" n; then
      rm -rf --one-file-system "${GLMMAYAINS_dir:?}"
      info "Deleted the model files of $GLMMAYAINS_q"
    fi
  done
}

finish() {
  local GLMMAYAINS_ip GLMMAYAINS_host GLMMAYAINS_drafting="none"
  # What the configuration says now: --drafting measure keeps the drafter only if it is faster.
  [[ -z $(config_arg "$(maya_config)" --dflash) ]] || GLMMAYAINS_drafting="DFlash2 drafter (license: $GLMMAYAINS_DRAFTER_LICENSE)"
  GLMMAYAINS_ip=$(listen_addresses | sed -n '1p')
  [[ -n $GLMMAYAINS_ip ]] || GLMMAYAINS_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ $GLMMAYAINS_ip != *:* ]] || GLMMAYAINS_ip="[$GLMMAYAINS_ip]"
  GLMMAYAINS_host="${GLMMAYAINS_ip:-<this host>}:${GLMMAYAINS_VAL[WEB_PORT]}"
  cat <<EOF

$GLMMAYAINS_MODEL (${GLMMAYAINS_VAL[QUANT]}) with Project Maya $GLMMAYAINS_MAYA_VERSION is installed.
  Web chat        : http://$GLMMAYAINS_host/
  OpenAI API      : http://$GLMMAYAINS_host/v1     (/v1/chat/completions, /v1/responses, /v1/models)
  Anthropic API   : http://$GLMMAYAINS_host        (/v1/messages)
  Model name      : ${GLMMAYAINS_MODEL_ID:-see /v1/models}
  Context         : ${GLMMAYAINS_N_CTX:-${GLMMAYAINS_VAL[CTX_SIZE]}} tokens
  Thinking        : $(thinking_label) (when a request names no level)
  Drafting        : $GLMMAYAINS_drafting
  Services        : $GLMMAYAINS_UNIT, nginx.service
  Logs            : journalctl -u $GLMMAYAINS_UNIT
                    $(maya_log)
  Settings        : $GLMMAYAINS_CONF_FILE
  API key         : web page $(key_label "${GLMMAYAINS_VAL[WEB_API_KEY]}"), agents $(key_label "${GLMMAYAINS_VAL[AGENT_API_KEY]}"), management always required
                    sudo sed -n 's/^MAYA_API_KEY=//p' $GLMMAYAINS_ENV_FILE
EOF
  if [[ ${GLMMAYAINS_VAL[AGENT_API_KEY]} != yes ]]; then
    echo "                    (agents that insist on an API key can be given any non-empty string)"
  fi
  if [[ ${GLMMAYAINS_VAL[WEB_API_KEY]} == yes ]]; then
    echo "                    (enter the key in the settings of the web page)"
  fi
  echo
}

do_install() {
  load_saved_config
  resolve_values
  require_gpu
  prompt_values
  validate
  prompt_gpus
  prompt_interfaces
  prompt_ufw
  show_summary
  preflight
  install_packages
  ensure_user
  prepare_destdir
  stop_service
  disable_exclusive_units
  gpu_busy_check
  install_maya
  write_key_files
  setup_maya
  set_thinking
  remove_other_configs
  write_unit
  write_logrotate
  write_nginx
  [[ -n ${GLMMAYAINS_SAVED[DESTDIR]:-} && ${GLMMAYAINS_SAVED[DESTDIR]} != "${GLMMAYAINS_VAL[DESTDIR]}" ]] \
    && warn "the previous installation directory ${GLMMAYAINS_SAVED[DESTDIR]} is no longer used; remove it manually if not needed"
  start_services
  configure_ufw
  save_config
  smoke_test
  cleanup_old_models
  finish
}

# -------------------------------------------------------------- uninstall

do_uninstall() {
  local GLMMAYAINS_destdir GLMMAYAINS_user GLMMAYAINS_p GLMMAYAINS_rules GLMMAYAINS_x GLMMAYAINS_n=0
  load_saved_config
  GLMMAYAINS_destdir=${GLMMAYAINS_ARG[DESTDIR]:-${GLMMAYA_DESTDIR:-${GLMMAYAINS_SAVED[DESTDIR]:-${GLMMAYAINS_DEFAULT[DESTDIR]}}}}
  GLMMAYAINS_destdir=${GLMMAYAINS_destdir%/}
  GLMMAYAINS_user=${GLMMAYAINS_ARG[USER]:-${GLMMAYA_USER:-${GLMMAYAINS_SAVED[USER]:-${GLMMAYAINS_DEFAULT[USER]}}}}
  cat <<EOF
This will stop and remove the $GLMMAYAINS_MODEL / Project Maya service and delete:
  $GLMMAYAINS_UNIT_DIR/$GLMMAYAINS_UNIT
  $GLMMAYAINS_NGINX_SITE (and the link in sites-enabled)
  $GLMMAYAINS_LOGROTATE_FILE
  $GLMMAYAINS_CONF_DIR (including the API key)
  $GLMMAYAINS_destdir (Maya, its engine and all downloaded model files)
EOF
  confirm "Uninstall $GLMMAYAINS_MODEL / Project Maya?" || die "aborted (use --yes to uninstall non-interactively)"

  info "Stopping the service"
  if service_exists "$GLMMAYAINS_UNIT"; then
    systemctl disable --now "$GLMMAYAINS_UNIT" 2>/dev/null || true
    rm -f "${GLMMAYAINS_UNIT_DIR:?}/$GLMMAYAINS_UNIT"
  fi
  systemctl daemon-reload
  systemctl reset-failed "$GLMMAYAINS_UNIT" 2>/dev/null || true

  info "Removing nginx site"
  rm -f "$GLMMAYAINS_NGINX_LINK" "$GLMMAYAINS_NGINX_SITE"
  if command -v nginx >/dev/null && systemctl is-active --quiet nginx.service; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx.service
    else
      warn "nginx configuration test failed; nginx was not reloaded"
    fi
  fi
  rm -f "$GLMMAYAINS_LOGROTATE_FILE"

  GLMMAYAINS_rules=${GLMMAYAINS_SAVED[UFW_RULES]:-}
  if [[ -n $GLMMAYAINS_rules ]] && command -v ufw >/dev/null; then
    for GLMMAYAINS_p in $GLMMAYAINS_rules; do
      # shellcheck disable=SC2046
      if ufw delete $(ufw_rule_args "$GLMMAYAINS_p") >/dev/null 2>&1; then
        info "Removed the ufw rule for $(ufw_rules_text "$GLMMAYAINS_p")"
      fi
    done
  fi

  if [[ -d $GLMMAYAINS_destdir ]]; then
    if [[ -e $GLMMAYAINS_destdir/$GLMMAYAINS_MARKER ]]; then
      info "Removing $GLMMAYAINS_destdir"
      rm -rf --one-file-system "${GLMMAYAINS_destdir:?}"
    else
      warn "$GLMMAYAINS_destdir does not look like a $GLMMAYAINS_APP_NAME installation; not removed"
    fi
  fi
  rm -rf "${GLMMAYAINS_CONF_DIR:?}"

  cat <<EOF

$GLMMAYAINS_MODEL / Project Maya was uninstalled.
The apt packages (cuda-toolkit-13, nginx-full, ...) and the service user $GLMMAYAINS_user were kept.
Remove them manually if they are no longer needed, e.g.:
  sudo userdel $GLMMAYAINS_user
EOF
  for GLMMAYAINS_x in $GLMMAYAINS_EXCLUSIVE_UNITS; do
    service_exists "$GLMMAYAINS_x" || continue
    if systemctl is-enabled --quiet "$GLMMAYAINS_x" 2>/dev/null; then continue; fi
    GLMMAYAINS_n=$((GLMMAYAINS_n + 1))
    cat <<EOF
$GLMMAYAINS_x is installed but not enabled (installing $GLMMAYAINS_APP_NAME stops and disables it).  To use it again:
  sudo systemctl enable --now ${GLMMAYAINS_x%.service}
EOF
  done
  ((GLMMAYAINS_n < 2)) || echo "Enable only one of them: they do not run at the same time."
}

main() {
  parse_args "$@"
  check_platform
  trap cleanup_tmp EXIT
  if [[ $GLMMAYAINS_ACTION == uninstall ]]; then
    do_uninstall
  else
    do_install
  fi
}

# Not run when the file is sourced (for tests).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
