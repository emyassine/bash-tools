#!/usr/bin/env bash
# srt-shift.sh - shift the timing of SRT subtitle files, safely.
#
# Safety design:
#   * All maths is done in integer milliseconds (no floating point drift).
#   * Only the timing lines are rewritten; every other byte (text, CRLF line
#     endings, BOM, missing final newline, position tags) is preserved.
#   * The result is verified by an independent second pass before anything is
#     written. If verification fails, the original file is never touched.
#   * The new file is written atomically (temp file in the same directory, then
#     rename), so an interrupted run cannot leave a half-written subtitle.
#   * Every change is backed up first, in a state directory (not next to your
#     media), and can be reverted with --undo / --undo-all.
#
# Backups live in: ${SRT_SHIFT_STATE:-${XDG_STATE_HOME:-~/.local/state}/srt-shift}
#
# Dependencies: bash, awk, coreutils (all present on a default Debian install).

set -Eeuo pipefail
export LC_ALL=C

PROG=${0##*/}
STATE_ROOT=${SRT_SHIFT_STATE:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/srt-shift}

OFFSET_MS=0
FROM_MS=0
UNTIL_MS=-1
CLAMP=1
DRY=0
FORCE=0
YES=0
MODE=shift
WORK=''
declare -a PENDING_TMP=()
declare -a FILES=()
FOUND_DIR=0

# ------------------------------------------------------------------ awk code
read -r -d '' AWK_LIB <<'EOF' || true
BEGIN {
  TS = "[0-9]+:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9]?[0-9]?"
  TIMING_RE = "^[ \t]*" TS "[ \t]*-->[ \t]*" TS "([ \t\r].*)?$"
  off = off + 0; from = from + 0; until = until + 0; clamp = clamp + 0
}
function parse_ts(t,   p, f) {
  split(t, p, /[:,.]/)
  f = p[4] ""
  while (length(f) < 3) f = f "0"
  return ((p[1] * 60 + p[2]) * 60 + p[3]) * 1000 + substr(f, 1, 3) + 0
}
function fmt_ts(n,   h, m, s, ms) {
  h = int(n / 3600000); n -= h * 3600000
  m = int(n / 60000);   n -= m * 60000
  s = int(n / 1000);    ms = n - s * 1000
  return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
}
function split_timing(line,   sides, right, rt) {
  split(line, sides, "-->")
  T_START = sides[1]; gsub(/[ \t]/, "", T_START)
  right = sides[2]
  match(right, /^[ \t]*[0-9:,.]+/)
  rt = substr(right, RSTART, RLENGTH)
  T_REST = substr(right, RLENGTH + 1)
  gsub(/[ \t]/, "", rt)
  T_END = rt
}
function in_range(s) { return (s >= from && (until < 0 || s < until)) }
EOF

read -r -d '' AWK_SHIFT <<'EOF' || true
{
  if ($0 ~ TIMING_RE) {
    split_timing($0)
    s = parse_ts(T_START); e = parse_ts(T_END)
    cues++
    if (e < s) badorder++
    ns = s; ne = e
    if (in_range(s)) {
      ns = s + off; ne = e + off; shifted++
      if (ns < 0 || ne < 0) {
        if (clamp) { if (ns < 0) ns = 0; if (ne < 0) ne = 0; clamped++; if (ne == 0) hidden++ }
        else { negative++; if (!neg_line) neg_line = NR }
      }
      if (!seen_first) { seen_first = 1; first_before = fmt_ts(s); first_after = fmt_ts(ns) }
      last_before = fmt_ts(s); last_after = fmt_ts(ns)
    }
    print fmt_ts(ns) " --> " fmt_ts(ne) T_REST
  } else {
    print
  }
}
END {
  printf "cues=%d\nshifted=%d\nclamped=%d\nhidden=%d\nnegative=%d\nneg_line=%d\nbadorder=%d\n", \
    cues, shifted, clamped, hidden, negative, neg_line, badorder > statsfile
  printf "first_before=%s\nfirst_after=%s\nlast_before=%s\nlast_after=%s\n", \
    first_before, first_after, last_before, last_after > statsfile
  close(statsfile)
}
EOF

# Independent verification: compares original and result line by line.
read -r -d '' AWK_VERIFY <<'EOF' || true
FNR == NR { orig[FNR] = $0; n1 = FNR; next }
{
  n2 = FNR
  if (!(FNR in orig)) { bad++; next }
  o = orig[FNR]
  if (o ~ TIMING_RE) {
    split_timing(o)
    os = parse_ts(T_START); oe = parse_ts(T_END); orest = T_REST
    xs = os; xe = oe
    if (in_range(os)) {
      xs = os + off; xe = oe + off
      if (clamp) { if (xs < 0) xs = 0; if (xe < 0) xe = 0 }
    }
    if ($0 !~ TIMING_RE) { bad++; next }
    split_timing($0)
    if (parse_ts(T_START) != xs || parse_ts(T_END) != xe || T_REST != orest) bad++
  } else if ($0 != o) {
    bad++
  }
}
END { if (n1 != n2) bad++; print bad + 0 }
EOF

# -------------------------------------------------------------------- helpers
log() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  cat <<USAGE
Usage: $PROG [options] PATH...

Shift the timing of SRT subtitle files. PATH can be .srt files or directories (searched
recursively). If you give a media file (e.g. song.webm), the matching .srt next
to it is found and you are asked whether to use it instead.

Shift options:
  --add=VALUE        Delay subtitles by VALUE (cues appear later)
  --sub=VALUE        Make subtitles earlier by VALUE (cues appear sooner)
  --from=TIME        Only shift cues that start at or after TIME
  --until=TIME       Only shift cues that start before TIME
  --strict           Refuse (leave the file untouched) if any time would go
                     below 00:00:00,000. Default: clamp those times to zero
                     and print a warning (a cue that ends up entirely before
                     zero becomes zero-length, i.e. invisible)
  -n, --dry-run      Show what would change, write nothing
  -y, --yes          Do not ask for confirmation when several files are given

Revert options:
      --undo         Restore the previous version of each file (one step)
      --undo-all     Restore the very first original of each file
      --history      Show saved backups for each file
  -f, --force        Allow --undo even if the file was modified since the shift

VALUE accepts: 16s  1600ms  1.5s  2m  1h  -2s  00:16  00:00:16,500
TIME  accepts: the same formats, not negative.
Options can be written as --add=16s or --add 16s. --add and --sub accumulate.

Examples:
  $PROG --add=16s song.srt
  $PROG --sub=1600ms song.srt
  $PROG --add=15s --from=00:00:15,950 song.srt   # fix only the later cues
  $PROG --dry-run --add=2s ~/Music/subs/
  $PROG --undo song.srt

Backups: $STATE_ROOT
USAGE
}

cleanup() {
  local f
  for f in "${PENDING_TMP[@]:-}"; do
    if [[ -n $f && -e $f ]]; then unlink -- "$f" 2>/dev/null || true; fi
  done
  if [[ -n $WORK && -d $WORK ]]; then
    for f in "$WORK"/*; do
      if [[ -e $f ]]; then unlink -- "$f" 2>/dev/null || true; fi
    done
    rmdir -- "$WORK" 2>/dev/null || true
  fi
}

sha_of() { sha256sum -- "$1" | cut -d' ' -f1; }
path_key() { printf '%s' "$1" | sha256sum | cut -c1-24; }

# parse_time_ms STRING -> sets PARSED_MS (signed integer milliseconds)
parse_time_ms() {
  local s=$1 sign=1 int frac unit mult pow num fr h m sec f i
  case $s in
    -*) sign=-1; s=${s#-} ;;
    +*) s=${s#+} ;;
  esac
  if [[ $s =~ ^([0-9]+)(\.([0-9]+))?(ms|s|m|h)$ ]]; then
    int=${BASH_REMATCH[1]}; frac=${BASH_REMATCH[3]}; unit=${BASH_REMATCH[4]}
    ((${#int} <= 9 && ${#frac} <= 9)) || return 1
    case $unit in ms) mult=1 ;; s) mult=1000 ;; m) mult=60000 ;; h) mult=3600000 ;; esac
    num=$((10#$int * mult))
    if [[ -n $frac ]]; then
      pow=1
      for ((i = 0; i < ${#frac}; i++)); do pow=$((pow * 10)); done
      fr=$((10#$frac * mult))
      ((fr % pow == 0)) || return 1   # would need sub-millisecond precision
      num=$((num + fr / pow))
    fi
  elif [[ $s =~ ^(([0-9]+):)?([0-9]+):([0-9]+)([.,]([0-9]{1,3}))?$ ]]; then
    h=${BASH_REMATCH[2]:-0}; m=${BASH_REMATCH[3]}; sec=${BASH_REMATCH[4]}; f=${BASH_REMATCH[6]:-0}
    ((${#h} <= 6 && ${#m} <= 6 && ${#sec} <= 6)) || return 1
    ((10#$sec < 60)) || return 1
    if [[ -n ${BASH_REMATCH[2]} ]]; then ((10#$m < 60)) || return 1; fi
    f=${f}000; f=${f:0:3}
    num=$(((((10#$h * 60) + 10#$m) * 60 + 10#$sec) * 1000 + 10#$f))
  else
    return 1
  fi
  PARSED_MS=$((sign * num))
}

fmt_offset() { # ms -> +16.000s
  local n=$1 sign=+
  if ((n < 0)); then sign=-; n=$((-n)); fi
  printf '%s%d.%03ds' "$sign" "$((n / 1000))" "$((n % 1000))"
}

set_opt() { # name value
  local name=$1 value=$2
  parse_time_ms "$value" || die "invalid value for $name: '$value' (examples: 16s, 1600ms, 1.5s, 00:00:16,500)"
  case $name in
    --add) OFFSET_MS=$((OFFSET_MS + PARSED_MS)) ;;
    --sub) OFFSET_MS=$((OFFSET_MS - PARSED_MS)) ;;
    --from|--until)
      ((PARSED_MS >= 0)) || die "$name cannot be negative"
      if [[ $name == --from ]]; then FROM_MS=$PARSED_MS; else UNTIL_MS=$PARSED_MS; fi
      ;;
  esac
}

# Subtitle files sitting next to a non-.srt path (e.g. song.webm -> song.srt,
# song.lyrics.srt, song.en.srt). The exact "song.srt" is listed first.
SIBLINGS=()
CHOSEN=''
find_sibling_srts() { # path -> fills SIBLINGS
  local f=$1 dir name bname c cname
  local -a exact=() others=()
  SIBLINGS=()
  dir=${f%/*}
  [[ $dir != "$f" ]] || dir=.
  name=${f##*/}
  bname=$name
  [[ $name != *.* ]] || bname=${name%.*}
  for c in "$dir"/*; do
    [[ -f $c ]] || continue
    cname=${c##*/}
    [[ ${cname,,} == *.srt ]] || continue
    [[ $cname == "$bname".* ]] || continue
    if [[ ${cname,,} == "${bname,,}.srt" ]]; then exact+=("$c"); else others+=("$c"); fi
  done
  SIBLINGS=("${exact[@]}" "${others[@]}")
}

# The given path is not an .srt: offer the matching subtitle(s) instead.
# Sets CHOSEN; returns 1 if nothing usable or the user declined.
choose_sibling() { # path
  local media=$1 n i ans
  find_sibling_srts "$media"
  n=${#SIBLINGS[@]}
  if ((n == 0)); then
    err "not an .srt file and no matching .srt found next to it: $media"
    return 1
  fi
  log "Not an .srt file: $media"
  if [[ ! -t 0 ]]; then
    if ((n == 1 && (YES || DRY))); then
      log "Using subtitle: ${SIBLINGS[0]}"
      CHOSEN=${SIBLINGS[0]}
      return 0
    fi
    err "  subtitle found: ${SIBLINGS[0]} (pass that path, or use --yes when exactly one exists)"
    return 1
  fi
  if ((n == 1)); then
    if ((YES)); then CHOSEN=${SIBLINGS[0]}; log "Using subtitle: $CHOSEN"; return 0; fi
    printf 'Found subtitle: %s\nUse it instead? [Y/n] ' "${SIBLINGS[0]}"
    IFS= read -r ans || ans=n
    case ${ans,,} in n|no) log "  Skipped."; return 1 ;; esac
    CHOSEN=${SIBLINGS[0]}
    return 0
  fi
  log "Found several subtitles next to it:"
  for ((i = 0; i < n; i++)); do printf '  %d) %s\n' "$((i + 1))" "${SIBLINGS[i]}"; done
  printf 'Choice [Enter = 1, 0 = skip]: '
  IFS= read -r ans || ans=0
  [[ -n $ans ]] || ans=1
  if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= n)); then
    CHOSEN=${SIBLINGS[ans - 1]}
    return 0
  fi
  log "  Skipped."
  return 1
}

collect_files() {
  local arg
  local -a found=()
  for arg in "$@"; do
    if [[ -d $arg ]]; then
      FOUND_DIR=1
      mapfile -d '' found < <(find "$arg" -type f -iname '*.srt' -print0 | sort -z)
      FILES+=("${found[@]}")
    elif [[ -e $arg || -L $arg ]]; then
      case ${arg,,} in
        *.srt) FILES+=("$arg") ;;
        *) if choose_sibling "$arg"; then FILES+=("$CHOSEN"); fi ;;
      esac
    elif [[ $MODE == undo* ]]; then
      FILES+=("$arg")   # file may have been deleted; history can still restore it
    else
      err "not found: $arg"
      return 1
    fi
  done
}

confirm_batch() {
  local ans
  ((${#FILES[@]} > 1)) || return 0
  ((YES || DRY)) && return 0
  if [[ ! -t 0 ]]; then
    die "${#FILES[@]} files selected; re-run with --yes to confirm (or --dry-run to preview)"
  fi
  printf '%d files will be modified (offset %s). Backups are kept. Continue? [y/N] ' \
    "${#FILES[@]}" "$(fmt_offset "$OFFSET_MS")"
  IFS= read -r ans || ans=
  case ${ans,,} in y|yes) ;; *) log "Aborted."; exit 1 ;; esac
}

# ---------------------------------------------------------------------- shift
shift_file() {
  local file=$1 real dir tmp stats head3 last k v bad id key edir
  local cues=0 shifted=0 clamped=0 hidden=0 negative=0 neg_line=0 badorder=0
  local first_before='' first_after='' last_before='' last_after=''

  real=$(realpath -- "$file" 2>/dev/null) || { err "$file: cannot resolve path"; return 1; }
  [[ -f $real && -r $real ]] || { err "$file: not a readable regular file"; return 1; }
  [[ -s $real ]] || { err "$file: file is empty"; return 1; }
  dir=${real%/*}; [[ -n $dir ]] || dir=/
  [[ -w $dir ]] || { err "$file: directory is not writable"; return 1; }

  head3=$(head -c2 -- "$real" | od -An -tx1 | tr -d ' \n')
  case $head3 in
    fffe|feff) err "$file: UTF-16 file; convert first: iconv -f UTF-16 -t UTF-8 in.srt > out.srt"; return 1 ;;
  esac

  stats="$WORK/stats.txt"
  : > "$stats"
  tmp=$(mktemp -- "$dir/.${real##*/}.shift.XXXXXX")
  PENDING_TMP+=("$tmp")

  awk -v off="$OFFSET_MS" -v from="$FROM_MS" -v until="$UNTIL_MS" -v clamp="$CLAMP" \
      -v statsfile="$stats" "$AWK_LIB"$'\n'"$AWK_SHIFT" "$real" > "$tmp"

  while IFS='=' read -r k v; do
    case $k in
      cues) cues=$v ;; shifted) shifted=$v ;; clamped) clamped=$v ;; hidden) hidden=$v ;;
      negative) negative=$v ;; neg_line) neg_line=$v ;; badorder) badorder=$v ;;
      first_before) first_before=$v ;; first_after) first_after=$v ;;
      last_before) last_before=$v ;; last_after) last_after=$v ;;
    esac
  done < "$stats"

  if ((cues == 0)); then
    err "$file: no SRT timing lines found, not a valid SRT. File untouched."
    return 1
  fi
  if ((negative > 0)); then
    err "$file: $negative cue(s) would start before 00:00:00,000 (first at line $neg_line). File untouched (--strict)."
    err "  Use a smaller offset, restrict with --from, or drop --strict to clamp."
    return 1
  fi

  # Preserve a missing final newline exactly as in the source.
  last=$(tail -c1 -- "$real" | od -An -tx1 | tr -d ' \n')
  if [[ $last != 0a ]]; then truncate -s -1 -- "$tmp"; fi

  bad=$(awk -v off="$OFFSET_MS" -v from="$FROM_MS" -v until="$UNTIL_MS" -v clamp="$CLAMP" \
        "$AWK_LIB"$'\n'"$AWK_VERIFY" "$real" "$tmp")
  if [[ $bad != 0 ]]; then
    err "$file: verification failed ($bad mismatches). File untouched."
    return 1
  fi

  log "$real"
  log "  cues: $cues, shifted: $shifted, clamped: $clamped, offset: $(fmt_offset "$OFFSET_MS")"
  if ((shifted > 0)); then
    log "  first shifted cue starts: $first_before -> $first_after"
    log "  last shifted cue starts:  $last_before -> $last_after"
  fi
  if ((clamped > 0)); then
    log "  warning: $clamped cue(s) would have gone below zero and were clamped to 00:00:00,000"
    if ((hidden > 0)); then log "  warning: $hidden of them are now zero-length (invisible) because they ended before zero"; fi
  fi
  if ((badorder > 0)); then
    log "  warning: $badorder cue(s) already had end before start in the source"
  fi

  if ((shifted == 0)); then
    log "  No cues in the selected range; unchanged."
    return 0
  fi
  if ((DRY)); then
    log "  [dry-run] nothing written."
    return 0
  fi

  # Backup first, then atomic replace.
  id=$(date +%Y%m%dT%H%M%S.%N)
  key=$(path_key "$real")
  edir="$STATE_ROOT/$key"
  install -d -m 700 -- "$STATE_ROOT" "$edir"
  printf '%s\n' "$real" > "$edir/path"
  cp -p -- "$real" "$edir/$id.srt"
  if ! cmp -s -- "$real" "$edir/$id.srt"; then
    err "$file: backup verification failed. File untouched."
    unlink -- "$edir/$id.srt" 2>/dev/null || true
    return 1
  fi
  {
    printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'offset_ms=%s\nfrom_ms=%s\nuntil_ms=%s\nclamp=%s\n' "$OFFSET_MS" "$FROM_MS" "$UNTIL_MS" "$CLAMP"
    printf 'orig_sha=%s\nnew_sha=%s\n' "$(sha_of "$real")" "$(sha_of "$tmp")"
  } > "$edir/$id.meta"

  chmod --reference="$real" -- "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$real"; then
    err "$file: could not replace file; restoring state."
    unlink -- "$edir/$id.srt" 2>/dev/null || true
    unlink -- "$edir/$id.meta" 2>/dev/null || true
    return 1
  fi
  PENDING_TMP=()
  log "  Saved. Revert with: $PROG --undo \"$real\""
  return 0
}

# ----------------------------------------------------------------------- undo
latest_meta() { # edir -> path of newest .meta or empty
  find "$1" -maxdepth 1 -type f -name '*.meta' -print 2>/dev/null | sort | tail -n1
}

meta_get() { # metafile key
  local k v
  while IFS='=' read -r k v; do
    if [[ $k == "$2" ]]; then printf '%s' "$v"; return 0; fi
  done < "$1"
  return 1
}

undo_once() { # real edir -> 0 restored, 3 nothing to undo, 1 error
  local real=$1 edir=$2 meta id new_sha orig_sha cur tmp dir off
  meta=$(latest_meta "$edir")
  [[ -n $meta ]] || return 3
  id=${meta##*/}; id=${id%.meta}
  new_sha=$(meta_get "$meta" new_sha || true)
  orig_sha=$(meta_get "$meta" orig_sha || true)
  off=$(meta_get "$meta" offset_ms || echo 0)

  if [[ -e $real ]]; then
    cur=$(sha_of "$real")
    if [[ $cur != "$new_sha" && $FORCE -eq 0 ]]; then
      err "$real was modified after the last shift. Use --force to restore anyway."
      return 1
    fi
  fi
  if [[ ! -f $edir/$id.srt ]] || [[ $(sha_of "$edir/$id.srt") != "$orig_sha" ]]; then
    err "$real: backup $id is missing or corrupted; cannot restore."
    return 1
  fi
  if ((DRY)); then log "  [dry-run] would restore backup $id ($(meta_get "$meta" time || true))"; return 0; fi

  dir=${real%/*}; [[ -n $dir ]] || dir=/
  tmp=$(mktemp -- "$dir/.${real##*/}.undo.XXXXXX")
  PENDING_TMP+=("$tmp")
  cp -p -- "$edir/$id.srt" "$tmp"
  mv -f -- "$tmp" "$real"
  PENDING_TMP=()
  unlink -- "$edir/$id.srt"
  unlink -- "$meta"
  log "  Restored backup $id (offset $(fmt_offset "$off") undone)"
}

undo_file() { # file
  local file=$1 real edir rc steps=0
  real=$(realpath -m -- "$file")
  edir="$STATE_ROOT/$(path_key "$real")"
  if [[ ! -d $edir ]] || [[ -z $(latest_meta "$edir") ]]; then
    if ((FOUND_DIR)); then return 0; fi
    log "$real"; log "  No backups for this file."; return 1
  fi
  log "$real"
  while :; do
    rc=0; undo_once "$real" "$edir" || rc=$?
    case $rc in
      0) steps=$((steps + 1)) ;;
      3) break ;;
      *) return 1 ;;
    esac
    [[ $MODE == undo-all && $DRY -eq 0 ]] || break
  done
  ((steps > 0)) || { log "  Nothing to undo."; return 1; }
  return 0
}

history_file() { # file
  local file=$1 real edir m id
  real=$(realpath -m -- "$file")
  edir="$STATE_ROOT/$(path_key "$real")"
  if [[ ! -d $edir ]] || [[ -z $(latest_meta "$edir") ]]; then
    if ((FOUND_DIR)); then return 0; fi
    log "$real"; log "  No backups."; return 0
  fi
  log "$real"
  while IFS= read -r m; do
    id=${m##*/}; id=${id%.meta}
    log "  $id  $(meta_get "$m" time || true)  offset $(fmt_offset "$(meta_get "$m" offset_ms || echo 0)")  from_ms=$(meta_get "$m" from_ms || echo 0)"
  done < <(find "$edir" -maxdepth 1 -type f -name '*.meta' -print | sort)
}

# ----------------------------------------------------------------------- main
main() {
  local f ok=0 failed=0

  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --add|--sub|--from|--until)
        (($# >= 2)) || die "$1 needs a value"
        set_opt "$1" "$2"; shift 2; continue ;;
      --add=*|--sub=*|--from=*|--until=*)
        set_opt "${1%%=*}" "${1#*=}" ;;
      --clamp) CLAMP=1 ;;
      --strict) CLAMP=0 ;;
      -n|--dry-run) DRY=1 ;;
      -f|--force) FORCE=1 ;;
      -y|--yes) YES=1 ;;
      --undo) MODE=undo ;;
      --undo-all) MODE=undo-all ;;
      --history) MODE=history ;;
      --) shift; FILES+=("$@"); break ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) FILES+=("$1") ;;
    esac
    shift
  done

  ((${#FILES[@]} > 0)) || { usage >&2; exit 2; }
  local -a args=("${FILES[@]}")
  FILES=()

  if [[ $MODE == shift ]]; then
    ((OFFSET_MS != 0)) || die "no offset given: use --add=VALUE or --sub=VALUE"
    if ((UNTIL_MS >= 0 && FROM_MS >= UNTIL_MS)); then die "--from must be earlier than --until"; fi
  fi
  if [[ $MODE != history && -z ${HOME:-} && -z ${SRT_SHIFT_STATE:-} ]]; then
    die "HOME is not set; set SRT_SHIFT_STATE to a backup directory"
  fi
  for f in awk sed od tr cut head tail mktemp realpath sha256sum truncate install find sort cmp date; do
    command -v "$f" >/dev/null 2>&1 || die "missing command: $f"
  done

  collect_files "${args[@]}" || exit 2
  ((${#FILES[@]} > 0)) || { err "no .srt files found"; exit 2; }

  WORK=$(mktemp -d)
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  if [[ $MODE == shift ]]; then confirm_batch; fi

  for f in "${FILES[@]}"; do
    case $MODE in
      shift) if shift_file "$f"; then ok=$((ok + 1)); else failed=$((failed + 1)); fi ;;
      undo|undo-all) if undo_file "$f"; then ok=$((ok + 1)); else failed=$((failed + 1)); fi ;;
      history) history_file "$f" ;;
    esac
  done

  if [[ $MODE != history ]]; then
    log ""
    log "Done. OK: $ok, failed or nothing to do: $failed"
    ((failed == 0)) || exit 1
  fi
}

main "$@"
