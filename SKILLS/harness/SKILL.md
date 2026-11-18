---
name: harness
description: "Must always apply when working in a T3 Code thread on an OPS harness box. Facts about the box and T3 that an agent cannot work out: how a thread pauses, moves and closes, how to reach the owner and get a file to them, how waiting and helper agents behave, and the commands the box provides."
---

# Harness

Facts about the box you are running on. The machinery (hooks, scripts, T3's own tools) does the work; this page says what exists and what bites. The harness root is `~/OPS` (or `$OPS_DIR`); commands below live in `<root>/.claude-config/bin/`.

## What survives

A conversation is lost at a compact or a close. Three things are not: git, the memory pool for this directory (the session-start digest prints it), and the resume note. Anything worth keeping goes into one of them before either happens.

## Ending a thread

Three endings. Pause: the same thread continues after a compact. Move: the work continues in another thread, profile or machine. Close: the purpose is done.

- Every ending starts with `session-end <pause|move|close>`. It snapshots git, starts the merged-branch and worktree cleanup (`branch-gc`) for this repo (add `--repo PATH` for each other repo the thread changed; it prints the candidates), rebuilds the memory index, lints when the thread touched harness files, and prints this thread's open asks and what is left for you to decide. Fix the lint findings on files this thread changed and name the rest as other work's.
- It never commits, pushes, logs time, edits a ticket, writes a baton, compacts, settles or deletes scratch. Those stay yours.
- What only you can do, every time:
  - Save to the memory pool only a trap with no other home, one fact per file; a ruling, a repo fact or a client fact goes to its home instead. A session with none saves none.
  - Leave the memory pool better than you found it: correct an entry this thread proved wrong, merge duplicates you touched, move a lesson that belongs in a repo's docs. The closing thread owns this; nothing else tidies the pool (`verify-ops.sh` only warns when one outgrows its budget).
  - Put knowledge where the next person will look. A client or technical fact goes to its page in the documentation system, a repo fact to that repo's docs, a decision to the changelog. Fix any document this thread made untrue.
  - Write the resume note at the top of the anchor or baton: NEXT ACTION (one step), VERIFY FIRST, DO NOT (with who said so), DEAD ENDS, ASK THE OWNER.
- Then run `session-end finish`. After a close it needs `--logged N` (time entries created and read back; 0 when entries already on the ticket cover the work) or `--declined REASON`. Skip it and the closeout stamp never moves, so the next ending redoes this one's work.
- Pause: `session-end pause` prints the compact line. On T3, with the box's harness token, the thread compacts itself (`compact-cycle.sh`); without the token the cycle stops with `ERR_T3API` before it sends anything, and the owner fires `/compact`. Never compact over an unanswered question.
- Move: the baton is `<root>/.claude-handoffs/pending/<key>.md`, key from `key.sh`. One pending baton per project; never overwrite an unread one. Commit and push it, or the other machine never sees it.
- Close: only on the owner's word; a thread never closes itself. `session-end close` lists what this thread made (scratch files, containers, temporary worktrees): remove them yourself by exact path or id, never another thread's and never one it marks as ownership unknown. Then settle the way `session-end close` prints it (T3's own settle tool; `t3-api.sh settle-when-idle` only where that tool is missing), and print the receipt first, because nothing after the settle reaches the owner.
- Time: when this thread worked a ticket, log its time before closing. `session-end close` prints the measured minutes (`active-minutes` is the tool); read what is already on the ticket first so nothing is billed twice. Ending a thread never changes a ticket's status. Closing a ticket follows `CONTEXT/work-tracking.md` (or your organization's platform skill, when this copy has it), and it does not end the thread.

## Talking to the owner

- Text written mid-turn may not be seen until the turn ends. What they must read in full goes through `send_to_user` or the final reply.
- Anything they must click within a time window (an approval link) goes last, with its expiry time, and then the turn ends.
- At most three asks in a reply, each with your recommendation and what happens if they say nothing. A hook checks this.
- They read cold. Say what a thing is before using its name; give a link beside every id.
- Data, comparisons and decisions read better as an inline page: build one HTML file from `assets/starter.html`, check it with `html_preview` at 728 and 390 wide (zero console errors), show it with `html_render`. Colors: `references/palette.md`. One page per reply.

## Getting a file to them

Pick by what they need:

- To read or look at it: show it in the thread, as an inline page or a link to its absolute path (T3 opens it in its files viewer). Nothing is transferred.
- On their computer: `grabit`, over Tailscale. It works only when `tailscale status` on this box shows it signed in and their computer online; Taildrop lands the file in their Downloads on Windows. A T3 thread has no SSH connection to find their machine from, so name it: `grabit --list`, then `grabit --to <their computer> FILE...`. Plain `grabit FILE` picks the right machine only from an SSH shell. Named files only, never a folder. "Permission denied" means the box never ran `sudo tailscale set --operator=<owner>`: tell them, do not work around it.
- Large or many files, or they want a link: `grabit --serve PATH...` prints a link that works only on their tailnet; it needs sudo and stays up until `grabit --serve-off`. Where the box's own doctrine names another delivery command, use that.
- Tailscale signed out, or none of their devices online: say so and link the path in T3. Do not paste the file into chat or invent another route.
- They sent you something: an image attached in T3 is already a saved path, read it. A file they Taildropped: `grabit --queue` pulls it into `~/grabit-inbox`; an empty queue means nothing arrived.

## Waiting

- A thread wakes only on a message, a task notice or a schedule. "I will check later" with nothing armed means it never happens. Arm `schedule_task` bound to this thread, and have its prompt delete the schedule when done.
- A background command stops after 30 minutes unless the call passes a longer `timeout` (2 hours at most).
- To wait on a background command you started, use `t3_background_wait`. To wait on a pull request, `watch_pull_request`. Never a sleep loop.

## Helper agents and other threads

- A helper's result is only its last message. Brief it: "your final message is the deliverable, in full".
- A helper that writes files gets its own worktree. One that shares your checkout moves your branch.
- Never message a running workflow agent: it starts a second copy.
- Another thread's worktree, scratch or documents are not yours to clean. Message that thread (`t3_thread_send`).
- No new top-level threads unless the owner asks.

## Review

- When the box has an OpenAI subscription (or another vendor's) wired into `OPS_REVIEWER_CMD`, code where a miss is expensive (production writes, guards, secrets, auth) gets a second-vendor review before it lands: `second-vendor-review`. Without one, say so and land on your own verification.

## The box

- T3's tools arrive as names only. Fetch a tool's definition before first use.
- Never kill processes by name pattern (`pkill -f`): your own shell and sibling agents match. Use `safe-pkill` or a recorded PID.
- A test of anything that deletes or moves files runs under `sandbox-run`.
- Guards block force-pushes, history rewrites, hook bypasses, secrets written into memory, and a push of this copy to an origin not proven private. A blocked call is a ruling, not an error to route around.
- Scratch goes in `$TMPDIR`, outputs in the project's folder, never the harness root.
- "Update the harness" in a copy of the template: `harness-update-scan.sh` compares the copy with the template. A file changed both upstream and locally is never applied automatically.
