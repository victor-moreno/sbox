#!/bin/bash
# slurm-inner.sh — runs INSIDE the job's bwrap (see SLURM.md, "Job launcher").
# Usage: slurm-inner.sh <out> <err> <in> <open-mode> -- [script args]
#   <err> empty = same file as <out>; <in> empty = /dev/null;
#   <open-mode> truncate|append. The user script is at /run/sbox-job/script.
# Slurm itself writes to a broker-owned log dir; the user's -o/-e/-i are opened
# here so symlinks resolve inside the sandbox, not on the host as slurmstepd would.

# sbatch filename patterns: %% %A %a %J %j %N %n %s %t %u %x, optional zero-pad
# width (%3a); a backslash anywhere disables expansion (and is dropped)
expand() {
  local s=$1 out="" c w v
  if [[ $s == *\\* ]]; then printf '%s' "${s//\\/}"; return; fi
  while [ -n "$s" ]; do
    c=${s:0:1}; s=${s:1}
    if [ "$c" != % ]; then out+=$c; continue; fi
    w=""; while [[ ${s:0:1} == [0-9] ]]; do w+=${s:0:1}; s=${s:1}; done
    c=${s:0:1}; s=${s:1}
    case $c in
      %) out+=%; continue ;;
      A) v=${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID} ;;
      a) v=${SLURM_ARRAY_TASK_ID:-4294967294} ;;
      j) v=$SLURM_JOB_ID ;;
      J) v=$SLURM_JOB_ID.batch ;;
      N) v=${SLURMD_NODENAME:-$(hostname -s)} ;;
      n|t) v=0 ;;
      s) v=batch ;;
      u) v=$USER ;;
      x) v=$SLURM_JOB_NAME ;;
      *) out+="%$w$c"; continue ;;   # unknown: kept literally
    esac
    if [ -n "$w" ] && [[ $v =~ ^[0-9]+$ ]]; then printf -v v "%0${w}d" "$((10#$v))"; fi
    out+=$v
  done
  printf '%s' "$out"
}

out=$(expand "$1"); err=$2; in=$3; mode=$4; shift 4
[ "$1" = -- ] && shift
[ -n "$err" ] && err=$(expand "$err")
[ -n "$in" ] && in=$(expand "$in") || in=/dev/null

if [ "$mode" = append ]; then exec >>"$out"; else exec >"$out"; fi || exit 98
if [ -z "$err" ] || [ "$err" = "$out" ]; then
  exec 2>&1
elif [ "$mode" = append ]; then exec 2>>"$err"
else exec 2>"$err"
fi || exit 98
exec <"$in" || exit 98

# SLURM_NET: bridge the job's private loopback to the netproxy the launcher
# started on the node (HTTP(S)_PROXY points here); ( & ) keeps it out of the script's jobs
if [ -S /run/sbox-net/proxy.sock ]; then
  ( "${SBOX_PYTHON:-python3}" /run/sbox-netproxy.py forward --listen 3128 --unix /run/sbox-net/proxy.sock >/dev/null 2>&1 & )
  for _i in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done
fi

# --publish: the node's PORT (listener outside bwrap) reaches the job's own
# 127.0.0.1:PORT through this relay
if [ -n "${SBOX_PUBLISH_PORT:-}" ] && [ -d /run/sbox-pub ]; then
  ( "${SBOX_PYTHON:-python3}" /run/sbox-netproxy.py relay --unix /run/sbox-pub/sock \
      --connect "127.0.0.1:$SBOX_PUBLISH_PORT" >/dev/null 2>&1 & )
  for _i in $(seq 50); do [ -S /run/sbox-pub/sock ] && break; sleep 0.1; done
fi

# honour the shebang like sbatch does (the data-bound file isn't executable);
# as in Linux, everything after the interpreter is one argument
IFS= read -r first < /run/sbox-job/script
first=${first#\#!}; first=${first%$'\r'}
first=${first#"${first%%[![:space:]]*}"}
interp=${first%%[[:space:]]*}
arg=${first#"$interp"}; arg=${arg#"${arg%%[![:space:]]*}"}; arg=${arg%"${arg##*[![:space:]]}"}
exec "${interp:-/bin/bash}" ${arg:+"$arg"} /run/sbox-job/script "$@"
