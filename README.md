# qb-dated-move

Prevents qBittorrent's "Set location" from silently overwriting files of an
older torrent with a same-named newer one.

Completed torrents whose save path is **exactly** one of `FINAL_DIRS` are moved
via the WebUI API into a dated subfolder based on their completion date:

    /data/a/linux.iso  ->  /data/a/20261015/linux.iso

If any top-level file/folder of the torrent already exists in the target
(on disk, claimed by another torrent in qB, or claimed earlier in the same
run), the script tries `20261015_1`, `20261015_2`, ... instead.

Torrents in subfolders (e.g. `/data/toast/test` when only `/data/toast` is
listed) are left alone. Subfolders can be listed as final dirs themselves;
nesting works fine.

## Environment

- Unraid, container `binhex-qbittorrentvpn`, qBittorrent 5.2.4
- Script lives in the container at `/config/scripts/qb-dated-move.sh`
  (host: `/mnt/user/appdata/binhex-qbittorrentvpn/scripts/`)
- WebUI reached from inside the container via `http://localhost:8080`
- Needs `curl`, `jq`, `flock` (all present in the image)

## Setup

1. Fill in the config block: `QB_USER`, `QB_PASS`, `FINAL_DIRS`
   (container paths as qB shows them, no trailing slash).
   This copy has placeholder credentials and paths.
2. qBittorrent: Tools → Options → Downloads → Run external program →
   **Run on torrent finished**:

       /bin/bash /config/scripts/qb-dated-move.sh

   qB doesn't run this through a shell, so env-var prefixes don't work there;
   the defaults in the file apply.

## Options (env vars, per run)

| Variable         | Default  | Meaning                                                      |
|------------------|----------|--------------------------------------------------------------|
| `DRY_RUN`        | `0`      | `1` = only log what would happen                             |
| `MIN_AGE_MONTHS` | empty    | only move torrents completed more than N months ago; empty = all |

Example manual run inside the container:

    DRY_RUN=1 MIN_AGE_MONTHS=12 /config/scripts/qb-dated-move.sh

## Behaviour notes

- Log: `/config/scripts/qb-dated-move.log` (~5 lines per run + 1 per move).
- A lock (`/tmp/qb-dated-move.lock`) serialises runs; each run waits until qB
  has finished its moves (max `MOVE_TIMEOUT`, 1800 s) before releasing it.
- Accepted race: a torrent moved into a final dir by hand stays there until
  the next finished download triggers the script. Two same-named torrents
  moved into the same final dir in that window will still overwrite.
- Torrents with Automatic Torrent Management enabled weren't tested (not used).
- Before big runs: back up `/config/qBittorrent/BT_backup` (resume data).

## Testing the clash handling

    mkdir -p /data/a/20261015 && touch /data/a/20261015/linux.iso
    DRY_RUN=1 /config/scripts/qb-dated-move.sh   # expect -> 20261015_1
    # remove the placeholder afterwards

## Optional: cap the log size

Insert after the `log()` definition:

    if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 5000 )); then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi

## Fixes made during development

- Login check no longer relies on qB returning `Ok.` (5.2.4 returned an empty
  body); the session is verified with `app/version` instead.
- Empty associative array tripped `set -u` in the container's bash; replaced
  the `${#EXPECTED[@]}` check with a plain counter.
- curl got connect/total timeouts so a blocked connection can't hang a run.
