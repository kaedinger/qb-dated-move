# qb-dated-move

Prevents qBittorrent's "Set location" from silently overwriting files of an
older torrent with a same-named newer one.

Completed torrents whose save path is **exactly** one of `FINAL_DIRS` are moved
via the WebUI API into a dated subfolder based on their completion date:

    /data/a/linux.iso  ->  /data/a/20261015/linux.iso

If any top-level file/folder of the torrent already exists in the target
(on disk, claimed by another torrent in qB, or claimed earlier in the same
run), the script tries `20261015_1`, `20261015_2`, ... instead.

Torrents in subfolders of a final dir are left alone, unless that subfolder is
listed as a final dir itself.

## Requirements

- qBittorrent with WebUI (tested: 5.2.4 in `binhex-qbittorrentvpn` on Unraid)
- `bash`, `curl`, `jq`, `flock` where the script runs (all present in the
  binhex image)

## Setup

1. Put `qb-dated-move.sh` into the container, e.g. `/config/scripts/`.
2. Copy `qb-dated-move.conf.example` to `qb-dated-move.conf` next to it, fill
   in `QB_USER`, `QB_PASS`, `FINAL_DIRS` (container paths as qB shows them, no
   trailing slash) and `chmod 600` it. It must be readable by the user qB runs
   as. A different location can be set via `CONF_FILE`.
3. qBittorrent: Tools → Options → Downloads → Run external program →
   **Run on torrent finished**:

       /bin/bash /config/scripts/qb-dated-move.sh

   qB doesn't run this through a shell, so env-var prefixes don't work there.

## Options (env vars, per run)

| Variable         | Default  | Meaning                                                      |
|------------------|----------|--------------------------------------------------------------|
| `DRY_RUN`        | `0`      | `1` = only log what would happen                             |
| `MIN_AGE_MONTHS` | empty    | only move torrents completed more than N months ago; empty = all |

Example manual run inside the container:

    DRY_RUN=1 MIN_AGE_MONTHS=12 /config/scripts/qb-dated-move.sh

## Behaviour notes

- Log: `/config/scripts/qb-dated-move.log`, trimmed automatically.
- At the end of each run, dated folders (`YYYYMMDD`, `YYYYMMDD_N`) directly in
  a final dir that contain no files anymore are removed, unless qB still
  uses them as a save path.
- Runs are serialised by a lock; each run holds it until qB has finished its
  moves (max `MOVE_TIMEOUT`, 1800 s).
- A torrent moved into a final dir by hand stays there until the next finished
  download triggers the script. Two same-named torrents moved into the same
  final dir in that window will still overwrite.
- Torrents with Automatic Torrent Management enabled are untested.
- Before big runs, back up `/config/qBittorrent/BT_backup` (resume data).

## Testing the clash handling

    mkdir -p /data/a/20261015 && touch /data/a/20261015/linux.iso
    DRY_RUN=1 /config/scripts/qb-dated-move.sh   # expect -> 20261015_1
    # remove the placeholder afterwards

## License

GPL-3.0, see [LICENSE](LICENSE).
