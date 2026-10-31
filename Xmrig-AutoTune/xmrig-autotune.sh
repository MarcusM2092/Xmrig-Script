#!/usr/bin/env bash
# xmrig-autotune.sh
# Detects CPU / L3 cache / RAM, builds candidate thread layouts for RandomX,
# benchmarks each with XMRig, and writes the best one to a config file.
#
# Usage:  ./xmrig-autotune.sh [-x /path/to/xmrig] [-b 1M] [-f] [-o outdir]
#   -x  path to xmrig binary         (default: ./xmrig)
#   -b  benchmark size: auto (default), or 250K, 1M, 2M, 4M, 10M
#       auto does a quick speed check first, then either picks a bench size taking
#       ~90s per test, or (on slow CPUs like a Raspberry Pi) runs timed tests instead
#       (override the target with TARGET_SEC=60 ./xmrig-autotune.sh ...)
#   -f  force run even if monerod is running (results will be skewed)
#   -o  output directory             (default: ./autotune-results)
#
# Run as a normal user; the script uses sudo for xmrig (needed for the MSR mod).

set -uo pipefail

XMRIG="./xmrig"
BENCH="auto"
OUTDIR="./autotune-results"
FORCE=0

while getopts "x:b:o:fh" opt; do
  case $opt in
    x) XMRIG="$OPTARG" ;;
    b) BENCH="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    f) FORCE=1 ;;
    *) sed -n '2,17p' "$0"; exit 0 ;;
  esac
done

[[ -x "$XMRIG" ]] || { echo "xmrig not found or not executable at: $XMRIG (use -x)"; exit 1; }
echo "XMRig build: $("$XMRIG" --version 2>/dev/null | head -1)"

if pgrep -x monerod >/dev/null && [[ $FORCE -eq 0 ]]; then
  echo "monerod is running. It would compete for CPU and skew results."
  echo "Wait for the sync to finish (or use -f to ignore this)."
  exit 1
fi

if pgrep -x xmrig >/dev/null && [[ $FORCE -eq 0 ]]; then
  echo "An xmrig process is already running (maybe your real miner). It would skew the results."
  echo "Stop it first (or use -f to ignore this). The autotune never touches other xmrig processes."
  exit 1
fi

# --- benchmark size -> number of hashes -------------------------------------
case "${BENCH^^}" in
  AUTO) BENCH_HASHES=0 ;;
  *K)   BENCH_HASHES=$(( ${BENCH%[kK]} * 1000 )) ;;
  *M)   BENCH_HASHES=$(( ${BENCH%[mM]} * 1000000 )) ;;
  *)    BENCH_HASHES=$BENCH ;;
esac

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Ctrl+C stops the running benchmark and exits instead of leaving xmrig running
trap 'echo; echo "Interrupted, stopping the benchmark..."; $SUDO pkill -TERM -f -- "--config=$OUTDIR/candidate-"; exit 130' INT TERM

mkdir -p "$OUTDIR"

# --- helpers ----------------------------------------------------------------
expand() {  # "0-3,8" -> "0 1 2 3 8"
  local out=() part i
  IFS=',' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      for ((i=${part%-*}; i<=${part#*-}; i++)); do out+=("$i"); done
    else
      out+=("$part")
    fi
  done
  echo "${out[@]}"
}

join() { local IFS=,; echo "$*"; }

# --- detect hardware --------------------------------------------------------
MODEL=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
TOTAL=$(nproc --all)

# L3 size (sum of unique L3 instances isn't needed; sysfs reports per-instance size)
L3_KB=0
for d in /sys/devices/system/cpu/cpu0/cache/index*; do
  [[ -r $d/level && $(cat "$d/level") == 3 ]] || continue
  raw=$(cat "$d/size")                       # e.g. 33792K or 32M
  case $raw in
    *K) L3_KB=${raw%K} ;;
    *M) L3_KB=$(( ${raw%M} * 1024 )) ;;
  esac
done
HAVE_L3=1
if [[ $L3_KB -eq 0 ]]; then
  HAVE_L3=0                                   # common on ARM (e.g. Raspberry Pi): no L3 reported
  L3_MB=0
  CACHE_CAP=$TOTAL                            # the 2 MB-per-thread rule is not applied
else
  L3_MB=$(( L3_KB / 1024 ))
  CACHE_CAP=$(( L3_MB / 2 ))                  # RandomX: ~2 MB L3 per thread
  [[ $CACHE_CAP -gt $TOTAL ]] && CACHE_CAP=$TOTAL
  [[ $CACHE_CAP -lt 1 ]] && CACHE_CAP=1
fi

MEM_AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if [[ $MEM_AVAIL_MB -lt 2600 ]]; then
  echo "WARNING: only ${MEM_AVAIL_MB} MB RAM available. RandomX fast mode needs ~2.1 GB; results will be poor."
fi

# --- physical cores vs SMT siblings -----------------------------------------
declare -A seen isP
phys=(); sib=()
while IFS=, read -r cpu core sock; do
  key="$sock-$core"
  if [[ -z ${seen[$key]:-} ]]; then seen[$key]=1; phys+=("$cpu"); else sib+=("$cpu"); fi
done < <(lscpu -p=CPU,CORE,SOCKET | grep -v '^#')

HYBRID=0
if [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]; then
  HYBRID=1
  for c in $(expand "$(cat /sys/devices/cpu_core/cpus)"); do isP[$c]=1; done
fi

pphys=(); ephys=(); psib=(); esib=()
if [[ $HYBRID -eq 1 ]]; then
  for c in "${phys[@]}"; do [[ -n ${isP[$c]:-} ]] && pphys+=("$c") || ephys+=("$c"); done
  for c in "${sib[@]}";  do [[ -n ${isP[$c]:-} ]] && psib+=("$c")  || esib+=("$c");  done
  ORDER=("${pphys[@]}" "${ephys[@]}" "${psib[@]}" "${esib[@]}")
else
  pphys=("${phys[@]}")
  ORDER=("${phys[@]}" "${sib[@]}")
fi

echo "=============================================="
echo " CPU:            $MODEL"
echo " Threads:        $TOTAL  (physical cores: ${#phys[@]})"
[[ $HYBRID -eq 1 ]] && echo " Hybrid:         ${#pphys[@]} P-cores, ${#ephys[@]} E-cores"
if [[ $HAVE_L3 -eq 1 ]]; then echo " L3 cache:       ${L3_MB} MB  -> cache-limited to ~${CACHE_CAP} threads"; else echo " L3 cache:       none reported (typical for ARM) -> cache rule not applied"; fi
echo " RAM available:  ${MEM_AVAIL_MB} MB"
if [[ ${BENCH,,} == auto ]]; then echo " Bench size:     auto (calibrated from a quick first run)"; else echo " Bench size:     $BENCH ($BENCH_HASHES hashes)"; fi
echo "=============================================="

# --- build candidate layouts ------------------------------------------------
declare -A CAND_SEEN
CAND_NAMES=(); CAND_LISTS=()

add_candidate() {  # name, cpu,list
  local name=$1 list=$2
  [[ -z $list ]] && return
  [[ -n ${CAND_SEEN[$list]:-} ]] && return
  CAND_SEEN[$list]=1
  CAND_NAMES+=("$name"); CAND_LISTS+=("$list")
}

prefix() { local n=$1; [[ $n -gt ${#ORDER[@]} ]] && n=${#ORDER[@]}; join "${ORDER[@]:0:$n}"; }

[[ $HAVE_L3 -eq 1 ]] && add_candidate "cache-cap (${CACHE_CAP} threads)" "$(prefix "$CACHE_CAP")"
add_candidate "one thread per core (${#phys[@]})"       "$(prefix "${#phys[@]}")"
add_candidate "all threads ($TOTAL)"                    "$(prefix "$TOTAL")"
if [[ $HYBRID -eq 1 ]]; then
  add_candidate "P-cores only, 1T each (${#pphys[@]})"  "$(join "${pphys[@]}")"
  add_candidate "P-cores only, all threads ($(( ${#pphys[@]} + ${#psib[@]} )))" "$(join "${pphys[@]}" "${psib[@]}")"
fi
if [[ $HAVE_L3 -eq 1 ]]; then
  # one step below the cache cap, in case of background-load noise
  [[ $CACHE_CAP -gt 4 ]] && add_candidate "cache-cap minus 2 ($(( CACHE_CAP - 2 )))" "$(prefix $(( CACHE_CAP - 2 )))"
else
  # no cache rule to go by, so also try leaving some cores free
  [[ $TOTAL -ge 3 ]] && add_candidate "all minus 1 ($(( TOTAL - 1 )) threads)" "$(prefix $(( TOTAL - 1 )))"
  [[ $TOTAL -ge 4 ]] && add_candidate "half ($(( TOTAL / 2 )) threads)"        "$(prefix $(( TOTAL / 2 )))"
fi

echo "Candidates to test: ${#CAND_NAMES[@]}"
for i in "${!CAND_NAMES[@]}"; do echo "  [$i] ${CAND_NAMES[$i]}: ${CAND_LISTS[$i]}"; done
echo

# --- run benchmarks ---------------------------------------------------------
TARGET_SEC="${TARGET_SEC:-90}"        # fixed-size mode: aim for ~this many seconds per candidate
TIMED_SEC="${TIMED_SEC:-90}"          # timed mode: seconds of hashing per candidate
CAL_SEC="${CAL_SEC:-25}"              # quick speed check: seconds of hashing
MAX_FULL_SEC="${MAX_FULL_SEC:-300}"   # if the smallest standard bench would take longer, use timed mode
POLL="${POLL:-3}"

mean_speed() {  # logfile  n  -> mean of the last n numeric 10s speed samples
  grep 'speed 10s/60s/15m' "$1" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="10s/60s/15m" && $(i+1) ~ /^[0-9.]+$/) print $(i+1)}' \
    | tail -n "$2" | awk '{s+=$1;c++} END{if(c) printf "%.1f", s/c; else print 0}'
}

run_one() {  # index  size_label  size_hashes  [timed_seconds]   -> sets HR
  local i=$1 label=$2 nhash=$3 timed=${4:-0}
  local name=${CAND_NAMES[$i]} list=${CAND_LISTS[$i]}
  local cfg="$OUTDIR/candidate-$i.json"
  local log="$OUTDIR/candidate-$i.log"
  local start now el phase cur pct eta bp bs secs hr XPID hstart=0 how

  cat > "$cfg" <<EOF
{
  "autosave": false,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "yield": true,
    "asm": true,
    "rx": [$list]
  },
  "randomx": { "mode": "auto", "1gb-pages": false },
  "pools": []
}
EOF

  rm -f "$log"
  if [[ $timed -gt 0 ]]; then how="timed ${timed}s"; else how="bench $label"; fi
  echo ">>> [$i/$(( ${#CAND_NAMES[@]} - 1 ))] $name  ($how)"
  $SUDO timeout 7200 "$XMRIG" --config="$cfg" --bench="$label" --no-color --print-time=5 --log-file="$log" < /dev/null > "$log.stdout" 2>&1 &
  XPID=$!
  start=$(date +%s)
  while kill -0 "$XPID" 2>/dev/null; do
    sleep "$POLL"
    now=$(date +%s); el=$(( now - start ))
    if grep -q 'dataset ready' "$log" 2>/dev/null; then
      phase="hashing"; [[ $hstart -eq 0 ]] && hstart=$now
    else
      phase="initialising dataset"
    fi
    cur=$(grep 'speed 10s/60s/15m' "$log" 2>/dev/null | tail -1 \
          | awk '{for(i=1;i<=NF;i++) if($i=="10s/60s/15m"){print $(i+1); exit}}')

    if [[ $timed -gt 0 ]]; then
      if [[ $hstart -gt 0 ]]; then
        printf "\r\033[K    [hashing] %ds / %ds | %s H/s" "$(( now - hstart ))" "$timed" "${cur:-n/a}"
        if [[ $(( now - hstart )) -ge $timed ]]; then
          $SUDO pkill -TERM -f -- "--config=$cfg" 2>/dev/null
          break
        fi
      else
        printf "\r\033[K    [%s] %ds elapsed" "$phase" "$el"
      fi
      continue
    fi

    # fixed-size mode: XMRig prints real progress ("bench  16.37% 40921/250000 (40.029s)")
    bp=$(grep -oE 'bench +[0-9.]+%' "$log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+')
    bs=$(grep -oE 'bench +[0-9.]+% [0-9]+/[0-9]+ \([0-9.]+s\)' "$log" 2>/dev/null | tail -1 | grep -oE '\([0-9.]+s\)' | tr -d '(s)')
    if [[ ${bp:-} =~ ^[0-9.]+$ && ${bs:-} =~ ^[0-9.]+$ ]] && awk -v p="$bp" 'BEGIN{exit !(p>0)}'; then
      eta=$(awk -v p="$bp" -v t="$bs" 'BEGIN{printf "%d", t*(100-p)/p}')
      printf "\r\033[K    [%s] %ds elapsed | %s H/s | %s%% | ~%ds left" "$phase" "$el" "${cur:-?}" "$bp" "$eta"
    elif [[ ${cur:-} =~ ^[0-9.]+$ ]]; then
      pct=$(awk -v c="$cur" -v e="$el" -v n="$nhash" 'BEGIN{p=c*e/n*100; if(p>99)p=99; printf "%d", p}')
      eta=$(awk -v c="$cur" -v e="$el" -v n="$nhash" 'BEGIN{r=n/c-e; if(r<0)r=0; printf "%d", r}')
      printf "\r\033[K    [%s] %ds elapsed | %s H/s | ~%s%% | ~%ds left" "$phase" "$el" "$cur" "$pct" "$eta"
    else
      printf "\r\033[K    [%s] %ds elapsed" "$phase" "$el"
    fi
  done
  wait "$XPID" 2>/dev/null
  printf "\r\033[K"

  hr=0
  if [[ $timed -gt 0 ]]; then
    hr=$(mean_speed "$log" 4)
  else
    secs=$(grep -oE 'benchmark finished in [0-9.]+' "$log" | tail -1 | grep -oE '[0-9.]+$')
    if [[ -n ${secs:-} ]]; then
      hr=$(awk -v n="$nhash" -v s="$secs" 'BEGIN{printf "%.1f", n/s}')
    else
      hr=$(mean_speed "$log" 1)
    fi
  fi
  [[ ${hr:-} =~ ^[0-9.]+$ ]] || hr=0
  echo "    result: $hr H/s"
  HR=$hr
  sleep 5   # let temps settle slightly between runs
}

RESULTS=()
MODE=fixed
SIZE_LABEL="$BENCH"; SIZE_HASHES="${BENCH_HASHES:-0}"

if [[ ${BENCH,,} == auto ]]; then
  echo "Auto mode: quick ${CAL_SEC}s speed check on candidate 0..."
  run_one 0 10M 10000000 "$CAL_SEC"
  CAL=$HR
  EST=$(awk -v h="$CAL" 'BEGIN{ if (h>0) printf "%d", 250000/h; else print 999999 }')
  if (( EST > MAX_FULL_SEC )); then
    MODE=timed
    echo "Speed ~${CAL} H/s: the smallest standard benchmark (250K) would take ~$(( EST / 60 )) min per candidate."
    echo "Using timed mode instead: ${TIMED_SEC}s of hashing per candidate."
  else
    WANT=$(awk -v h="$CAL" -v t="$TARGET_SEC" 'BEGIN{printf "%d", h*t}')
    SIZE_LABEL=250K; SIZE_HASHES=250000
    for pair in 1M:1000000 2M:2000000 4M:4000000 10M:10000000; do
      if [[ $SIZE_HASHES -lt $WANT ]]; then SIZE_LABEL=${pair%%:*}; SIZE_HASHES=${pair##*:}; fi
    done
    echo "Speed ~${CAL} H/s -> using bench size $SIZE_LABEL (target ~${TARGET_SEC}s per candidate)"
  fi
  echo
fi

for ((i=0; i<${#CAND_NAMES[@]}; i++)); do
  if [[ $MODE == timed ]]; then
    run_one "$i" 10M 10000000 "$TIMED_SEC"
  else
    run_one "$i" "$SIZE_LABEL" "$SIZE_HASHES"
  fi
  RESULTS+=("$HR|$i")
done

# --- summarise --------------------------------------------------------------
echo
echo "================= RESULTS (best first) ================="
BEST_IDX=-1; BEST_HR=0
while IFS='|' read -r hr idx; do
  printf "  %10s H/s   %s\n" "$hr" "${CAND_NAMES[$idx]}"
  if [[ $BEST_IDX -eq -1 ]]; then BEST_IDX=$idx; BEST_HR=$hr; fi
done < <(printf '%s\n' "${RESULTS[@]}" | sort -t'|' -k1,1 -nr)

if [[ $BEST_IDX -eq -1 || $BEST_HR == 0 ]]; then
  echo
  echo "No valid hashrate was parsed. Check the logs in $OUTDIR/ (candidate-N.log)"
  echo "and adjust the grep patterns in this script to match your XMRig version's output."
  exit 1
fi

BEST_LIST=${CAND_LISTS[$BEST_IDX]}
OUT_CFG="$OUTDIR/xmrig-best-config.json"
cat > "$OUT_CFG" <<EOF
{
  "autosave": false,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "yield": true,
    "asm": true,
    "rx": [$BEST_LIST]
  },
  "randomx": { "mode": "auto", "1gb-pages": false },
  "pools": [
    {
      "url": "127.0.0.1:3333",
      "user": "x",
      "pass": "x",
      "keepalive": true,
      "tls": false
    }
  ]
}
EOF

echo
echo "Best layout: ${CAND_NAMES[$BEST_IDX]}  (~${BEST_HR} H/s)"
echo "Config written to: $OUT_CFG"
echo "It points at P2Pool on 127.0.0.1:3333. Run with:"
echo "  sudo $XMRIG --config=$OUT_CFG"
