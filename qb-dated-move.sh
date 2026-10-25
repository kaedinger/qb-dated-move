#!/bin/bash
#
# qb-dated-move.sh
#
# Moves completed torrents that sit directly in one of FINAL_DIRS into a
# dated subfolder (YYYYMMDD, by completion date) via the qBittorrent WebUI API.
# If any top-level file/folder of the torrent already exists in that subfolder
# (on disk, claimed by another torrent in qB, or claimed earlier in this run),
# it tries YYYYMMDD_1, YYYYMMDD_2, ... until there is no clash.
#
# Intended to run inside the binhex-qbittorrentvpn container, e.g. via
# "Run external program on torrent finished":
#     /bin/bash /config/scripts/qb-dated-move.sh
#
# Test with: DRY_RUN=1 ./qb-dated-move.sh   (default is a real run)

set -u

# ---------------------------------------------------------------- config ---

QB_URL="http://localhost:8080"     # from inside the container
QB_USER="admin"
QB_PASS="changeme"

# Paths exactly as qBittorrent shows them (container paths!), no trailing slash
FINAL_DIRS=(
    "/data/a"
    "/data/b"
)

DRY_RUN="${DRY_RUN:-0}"            # 1 = only log what would happen (override per run: DRY_RUN=1 ...)

# Only move torrents completed more than this many months ago.
# Empty = move all. Can be overridden per run: MIN_AGE_MONTHS=6 ./qb-dated-move.sh
MIN_AGE_MONTHS="${MIN_AGE_MONTHS:-}"
TZ_NAME="Europe/Berlin"            # timezone for the date folder
MOVE_TIMEOUT=1800                  # seconds to wait for qB to finish moves
LOG_FILE="/config/scripts/qb-dated-move.log"
LOCK_FILE="/tmp/qb-dated-move.lock"

# ----------------------------------------------------------------- setup ---

# Files created by root (docker exec) stay writable for qB's user and vice versa
umask 0000

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

for bin in curl jq flock; do
    command -v "$bin" >/dev/null 2>&1 || { log "ERROR: '$bin' not found"; exit 1; }
done

[[ -e "/usr/share/zoneinfo/$TZ_NAME" ]] || \
    log "WARN: zoneinfo for $TZ_NAME not found, dates may be UTC"

# Only one instance at a time; a second trigger waits for the first to finish
exec 9>>"$LOCK_FILE"
flock -w "$MOVE_TIMEOUT" 9 || { log "ERROR: could not acquire lock"; exit 1; }

COOKIE_JAR="$(mktemp)"

api() {  # api <path> [curl args...]
    local path="$1"; shift
    curl -sS --fail --connect-timeout 10 --max-time 60 \
         -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
         -H "Referer: $QB_URL" "$@" "$QB_URL/api/v2/$path"
}

cleanup() {
    api auth/logout -X POST >/dev/null 2>&1
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

CUTOFF=0
if [[ -n "$MIN_AGE_MONTHS" ]]; then
    [[ "$MIN_AGE_MONTHS" =~ ^[0-9]+$ ]] || { log "ERROR: MIN_AGE_MONTHS must be a whole number"; exit 1; }
    CUTOFF=$(TZ="$TZ_NAME" date -d "-$MIN_AGE_MONTHS months" +%s)
fi

if (( CUTOFF > 0 )); then
    age_info="completed before $(TZ="$TZ_NAME" date -d "@$CUTOFF" '+%F %T')"
else
    age_info="all ages"
fi
log "Start (DRY_RUN=$DRY_RUN, $age_info), logging in to $QB_URL"
resp=$(curl -sS --connect-timeout 10 --max-time 30 \
            -c "$COOKIE_JAR" -H "Referer: $QB_URL" \
            -w '\n%{http_code}' \
            --data-urlencode "username=$QB_USER" \
            --data-urlencode "password=$QB_PASS" \
            "$QB_URL/api/v2/auth/login") || { log "ERROR: login request failed"; exit 1; }
login_code="${resp##*$'\n'}"
login_body="${resp%$'\n'*}"

# Don't rely on the response body; verify the session with a real API call
if ! version=$(api app/version); then
    log "ERROR: login failed (HTTP $login_code, body: '${login_body}')"
    exit 1
fi
log "Logged in (HTTP $login_code), qBittorrent $version"

# --------------------------------------------------------------- helpers ---

is_final_dir() {
    local p="${1%/}" d
    for d in "${FINAL_DIRS[@]}"; do [[ "$p" == "${d%/}" ]] && return 0; done
    return 1
}

# Unique top-level entries (first path component) of a torrent's files
top_entries() {
    api torrents/files -G --data-urlencode "hash=$1" \
        | jq -r '.[].name | split("/")[0]' | sort -u
}

declare -A QB_OCCUPIED   # "<dir>/<name>" claimed by any torrent in qB
declare -A CLAIMED       # "<dir>/<name>" claimed by a move in this run
declare -A EXPECTED      # hash -> target dir of moves started in this run

occupied() {  # occupied <dir> <name>
    local key="$1/$2"
    [[ -e "$key" || -L "$key" ]]       && return 0
    [[ -n "${CLAIMED[$key]+x}" ]]      && return 0
    [[ -n "${QB_OCCUPIED[$key]+x}" ]]  && return 0
    return 1
}

pick_target() {  # pick_target <base_dir> <yyyymmdd> <name>...
    local base="$1" day="$2"; shift 2
    local n=0 cand name clash
    while (( n < 1000 )); do
        if (( n == 0 )); then cand="$base/$day"; else cand="$base/${day}_$n"; fi
        clash=0
        for name in "$@"; do
            if occupied "$cand" "$name"; then clash=1; break; fi
        done
        (( clash == 0 )) && { printf '%s' "$cand"; return 0; }
        n=$((n + 1))
    done
    return 1
}

wait_for_moves() {
    # Plain counter instead of ${#EXPECTED[@]}: older bash versions treat an
    # empty associative array as unbound under 'set -u'
    (( moves_started > 0 )) || return 0
    local hashes waited=0 pending
    hashes=$(IFS='|'; echo "${!EXPECTED[*]}")
    sleep 2
    while (( waited < MOVE_TIMEOUT )); do
        pending=0
        while IFS=$'\t' read -r h st sp; do
            [[ "$st" == "moving" || "${sp%/}" != "${EXPECTED[$h]}" ]] && pending=$((pending + 1))
        done < <(api torrents/info -G --data-urlencode "hashes=$hashes" \
                    | jq -r '.[] | [.hash, .state, .save_path] | @tsv')
        (( pending == 0 )) && { log "All moves finished"; return 0; }
        sleep 5; waited=$((waited + 5))
    done
    log "WARN: $pending move(s) still unfinished after ${MOVE_TIMEOUT}s"
}

# ------------------------------------------------------------------ main ---

torrents=$(api torrents/info) || { log "ERROR: could not fetch torrent list"; exit 1; }
log "qB reports $(jq length <<<"$torrents") torrents; final dirs: ${FINAL_DIRS[*]}"
candidates=0
skipped=0
moves_started=0

# Everything qB already has in some folder counts as occupied
while IFS=$'\t' read -r sp cp; do
    sp="${sp%/}"; cp="${cp%/}"
    [[ "$cp" != "$sp" && "$cp" == "$sp/"* ]] && QB_OCCUPIED["$sp/${cp#"$sp/"}"]=1
done < <(jq -r '.[] | [.save_path, .content_path] | @tsv' <<<"$torrents")

while IFS=$'\t' read -r hash state save_path completion_on name; do
    save_path="${save_path%/}"
    is_final_dir "$save_path" || continue
    [[ "$state" == "moving" ]] && continue
    candidates=$((candidates + 1))

    if (( CUTOFF > 0 )); then
        if (( completion_on <= 0 )); then
            log "SKIP: '$name' has no completion date (age filter active)"
            skipped=$((skipped + 1)); continue
        fi
        (( completion_on < CUTOFF )) || { skipped=$((skipped + 1)); continue; }
    fi

    if (( completion_on > 0 )); then
        day=$(TZ="$TZ_NAME" date -d "@$completion_on" +%Y%m%d)
    else
        day=$(TZ="$TZ_NAME" date +%Y%m%d)
        log "WARN: no completion date for '$name', using today"
    fi

    mapfile -t tops < <(top_entries "$hash")
    if (( ${#tops[@]} == 0 )); then
        log "WARN: no file list for '$name' ($hash), skipping"
        continue
    fi

    if ! target=$(pick_target "$save_path" "$day" "${tops[@]}"); then
        log "ERROR: no free target folder for '$name', skipping"
        continue
    fi

    for t in "${tops[@]}"; do CLAIMED["$target/$t"]=1; done

    if (( DRY_RUN )); then
        log "DRY-RUN: '$name' -> $target"
        continue
    fi

    if api torrents/setLocation --data-urlencode "hashes=$hash" \
                                --data-urlencode "location=$target" >/dev/null; then
        log "Moving '$name' -> $target"
        EXPECTED["$hash"]="$target"
        moves_started=$((moves_started + 1))
    else
        log "ERROR: setLocation failed for '$name' -> $target"
    fi
done < <(jq -r '.[] | select(.progress == 1)
                | [.hash, .state, .save_path, (.completion_on | tostring), .name]
                | @tsv' <<<"$torrents")

log "$candidates torrent(s) found in final dirs, $skipped skipped by age filter"

# Hold the lock until qB has finished moving, so the next run sees the result
wait_for_moves
log "Done"
