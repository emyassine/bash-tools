#!/usr/bin/env bash
# fetch-lyrics.sh - find and save lyrics for local audio/video files.
#
# Sources (in order):
#   1. LRCLIB (https://lrclib.net) - free public database, no API key, no account.
#      Best coverage for non-Latin scripts (Arabic, Japanese, ...) and provides
#      time-synced lyrics, which become real subtitles.
#   2. LyricsFreak website (plain text, estimated timing) - only when LRCLIB has
#      no confident match.
#
# Default mode is AUTO: every file is matched by artist/title tokens, media
# duration and embedded tags, and the best confident match is saved without
# asking. Use --ask to choose manually.
#
# Output, next to each media file (media files themselves are never modified):
#   VLC mode (--vlc, default when not asked):
#     <name>.srt         subtitle file (real timing if synced, else estimated)
#   Full mode (--full):
#     <name>.srt         subtitle file
#     <name>.lrc         synced lyrics (only if the source has timing)
#     <media>.lyrics.txt plain text with source header
#
# Dependencies: curl, jq, ffprobe (package ffmpeg). On Debian the script can
# install only the missing ones with apt-get (no update, no upgrade, no
# recommended packages). Nothing else on the system is touched.

set -Eeuo pipefail
export LC_ALL=C.UTF-8

LRCLIB='https://lrclib.net/api'
LF_BASE='https://www.lyricsfreak.com'
UA='fetch-lyrics.sh/2.0 (personal use) Mozilla/5.0 (X11; Linux x86_64)'

ASK=0
FORCE=0
MODE=''
INSTALL_DEPS=0
TMP=''
DUR=0
TAG_ARTIST=''
TAG_TITLE=''
QUERY=''
COMBOS='[]'
LR_N=0
LR_ERRORS=0
SAVED=0
SKIPPED=0
declare -a LR_FILES=()
declare -A LR_SEEN=()
declare -a NOT_FOUND=()

AWK_STAMP='function stamp(n,   h, m, s, ms) {
  h = int(n / 3600000); m = int((n % 3600000) / 60000)
  s = int((n % 60000) / 1000); ms = int(n % 1000)
  return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
}
'

read -r -d '' JQ_RANK <<'EOF' || true
def toks: ascii_downcase | [scan("[\\p{L}\\p{M}\\p{N}]+")] | unique;
def member($arr; $x): any($arr[]; . == $x);
def inter($a; $b): [$a[] | select(member($b; .))] | length;
def jac($a; $b):
  if ($a | length) == 0 or ($b | length) == 0 then 0
  else inter($a; $b) as $i | $i / (($a | length) + ($b | length) - $i) end;
def cont($a; $b):
  if ($a | length) == 0 then 0.5 else inter($a; $b) / ($a | length) end;

map(select(((.instrumental // false) | not)
           and (((.plainLyrics // "") != "") or ((.syncedLyrics // "") != ""))))
| map(. as $r
  | (($r.trackName // "") | toks) as $rt
  | (($r.artistName // "") | toks) as $ra
  | ([ $combos[]
       | (.t | toks) as $wt | (.a | toks) as $wa
       | {tt: jac($wt; $rt), aa: cont($wa; ($ra + $rt))} ]
     | max_by(.tt * 0.65 + .aa * 0.35)) as $m
  | (if $dur > 0 and ($r.duration != null)
     then (($r.duration - $dur) | fabs) else null end) as $dd
  | (if $dd == null then 0
     elif $dd <= 3 then 0.25
     elif $dd <= 8 then 0.1
     elif $dd > 25 then -0.25
     else 0 end) as $db
  | ($m.tt * 0.65 + $m.aa * 0.35 + $db) as $base
  | $r + {
      score: ($base + (if (($r.syncedLyrics // "") != "") then 0.08 else 0 end)),
      ok: ((($m.tt >= $min_ts) or ($m.tt >= 0.5 and $db >= 0.25))
           and ($m.aa >= 0.5 or $db >= 0.25) and $base >= 0.6)
    })
| sort_by((.ok | not), -.score)
EOF

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage: fetch-lyrics.sh [options] DIRECTORY

Finds lyrics for every audio/video file under DIRECTORY (recursive) and saves
them next to the media. Automatic by default. If neither --vlc nor --full is
given, you are asked once (non-interactive runs default to --vlc).

Options:
  -a, --ask            Interactive: list candidates and let you choose
      --vlc            Save only the .srt subtitle (what VLC and most players load)
      --full           Save .srt, .lrc (if synced) and .lyrics.txt
  -f, --force          Redo files that already have output (overwrites <name>.srt in VLC mode)
      --install-deps   Install missing dependencies with apt-get without asking
  -h, --help           Show this help
USAGE
}

cleanup() {
  local f
  [[ -n $TMP && -d $TMP ]] || return 0
  for f in "$TMP"/*; do
    [[ -e $f ]] || continue
    unlink -- "$f" 2>/dev/null || true
  done
  rmdir -- "$TMP" 2>/dev/null || true
}

# ---------------------------------------------------------------- dependencies
ensure_deps() {
  local tool pair cmd pkg ans
  local -a pkgs=() missing=() sudo_cmd=()

  for tool in awk sed find sort wc realpath mktemp unlink md5sum cut tr sleep; do
    command -v "$tool" >/dev/null 2>&1 || { err "Missing base command: $tool"; exit 1; }
  done

  for pair in curl:curl jq:jq ffprobe:ffmpeg; do
    cmd=${pair%%:*}; pkg=${pair##*:}
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd"); pkgs+=("$pkg")
    fi
  done
  ((${#missing[@]} > 0)) || return 0

  if ! command -v apt-get >/dev/null 2>&1; then
    err "Missing: ${missing[*]}. Install the packages (${pkgs[*]}) with your package manager."
    exit 1
  fi
  if ((EUID != 0)); then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd=(sudo)
    else
      err "Missing: ${missing[*]}. Run as root: apt-get install --no-install-recommends ${pkgs[*]}"
      exit 1
    fi
  fi

  log "Missing commands: ${missing[*]}"
  log "Will run: ${sudo_cmd[*]:-} apt-get install -y --no-install-recommends ${pkgs[*]}"
  log "(Only these packages are installed; no update, no upgrade.)"
  if ((!INSTALL_DEPS)); then
    if [[ -t 0 ]]; then
      printf 'Install now? [y/N] '
      IFS= read -r ans || ans=
      case ${ans,,} in y|yes) ;; *) err "Aborted."; exit 1 ;; esac
    else
      err "Not interactive. Re-run with --install-deps or install manually."
      exit 1
    fi
  fi
  if ! "${sudo_cmd[@]}" apt-get install -y --no-install-recommends "${pkgs[@]}"; then
    err "Installation failed. If package lists are stale, run: sudo apt-get update"
    exit 1
  fi
}

# ------------------------------------------------------------------ HTTP layer
# http_get URL OUTFILE [curl args...]; retries on 429/5xx/network errors and
# honours Retry-After. Returns 0 only for HTTP 200.
http_get() {
  local url=$1 out=$2 attempt code wait hdr="$TMP/headers.txt"
  shift 2
  for attempt in 1 2 3 4 5; do
    : > "$hdr"
    code=$(curl -sS -L --max-time 25 -A "$UA" -D "$hdr" -o "$out" \
      -w '%{http_code}' "$@" "$url" 2>/dev/null) || code=000
    case $code in
      200) return 0 ;;
      429|500|502|503|504|000)
        ((attempt < 5)) || break
        wait=$(awk 'tolower($1) == "retry-after:" { gsub(/\r/, "", $2); v = $2 } END { print v }' "$hdr")
        [[ $wait =~ ^[0-9]+$ ]] || wait=$((attempt * attempt * 3))
        ((wait <= 60)) || wait=60
        log "  HTTP $code from ${url%%\?*}, retrying in ${wait}s (attempt $attempt/5)"
        sleep "$wait"
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

hkey() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

# --------------------------------------------------------------- text cleaning
clean_title() {
  printf '%s' "$1" | tr '_' ' ' | sed -E \
    -e 's/[[:space:]]*(–|—|―)+[[:space:]]*/ - /g' \
    -e 's/[[:space:]]*(│|\||｜).*$//' \
    -e 's/\[[^]]*\]//g' \
    -e 's/\([^)]*\)//g' \
    -e 's/（[^）]*）//g' \
    -e 's/【[^】]*】//g' \
    -e 's/[[:space:]]+(official[[:space:]]+)?(music[[:space:]]+)?(video|audio|visuali[sz]er)[[:space:]]*$//I' \
    -e 's/[[:space:]]+(lyrics?|lyric[[:space:]]+video)[[:space:]]*$//I' \
    -e 's/[[:space:]]+(4K|HD|HQ|MV|1080p)[[:space:]]*$//I' \
    -e 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

strip_feat() {
  printf '%s' "$1" | sed -E 's/[[:space:]]+(feat\.?|ft\.?|featuring)[[:space:]].*$//I'
}

first_artist() {
  local a=$1
  a=${a%%,*}; a=${a%% & *}; a=${a%% x *}; a=${a%% X *}
  printf '%s' "$a" | sed -E 's/^ +| +$//g'
}

join_query() { printf '%s %s' "$1" "$2" | sed -E 's/^ +| +$//g'; }

html_to_text() {
  sed -E \
    -e 's/<br[[:space:]]*\/?>/\n/Ig' \
    -e 's/<\/p[[:space:]]*>/\n/Ig' \
    -e 's/<[^>]*>//g' \
    -e 's/&quot;/"/g' \
    -e 's/&#0*39;/\x27/g' \
    -e 's/&apos;/\x27/g' \
    -e 's/&#8217;/’/g' \
    -e 's/&#8216;/‘/g' \
    -e 's/&#8211;/–/g' \
    -e 's/&#8212;/—/g' \
    -e 's/&nbsp;/ /g' \
    -e 's/&#160;/ /g' \
    -e 's/&lt;/</g' \
    -e 's/&gt;/>/g' \
    -e 's/&amp;/\&/g' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d'
}

# ------------------------------------------------------------- media inspection
read_media_info() {
  local meta
  meta=$(ffprobe -v error -show_entries format=duration:format_tags=artist,title \
    -of json -i "$1" 2>/dev/null || true)
  [[ -n $meta ]] || meta='{}'
  DUR=$(jq -r '(((.format.duration // "0") | tonumber?) // 0)' <<<"$meta" 2>/dev/null || printf '0')
  [[ $DUR =~ ^[0-9]+([.][0-9]+)?$ ]] || DUR=0
  TAG_ARTIST=$(jq -r '((.format.tags // {}) | with_entries(.key |= ascii_downcase) | .artist // "")' <<<"$meta" 2>/dev/null || true)
  TAG_TITLE=$(jq -r '((.format.tags // {}) | with_entries(.key |= ascii_downcase) | .title // "")' <<<"$meta" 2>/dev/null || true)
}

# Prints a JSON array of {a: artist, t: title} guesses derived from the file
# name (both orders, because "Title - Artist" is common) and embedded tags.
build_combos() {
  local q=$1 a t
  {
    if [[ $q == *' - '* ]]; then
      a=${q%% - *}
      t=$(strip_feat "${q#* - }")
      printf '%s\t%s\n%s\t%s\n' "$a" "$t" "$t" "$a"
    else
      printf '\t%s\n' "$(strip_feat "$q")"
    fi
    if [[ -n $TAG_TITLE ]]; then
      printf '%s\t%s\n' "$TAG_ARTIST" "$(clean_title "$TAG_TITLE")"
    fi
  } | awk -F'\t' 'NF >= 2 && $2 != "" && !seen[$0]++' \
    | jq -Rn '[inputs | split("\t") | {a: .[0], t: .[1]}]'
}

# ---------------------------------------------------------------------- LRCLIB
lr_query() {
  local param=$1 key f
  key=$(hkey "$param")
  [[ -z ${LR_SEEN[$key]+x} ]] || return 0
  LR_SEEN[$key]=1
  LR_N=$((LR_N + 1))
  f="$TMP/lr-$LR_N.json"
  if http_get "$LRCLIB/search" "$f" --get --data-urlencode "$param" \
      && jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    LR_FILES+=("$f")
  else
    LR_ERRORS=$((LR_ERRORS + 1))
  fi
  sleep 0.2
}

lrclib_candidates() {
  local out=$1 a t fa
  LR_FILES=(); LR_SEEN=(); LR_N=0; LR_ERRORS=0
  while IFS=$'\x1f' read -r a t; do
    [[ -n $t ]] || continue
    fa=$(first_artist "$a")
    lr_query "track_name=$t"
    if [[ -n $fa ]]; then lr_query "q=$fa $t"; fi
  done < <(jq -r '.[] | [.a, .t] | join("\u001f")' <<<"$COMBOS")
  lr_query "q=$QUERY"
  if ((${#LR_FILES[@]} > 0)); then
    jq -s 'add | unique_by(.id)
           | map(. + {source: ("https://lrclib.net/api/get/" + (.id | tostring))})' \
      "${LR_FILES[@]}" > "$out"
  else
    printf '[]' > "$out"
  fi
}

# ------------------------------------------------------------------ LyricsFreak
lf_song_paths() {
  awk '
    /<a[[:space:]]*$/ { tag = $0; on = 1; next }
    on {
      tag = tag " " $0
      if (/>/) {
        if (tag ~ /class="song"/ && match(tag, /href="[^"]+"/))
          print substr(tag, RSTART + 6, RLENGTH - 7)
        on = 0
      }
    }
  ' "$1" | awk '!seen[$0]++' | head -4
}

lf_extract_lyrics() {
  awk '
    !inside && /<div id="content" class="lyrictxt/ {
      inside = 1
      sub(/^.*<div id="content" class="lyrictxt[^>]*>/, "")
    }
    inside {
      if (index($0, "</div>")) { sub(/<\/div>.*/, ""); print; exit }
      print
    }
  ' "$1" | html_to_text
}

lf_candidates() {
  local out=$1 list="$TMP/lf-list.ndjson" q key a t url path title song artist n=0
  local -a queries=() all_paths=() paths=()
  local -A seen_q=() seen_p=()
  : > "$list"
  queries+=("$QUERY")
  while IFS=$'\x1f' read -r a t; do
    [[ -n $t ]] || continue
    queries+=("$(join_query "$(first_artist "$a")" "$t")")
  done < <(jq -r '.[] | [.a, .t] | join("\u001f")' <<<"$COMBOS")

  for q in "${queries[@]}"; do
    key=$(hkey "$q")
    [[ -z ${seen_q[$key]+x} ]] || continue
    seen_q[$key]=1
    if http_get "$LF_BASE/search.php" "$TMP/lf-search.html" --get \
        --data-urlencode 'a=search' --data-urlencode 'type=song' --data-urlencode "q=$q"; then
      mapfile -t paths < <(lf_song_paths "$TMP/lf-search.html")
      for path in "${paths[@]}"; do
        [[ -n $path && -z ${seen_p[$path]+x} ]] || continue
        seen_p[$path]=1
        all_paths+=("$path")
      done
    fi
    sleep 1
    if ((${#all_paths[@]} >= 6)); then break; fi
  done

  for path in "${all_paths[@]}"; do
    url="$LF_BASE$path"
    n=$((n + 1))
    if ! http_get "$url" "$TMP/lf-page-$n.html"; then continue; fi
    sleep 1
    lf_extract_lyrics "$TMP/lf-page-$n.html" > "$TMP/lf-lyrics-$n.txt" || true
    [[ -s $TMP/lf-lyrics-$n.txt ]] || continue
    (($(wc -c < "$TMP/lf-lyrics-$n.txt") >= 100)) || continue
    title=$(sed -nE 's/^[[:space:]]*<title>(.*)<\/title>.*/\1/p' "$TMP/lf-page-$n.html" | head -1 | html_to_text || true)
    title=$(printf '%s' "$title" | sed -E 's/[[:space:]]*lyrics[[:space:]]*\|.*$//I')
    if [[ $title == *' - '* ]]; then
      song=${title% - *}; artist=${title##* - }
    else
      song=$title; artist=''
    fi
    jq -n --arg id "$url" --arg t "$song" --arg a "$artist" \
      --rawfile l "$TMP/lf-lyrics-$n.txt" \
      '{id: $id, trackName: $t, artistName: $a, duration: null,
        plainLyrics: $l, syncedLyrics: null, source: $id}' >> "$list"
  done
  jq -s '.' "$list" > "$out"
}

# --------------------------------------------------------------------- ranking
rank_candidates() { # min_title_similarity input.json output.json
  jq --argjson combos "$COMBOS" --argjson dur "$DUR" --argjson min_ts "$1" \
    "$JQ_RANK" "$2" > "$3"
}

choose_candidate() { # ranked.json -> $TMP/chosen.json
  local ranked=$1 count top_ok choice
  count=$(jq 'length' "$ranked")
  ((count > 0)) || return 1
  top_ok=$(jq '.[0].ok' "$ranked")

  if ((!ASK)); then
    [[ $top_ok == true ]] || return 1
    jq '.[0]' "$ranked" > "$TMP/chosen.json"
    return 0
  fi

  log "Candidates:"
  jq -r 'to_entries | .[:8][]
    | "  \(.key + 1)) \(.value.artistName // "?") - \(.value.trackName) [\(.value.duration // "?")s, \(if (.value.syncedLyrics // "") != "" then "synced" else "plain" end), score \(((.value.score * 100) | floor) / 100)\(if .value.ok then "" else ", weak" end)]"' "$ranked"
  if [[ $top_ok == true ]]; then
    printf 'Choice [Enter = 1, 0 = skip]: '
  else
    printf 'Choice [Enter = skip]: '
  fi
  IFS= read -r choice || choice=
  if [[ -z $choice ]]; then
    if [[ $top_ok == true ]]; then choice=1; else choice=0; fi
  fi
  [[ $choice =~ ^[0-9]+$ ]] || return 1
  ((choice >= 1 && choice <= count && choice <= 8)) || return 1
  jq --argjson i "$((choice - 1))" '.[$i]' "$ranked" > "$TMP/chosen.json"
}

# --------------------------------------------------------------- subtitle build
lrc_to_srt() { # lrc_file total_ms
  awk -v total="$2" "$AWK_STAMP"'
  {
    line = $0; sub(/\r$/, "", line); k = 0
    while (match(line, /^\[[0-9]+:[0-9]+([.:][0-9]+)?\]/)) {
      tag = substr(line, 2, RLENGTH - 2); line = substr(line, RLENGTH + 1)
      np = split(tag, p, /[:.]/)
      frac = 0
      if (np >= 3) {
        f = p[3]; frac = f + 0
        if (length(f) == 1) frac = frac * 100
        else if (length(f) == 2) frac = frac * 10
        else if (length(f) > 3) frac = substr(f, 1, 3) + 0
      }
      k++; ts[k] = (p[1] * 60 + p[2]) * 1000 + frac
    }
    if (k == 0) next
    gsub(/<[0-9:.]+>/, "", line)
    sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
    for (i = 1; i <= k; i++) { c++; st[c] = ts[i]; tx[c] = line }
  }
  END {
    for (i = 2; i <= c; i++) {
      s = st[i]; t = tx[i]; j = i - 1
      while (j >= 1 && st[j] > s) { st[j + 1] = st[j]; tx[j + 1] = tx[j]; j-- }
      st[j + 1] = s; tx[j + 1] = t
    }
    out = 0
    for (i = 1; i <= c; i++) {
      if (tx[i] == "") continue
      en = (i < c) ? st[i + 1] : st[i] + 5000
      if (en - st[i] > 10000) en = st[i] + 10000
      if (i == c && total + 0 > st[i] + 1000 && total + 0 < en) en = total + 0
      if (en <= st[i]) en = st[i] + 1000
      out++
      printf "%d\n%s --> %s\n%s\n\n", out, stamp(st[i]), stamp(en), tx[i]
    }
  }' "$1"
}

plain_to_srt() { # plain_file total_ms ; timing is proportional to line length
  awk -v total="$2" "$AWK_STAMP"'
  {
    sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
    if ($0 == "") next
    n++; l[n] = $0; w[n] = length($0) + 8; sum += w[n]
  }
  END {
    pos = 0
    for (i = 1; i <= n; i++) {
      s = int(pos * total / sum); pos += w[i]; e = int(pos * total / sum)
      printf "%d\n%s --> %s\n%s\n\n", i, stamp(s), stamp(e), l[i]
    }
  }' "$1"
}

# Sidecar path: never overwrite a foreign file with the same name.
sidecar_path() { # base ext txt_marker
  local p="$1.$2"
  if [[ -e $p && ! -e $3 ]]; then p="$1.lyrics.$2"; fi
  printf '%s' "$p"
}

save_result() { # media
  local media=$1 base txt srt lrc total_ms timing matched source
  base=${media%.*}
  txt="${media}.lyrics.txt"
  if [[ $MODE == vlc ]]; then
    srt="$base.srt"
  else
    srt=$(sidecar_path "$base" srt "$txt")
    lrc=$(sidecar_path "$base" lrc "$txt")
  fi

  jq -r '.syncedLyrics // empty' "$TMP/chosen.json" | tr -d '\r' > "$TMP/synced.lrc"
  jq -r '.plainLyrics // empty' "$TMP/chosen.json" | tr -d '\r' > "$TMP/plain.txt"
  if [[ ! -s $TMP/plain.txt && -s $TMP/synced.lrc ]]; then
    sed -E -e 's/^(\[[^]]*\])+[[:space:]]?//' -e 's/<[0-9:.]+>//g' "$TMP/synced.lrc" | cat -s > "$TMP/plain.txt"
  fi
  [[ -s $TMP/plain.txt ]] || { log "  Chosen entry has no lyrics text."; return 1; }

  total_ms=$(awk -v d="$DUR" 'BEGIN { printf "%d", d * 1000 }')
  ((total_ms > 0)) || total_ms=180000

  timing=estimated
  : > "$TMP/out.srt"
  if [[ -s $TMP/synced.lrc ]]; then
    lrc_to_srt "$TMP/synced.lrc" "$total_ms" > "$TMP/out.srt" || true
    if [[ -s $TMP/out.srt ]]; then timing=synced; fi
  fi
  if [[ $timing == estimated ]]; then
    plain_to_srt "$TMP/plain.txt" "$total_ms" > "$TMP/out.srt"
  fi

  mv -f -- "$TMP/out.srt" "$srt"
  log "  Subtitle: $srt ($timing timing)"
  if [[ $MODE == full ]]; then
    matched=$(jq -r '"\(.artistName // "?") - \(.trackName // "?")"' "$TMP/chosen.json")
    source=$(jq -r '.source // ""' "$TMP/chosen.json")
    {
      printf 'Source: %s\nMatched: %s\nTiming: %s\n\n' "$source" "$matched" "$timing"
      cat "$TMP/plain.txt"
    } > "$TMP/out.txt"
    mv -f -- "$TMP/out.txt" "$txt"
    log "  Lyrics text: $txt"
    if [[ $timing == synced ]]; then
      mv -f -- "$TMP/synced.lrc" "$lrc"
      log "  Synced lyrics: $lrc"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------- driver
process_file() { # media index total
  local media=$1 idx=$2 total=$3 filename stem txt
  filename=${media##*/}
  stem=${filename%.*}
  txt="${media}.lyrics.txt"

  if ((!FORCE)) && { [[ $MODE == full && -e $txt ]] || [[ $MODE == vlc && -e ${media%.*}.srt ]]; }; then
    log "[$idx/$total] Skip (already done): $filename"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  log ""
  log "[$idx/$total] $filename"
  QUERY=$(clean_title "$stem")
  [[ -n $QUERY ]] || QUERY=$stem
  read_media_info "$media"
  COMBOS=$(build_combos "$QUERY")
  log "  Query: $QUERY (duration ${DUR}s)"

  lrclib_candidates "$TMP/lr-all.json"
  rank_candidates 0.7 "$TMP/lr-all.json" "$TMP/ranked-lr.json"

  printf '[]' > "$TMP/ranked-lf.json"
  if [[ $(jq '[.[] | select(.ok)] | length' "$TMP/ranked-lr.json") -eq 0 ]]; then
    log "  No confident LRCLIB match, trying LyricsFreak..."
    lf_candidates "$TMP/lf-all.json"
    rank_candidates 0.8 "$TMP/lf-all.json" "$TMP/ranked-lf.json"
  fi
  jq -s 'add | sort_by((.ok | not), -.score)' "$TMP/ranked-lr.json" "$TMP/ranked-lf.json" > "$TMP/ranked.json"

  if choose_candidate "$TMP/ranked.json"; then
    log "  Match: $(jq -r '"\(.artistName // "?") - \(.trackName) (score \(((.score * 100) | floor) / 100))"' "$TMP/chosen.json")"
    if save_result "$media"; then
      SAVED=$((SAVED + 1))
      return 0
    fi
  fi

  if [[ $(jq 'length' "$TMP/ranked.json") -eq 0 && $LR_ERRORS -gt 0 && ${#LR_FILES[@]} -eq 0 ]]; then
    log "  Search failed (network problem or site block)."
  elif ((ASK)); then
    log "  Skipped."
  else
    log "  No confident match. Run with --ask to pick manually."
  fi
  NOT_FOUND+=("$filename")
  return 0
}

main() {
  local dir='' root media i=0 total ans
  local -a MEDIA=()

  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      -a|--ask) ASK=1 ;;
      -f|--force) FORCE=1 ;;
      --install-deps) INSTALL_DEPS=1 ;;
      --vlc) MODE=vlc ;;
      --full) MODE=full ;;
      -*) err "Unknown option: $1"; usage >&2; exit 2 ;;
      *) if [[ -n $dir ]]; then usage >&2; exit 2; fi; dir=$1 ;;
    esac
    shift
  done
  if [[ -z $dir || ! -d $dir ]]; then usage >&2; exit 2; fi

  if [[ -z $MODE ]]; then
    if [[ -t 0 ]]; then
      printf 'Is this for VLC? Save only the .srt subtitle next to each file? [Y/n] '
      IFS= read -r ans || ans=
      case ${ans,,} in n|no) MODE=full ;; *) MODE=vlc ;; esac
    else
      MODE=vlc
    fi
  fi

  ensure_deps
  root=$(realpath -- "$dir")
  TMP=$(mktemp -d)
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  mapfile -d '' MEDIA < <(find "$root" -type f \( \
    -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.ogg' -o -iname '*.opus' -o \
    -iname '*.flac' -o -iname '*.wav' -o -iname '*.wma' -o -iname '*.mp4' -o -iname '*.m4v' -o \
    -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.avi' \
    \) ! -name '*.part' ! -name '*.ytdl' -print0 | sort -z)
  total=${#MEDIA[@]}
  if ((total == 0)); then log "No audio/video files found in $root"; exit 0; fi
  if ((ASK)); then
    log "$total media files. Interactive mode (LRCLIB, then LyricsFreak)."
  else
    log "$total media files. Automatic mode (LRCLIB, then LyricsFreak)."
  fi

  for media in "${MEDIA[@]}"; do
    i=$((i + 1))
    process_file "$media" "$i" "$total"
  done

  log ""
  log "Done. Saved: $SAVED, skipped: $SKIPPED, not found: ${#NOT_FOUND[@]}"
  if ((${#NOT_FOUND[@]} > 0)); then
    log "Not found:"
    for media in "${NOT_FOUND[@]}"; do log "  - $media"; done
    log "Retry those with --ask to review weak candidates."
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
