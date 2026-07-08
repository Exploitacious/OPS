# ARCHIVE/

Holding pen for **machine-local project archives** — the compressed
tarballs written by `WORKFORCE/bin/ac-close-project --archive` when a
fleet project is wound down (Phase G of the close-out). Each archive
captures a retired project's fleet runtime (manifest, tasks, decisions,
closeout note) so it can be pulled back for reference without keeping
the live `WORKFORCE/FLEETPROJECTS/<slug>/` directory around. The
contents are a per-machine audit trail, so this folder is gitignored
(`ARCHIVE/` in `.gitignore`) — the tarballs stay on the machine that
produced them and are not synced across the fleet. This README is the
only tracked file here.
