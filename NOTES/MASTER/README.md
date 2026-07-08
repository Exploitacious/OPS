# NOTES/MASTER/ — the Obsidian vault

`NOTES/MASTER/` is the Obsidian vault slot. Point Obsidian at **this
directory** (`~/OPS/NOTES/MASTER/`) when you open the vault — its
`.obsidian/` config lives here, and `.gitignore` is tuned to track the
vault's markdown and a curated slice of its `.obsidian/` settings while
ignoring high-churn workspace state.

**`NOTES/` itself is never a vault target.** The parent `NOTES/`
directory is a container, not a vault: loose top-level files in it are
tracked as plain scratch notes, and its subdirectories are ignored so a
second vault could be dropped alongside `MASTER/` without cross-linking
into it. Opening `NOTES/` as a vault would pull those siblings into the
graph and put the `.obsidian/` config at the wrong level. Always open
`MASTER/` (or another explicit vault subdir), never `NOTES/`.

The vault is the home for personal notes, research, and durable
knowledge that isn't a project deliverable (those go in `DELIVERABLES/`)
and isn't a repo's own docs. On a multi-machine setup the vault content
typically syncs from whichever machine you do most of your writing on;
other machines just drop the occasional scratch note or README here.
