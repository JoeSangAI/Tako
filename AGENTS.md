# Tako

Desktop soft-body companion that sticks to a window and gives it intelligence. README is the public product page. If `.local/AGENTS.private.md` exists, read it too: it holds this machine's private rules, and `.local/STATUS.md` holds the current verified state.

This repository is public. Personal paths, names, chat content, keys and client facts never enter it: whatever is personal goes in `~/Library/Application Support/Tako/config.json`. `scripts/check_public.sh` guards this on every push.

## Rules that must hold

- It is called Tako everywhere, in the UI and in the model's prompts. It does not answer as any other assistant name.
- Fill, never send: Tako may put text into an app's input and change documents the owner asked it to change, but must never press Return, click a send button or otherwise send a message. Only the owner's own words can trigger writing; what an incoming message or window shows never can.
- DingTalk is off limits: never stick to or operate its window.
- Operating an app (`Operate.swift`): sending stays refused even with approval; Enter is refused in messaging apps; password fields are refused; irreversible words and network/system tools go through an approval card every step.
- A job belongs to the window it was asked on and goes on wherever the owner goes (Joe 2026-11-01: people and the agent run apart, that is what saves them time). Switching away or dragging the goo to another window never stops it; only the stop button does, and only for what the panel shows. It works behind the owner's back: Accessibility and events sent to that app alone, never their focus, pointer or clipboard. What only the real pointer can do waits until they are back on that window and idle (`ownerIsAway`), and nothing brings a window forward except a button they pressed.
- A turn started by someone else's message runs on a throwaway thread with no tools at all (`READER_CONFIG`); never give it shell, plugins or `TOOLS`. Tool calls and approvals count only on the threads of the owner's own jobs (`on_thread`). It may ask for a knowledge lookup in words; the system runs one fixed read-only query (no shell, no network).
- A limb has what the brain has (Joe 2026-11-02: the point is the same intelligence at every window, and using AI already means trusting the provider): the owner's turns read this Mac's files and keys like their own Codex does. What stays narrow is writing: the turn's folder, plus paths in the owner's own words and files they handed over (`named_paths`), and one card per thing outside that. Don't add read limits or more cards; the lines above are the floor.
- Filling says it filled only when it can tell: a page with no cursor in a field is an error, never success (`insertBehindTheOwner`).
- Learning from the owner's edits keeps habits only (`voice.md`), never sentences, names or figures; `metrics.jsonl` holds numbers only. Tako speaks unasked only when it is worth it: silence is the default.
- Listening (`Listen.swift`): starts only on the owner's words, only the stuck app's sound, never calls or meetings; audio pieces are deleted once read and nothing leaves the Mac. Notes come from a throwaway thread with no tools.
- Feedback (`feedback.py`): never interrupts: no cards, no questions, one checkmark in the menu, on unless switched off, and off stops all of it. Automatic reports hold only numbers, fixed vocabulary and error type and place, never words, names or identifiers, not even abstracted ones. Free text leaves only when the owner asks to tell the author and taps send on the card that shows it. Extraction reads only the owner's panel words on a throwaway thread with no tools. Change `docs/PRIVACY.md` in the same commit as anything that changes what leaves. The receiver takes no key and serves nothing back.
- Greetings (`greetings.py`): only the app's name goes to the model, never the title or anything in the window, on a throwaway thread with no tools; lines are shown as plain text and only in the empty panel.
- Peeled off a window, it stops reading on its own initiative; a job the owner already started goes on. Chat text stays in memory; never log or commit chat content, keys or tokens.
- Runtime state lives in `~/Library/Application Support/Tako/`, never inside the app bundle (a write there breaks its signature and the permissions with it).
- Moving or narrowing another app's window needs Accessibility; always put it back unless the owner moved it. The panel never covers a full window if it can be helped.
- Tests never change network or proxy tools' state, never send anything, and write to an isolated `TAKO_HOME`. `TAKO_HOME` also turns reports off, so the real app must never set it for its own server.

## Releasing

A release is a version bump, nothing else: change `VERSION`, add a section to `CHANGELOG.md` written for the people who use Tako (what they get, not what changed in the code), commit, `git push`. `.githooks/pre-push` runs the tests and the public check, builds and signs the app, and publishes the GitHub release once the push lands; every installed Tako then offers it. A push that keeps `VERSION` reaches nobody. Enable the hook in a new checkout with `git config core.hooksPath .githooks`.

A release also carries a small package without the Python, which an installed Tako with the same `python.id` fetches instead of the whole app; the Python is signed once and cached in `.build/signed-python/` so its bytes stay the same. Losing that cache only means the next update is whole again.

Updates install only when the new app satisfies the running app's designated requirement, so the signing identity must stay the same: changing it strands everyone on the old version and resets their permissions.

## Layout

`docs/ARCHITECTURE.md` is the map: the two processes, the two kinds of thread, what each file is for, how to add a tool. Read it before moving anything.

`Sources/native/` the app (Swift): goo, windows, panel window, hands, updates. `Sources/brain/` the Python side and the panel page. `server/feedback_receiver.py` where reports land.

`tests/test_guards.py` the lines that must hold. `tests/test_turns.py` the real Python side against `tests/fake_codex.py`, with the test playing the app: write a new behaviour or a bug as a scene there first. `run.sh` builds and restarts for development. `scripts/` build and release.
