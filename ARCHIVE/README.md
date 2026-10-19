# ARCHIVE/

Holding pen for **machine-local archives** you want to keep on this machine
but out of git: a tarball of a closed project's working tree, an exported
transcript, a snapshot taken before a risky migration. The contents are
gitignored (`ARCHIVE/*` in `.gitignore`, with this README the only tracked
file), so nothing here syncs to your other machines, and `harness-update`
never touches the folder.

Nothing in the harness writes here on its own any more: the retired
multi-agent fleet's close-out tool did, and it is gone. If you never use the
folder, it costs nothing.
