# Technical specification: mixed Japanese–English dictation for macOS

**Version:** 2026-10-06
**Applies to:** this repository (a modified VoiceInk, GPL-3.0)
**Written for:** two readers. First, the author of a step-by-step build guide (the "roadmap writer"), who turns this into instructions a viewer hands to their own coding agent. Second, that coding agent itself, which builds the app inside an environment nobody here has seen.

This document separates three kinds of statement, because mixing them is how a guide ends up working only on its author's machine:

- **Facts about the software**: what the code does, with parameter values. Verified against the code on 2026-10-04.
- **Facts about one environment**: what was measured on the original builder's Mac. Marked *(measured on one Mac)*. Expect different numbers elsewhere.
- **Unknowns**: things nobody has checked. Marked **Unknown**. The recipient's agent must not present these as facts.

---

## 1. End state

**The person speaks a sentence that mixes Japanese and English, in any text field on their Mac, and the correct text appears at the cursor within about a second, with their own names spelled right, without touching the keyboard.**

What is true afterwards that was not true before:

- One key (by default Right Command) starts and stops dictation everywhere, and does not fire by accident during ordinary shortcuts.
- Product names, people's names and jargon come out in the person's preferred spelling, because the app knows their vocabulary.
- When the network or the cloud service fails, dictation still works through an on-device model, and the screen says so.
- Rebuilding the app does not silently remove its macOS permissions.
- Optionally: words the person corrects by hand are proposed for the dictionary; filler words are removed; the month's cloud cost is visible.

---

## 2. Routes to the end state

The recipient's agent should choose a route with the person, using the criteria below. None of these is "the" path.

| Route | What it is | Choose when |
|---|---|---|
| **A. Build this template** | Clone this repository and build it. Everything in this spec is already implemented. | The person has a Mac with Xcode (or can install it) and wants the full feature set. This is the shortest route. |
| **B. Upstream VoiceInk, settings only** | Use the official VoiceInk app or an unmodified build, and only configure it (Soniox, vocabulary, shortcut). | The person does not want to build software. They get the engine and the vocabulary, which are most of the accuracy gain, but not the fallback, the shortcut fix, the Japanese filler removal or the Auto Learn fixes. |
| **C. Re-implement on another base** | Apply the behaviour in sections 6–7 to a different app or codebase. | The person already maintains their own dictation tool. Use sections 6–7 as the behaviour contract and section 9 as the list of traps. |

### 2.1 Which version to build

- **This release:** the tag `v2.21-jp.2`. Route A clones exactly that tag: `git clone --branch v2.21-jp.2 https://github.com/matsumotoryosuke-dev/voice-dictation-jp-template.git`. The `main` branch may move after the guide is written; the tag does not.
- **The upstream it is based on:** VoiceInk commit `c09cc1f` in Beingpax/VoiceInk (2026-10-01; the app reports version 2.21).
- **The two commit IDs are not a contradiction.** `c09cc1f` is the commit in upstream's repository. `d04a88f` is the first commit in this repository, which holds that same upstream code unchanged. `git diff d04a88f v2.21-jp.2` shows every change this template makes.
- GitHub's "Use this template" button copies the current `main` as a single new commit, without this history or the tags. After using it, `d04a88f` does not exist in the new repository; `NOTICE.md` still lists the changes. To keep the version fixed and the history readable, clone the tag instead.

**Minimum agent capability.** Route A and C need an agent that can run commands on the person's Mac (a terminal-capable coding agent). An agent limited to chat can still guide the person command by command; it must then ask the person to paste each command's output back, and must treat "it looks done" as unverified until that output is seen.

---

## 3. Preconditions and how to verify each

The agent verifies each by doing the smallest real version of it, not by asking "is X installed?".

| Precondition | Verify by | If absent |
|---|---|---|
| macOS 14.4 or later | `sw_vers -productVersion` | Stop. The app does not run on older macOS. |
| Apple Silicon | `uname -m` returns `arm64` | **Unknown** whether Intel Macs work. Say so; do not promise it. |
| Xcode installed and licence accepted | `xcodebuild -version` prints a version | The person installs Xcode from the App Store and opens it once. Command Line Tools alone are enough for `make test-core` but not for building the app. |
| Disk space | `df -h ~` | Build output is about 3.5 GB; the local Whisper model is about 1.7 GB *(measured on one Mac)*. |
| Memory, if Auto Learn's local reviewer is wanted | System Settings → About, or `sysctl hw.memsize` | The reviewer model used here occupies about 10 GB while loaded. On a 16 GB Mac, recommend leaving Auto Learn review off or choosing a smaller model, and say the smaller model is untested (**Unknown**). |
| A cloud speech-to-text account (if cloud is chosen) | The person can sign in to the provider's console | The person creates the account and the API key **themselves**. See section 10. |
| Ollama (only for Auto Learn) | `curl -s http://127.0.0.1:11434/api/tags` returns JSON | Auto Learn capture still works; review cannot run until a provider exists. |

---

## 4. Questions the agent must ask the person

These are facts or preferences only the person has. The agent asks **one at a time**, offers a short list of examples where that helps, and always accepts an answer outside the list. Each entry says why it matters and what to do with the answer. Where an answer is not covered, decide by the stated criterion; if that is not enough, ask.

1. **Which languages do you mix when you speak?**
   Why: the engine choice depends on it. Soniox real-time was the most accurate on Japanese with English inside the sentence *(measured on one Mac, one speaker)*. Other pairs are **Unknown**; VoiceInk supports many providers, and the person should compare two on their own speech before committing.

2. **Is it acceptable that your speech is sent to a cloud service?**
   Why: with a cloud engine, everything dictated (including private messages) goes to that provider. If not acceptable, use an on-device model only and say plainly that accuracy on mixed speech will be lower (on-device Whisper made about 1.5× the errors of Soniox on the test speech, *measured on one Mac*).

3. **Which apps do you dictate into most?**
   Why: these are the apps to test pasting and correction capture in. Electron and browser apps (Claude, Notion, Obsidian, Slack, Gmail in a browser) behave differently from native ones. Terminal is out of scope: its Secure Keyboard Entry blocks global shortcuts.

4. **Which key do you want for dictation?**
   Default: Right Command in Hybrid mode (tap to start/stop; hold to talk while held). Double-tapping a key is deliberately not offered: detecting a double tap delays every single use by about 250–300 ms.

5. **Which names and terms do you say often, and how should each be spelled?**
   Why: giving the engine a vocabulary list mattered more than the choice of engine on the test speech. Collect 10–40 terms. Also ask for spellings that must never appear (for example a wrong kanji for the person's surname).

6. **Which filler sounds do you want removed, and how strongly?**
   Why: some fillers are also real words. Section 6.4 lists the defaults. Ask specifically about words that are both (in Japanese: まあ, あの, その, なんか). The person's own habit decides; there is no correct answer.

7. **Do you want hand corrections proposed for the dictionary (Auto Learn)?** If yes: **review each batch yourself, or let it apply automatically?**
   Why: automatic review loads a local model (about 10 GB here) after each correction; manual review loads it only when the person presses Review Now. The reviewer is unreliable (section 6.6), so manual review with the person deciding is the safer default.

8. **Do you want the cloud cost shown in the app?** Only relevant with Soniox.

9. **Do you allow the app to read your screen (Screen Recording)?**
   Why: VoiceInk can read on-screen text to give its optional AI clean-up feature context. Dictation does not need it. Default: do not grant.

---

## 5. Milestones, each with a test that can fail

Each milestone is an end state. The agent records which milestones are done in a file inside the cloned repository (for example `SETUP-PROGRESS.md`), so that a new session can resume. The person is told that file exists.

| # | End state | Test (must be able to fail) |
|---|---|---|
| M0 | The repository builds its tests | `make test-core` exits 0 and reports the test count. |
| M1 | The app builds and opens | `make local` ends with "Build complete"; the app launches from `/Applications`. |
| M2 | Rebuilds keep permissions | After creating the `VoiceInk Local` certificate (section 7.1): `codesign -dvv /Applications/VoiceInk.app` shows `Authority=VoiceInk Local`; rebuild and reinstall once more; the dictation key still works without re-granting anything. |
| M3 | Dictation works in the person's main app | The person reads a prepared sentence that mixes their languages and contains three of their own terms. Text appears at the cursor; the terms are spelled as the person wants. |
| M4 | Fallback works | With Wi-Fi off, dictation still produces text, and a notice says the local model was used. |
| M5 | The key does not misfire | Right Command + C, Right Command + click, and Right Command + Shift do not start a recording (or start and cancel within a second). |
| M6 | Corrections apply | A word the engine gets wrong, added as a replacement, comes out right on the next dictation. |
| M7 | Fillers behave as chosen | A sentence with the chosen fillers loses them; a sentence with the same sounds used as real words (「その件」) keeps them. |
| M8 (optional) | Auto Learn reaches the dictionary | In a chat app, dictate, fix one word by hand, send. Review Now lists the correction; approving it adds it; the next dictation uses it. |
| Done | The person uses it by choice | In a **new** session the next day, the person dictates five real messages in their main app. The agent asks how many needed keyboard fixes and why. This test runs where the building session is not, so it can fail. |

---

## 6. Behaviour contract (what the software does)

### 6.1 Speech recognition engine

- **Primary engine:** Soniox real-time, model `stt-rt-v5`, over WebSocket `wss://stt-rt.soniox.com/transcribe-websocket`. Audio is 16 kHz mono PCM (`pcm_s16le`).
- **Vocabulary:** the person's dictionary terms are sent in the session configuration as `context.terms`.
- **Language:** "auto" sends `enable_language_identification: true` with no hint, which is what mixed speech needs. A fixed language sends `language_hints` with `language_hints_strict: true`.
- **Finishing:** on key release the app sends `{"type":"finalize"}` and pastes the final text. Measured time from release to text: 0.08–0.26 s over 81 real dictations *(measured on one Mac)*.
- **Price:** Soniox real-time costs $0.12 per hour of audio; file upload $0.10 per hour (Soniox pricing page, 2026-10). Heavy daily use came to about $1 a month *(measured on one Mac)*.

### 6.2 Cloud-to-local fallback

The app classifies each cloud failure and decides:

| Failure | Decision |
|---|---|
| Offline (known before the attempt) | Skip the cloud; use the local model; say so. |
| Timeout, HTTP 408 | Use the local model; say so. |
| Connection failed, server error, HTTP 429, HTTP 5xx | Use the local model; say so ("service unavailable"). |
| HTTP 401/403, key rejected | Use the local model; say "key rejected". |
| Key missing | Use the local model; say "key missing". |
| The cloud answered with empty text | Use the local model ("returned no text"). |
| No speech detected | Report "No speech detected"; do not fall back; paste nothing. |
| Cancelled by the user | Stop silently. |
| Any other client error (HTTP 400 etc.), unsupported model, bad audio | Report the original error; do not fall back. |

- **Local model choice:** the largest downloaded multilingual Whisper model.
- **No local model downloaded:** the error says both what failed in the cloud and that no local model exists.
- **Slow first press:** when the live connection did not finalise in time (typically the first press after a pause), the app does **not** upload the recording to the cloud as a file (3–8 s); it runs the local model instead, when one exists. On the test Mac, local Whisper then took 4–6 s, so the gain there is small *(measured on one Mac)*.
- **Nothing is pasted** when the final text is empty; pasting an empty string would overwrite the clipboard.

### 6.3 Dictation key isolation (ChordGuard)

A modifier-only shortcut (Right Command) starts recording on key-down. ChordGuard cancels that recording if, **within 1.0 s of the press**, any of these happens: a non-modifier key goes down; another modifier joins; a left or right mouse button goes down (observed through a listen-only event tap). It cancels at most once per press, and a cancelled press does not start the shortcut's cooldown.

### 6.4 Filler removal

Applied to the final text before pasting. The person can edit the list in Settings.

- **English, word boundaries:** um, umm, uhm, uh, uhh, uhhh, hmm, hm, mmm, mm, er, err, ahh.
- **Japanese pure hesitations**, removed when they stand alone between boundaries (start/end of text, space, punctuation 、。，．！？!?…「」『』（）()〜~): えーっと, えーと, えっと, えと, えー, えぇ, あのー, あのう, あのぉ, うーん, うー, うぅ, あー, あぁ, んー, んん, そのー, そのう. A following 、 is removed with them.
- **まあ / まぁ (strong):** removed where it starts a phrase or is followed by a comma, but まあまあ ("so-so") stays.
- **あの / その (comma only):** removed only when a comma follows, because without one they usually mean "that" (あの件, その件).
- **なんか:** never removed by default.
- **Real words are protected:** a Japanese filler must both start and end at a boundary, so そのうち and へえー are never damaged. Longer forms match first (えーっと before えー).

### 6.5 Dictionary and shared vocabulary

**Word replacement (upstream behaviour, kept):** rules apply longest source first, case-insensitively. A rule containing Japanese, Chinese, Korean or Thai is a plain substring replacement with no word boundary; other rules match whole words.

**Consequences the recipient must know:**
- A Japanese rule replaces the text **inside longer words**. A rule ボード → board would also turn キーボード into キーboard. Only add Japanese rules for strings that never occur inside another word.
- Rules apply in sequence, so a later rule can re-edit an earlier rule's output. Check that no replacement contains another rule's source.
- A rule whose source and replacement differ only in capital letters (Re:issue → RE:Issue) cannot be stored.

**Shared vocabulary file** at `~/.config/dictation/vocabulary.json`:

```json
{"terms": ["Obsidian", "Notion"], "corrections": {"オブシディアン": "Obsidian"}}
```

- Two-way sync with the app's dictionary. Changes in the file reach the app, and changes in the app reach the file.
- **Three-way merge** against the last agreed state, kept at `~/Library/Application Support/com.prakashjoshipax.VoiceInk/shared-vocabulary-base.json`, so deletions propagate in both directions. When both sides changed the same entry, the app's value wins. The first sync, with no agreed state, takes the union.
- Sync runs when the file or its folder changes (0.5 s debounce), when the app comes to the front, and every 60 s, because editing the dictionary inside the app posts no notification.
- **Known defect:** a change that differs only in capitals (NOTION → Notion) is mishandled. The term was deleted and not re-added. Workaround: remove the entry, let one sync pass, then add the new spelling.
- A tool that writes this file must **merge** into it, never overwrite it. Overwriting reads as "the user deleted everything the app learned".

### 6.6 Auto Learn (learning from hand corrections)

**Capture:**
- After pasting, the app reads the focused text field through the Accessibility API and finds the pasted text in it.
- Electron and Chromium apps expose their accessibility tree only when the `AXManualAccessibility` attribute is set. The app sets it **even when its current value cannot be read**; several Electron apps accept the setting but do not report it.
- The app sets the attribute **when recording starts** on the frontmost app, and asks for its focused element once, because that first query is what makes Chromium build the tree. Setting it only at paste time left the tree unbuilt: 21 of 26 captures failed in one day, all of them more than 120 s after the previous dictation *(measured on one Mac)*.
- The first read happens 120 ms after the paste (0.10 s accessibility timeout). Retries follow 150, 300, 600 and 1000 ms later (0.4 s timeout each).
- The attribute is restored 300 s after the last session, or 600 s after a recording that never pasted.

**Watching the edit:**
- The app watches the field for 60 s: on every value change (an `AXValueChanged` observer on the field itself, not app-wide, because an app-wide watch fires on every token of a streamed chat reply) and every 400 ms as a safety net.
- It keeps the **last state that is still recognisably the paste**. The watch ends early when the paste disappears: the field emptied (a chat message was sent), the surrounding text was edited away, or other text replaced it.
- **Recognisably the same:** at least half of the pasted words survive; for a paste of three words or fewer, the edited text only has to stay within about three times the original length (or 24 characters).

**Turning an edit into candidates:**
- The diff splits text at whitespace, ASCII punctuation, full-width punctuation (、。，．！？「」『』（）【】〔〕：；) and **script changes** (kanji / hiragana / katakana / other). The long-vowel mark ー and sound marks belong to whatever they follow.
- Without the script split, a whole Japanese clause was one "word". A one-word fix then became a 40-character candidate, which a 32-character limit on unspaced candidates dropped.
- Each candidate keeps up to three neighbouring segments on each side as context for the reviewer.

**Review:**
- Candidates queue on disk and are judged by an AI reviewer through the app's AI-provider settings. A local Ollama model keeps corrections on the Mac.
- **Review timeout: 180 s.** It must not share the 7 s timeout of the app's text-enhancement feature. On the test Mac the model needed about 4 s to load and 30 s to judge 14 corrections *(measured on one Mac)*.
- The request includes the person's existing vocabulary (`knownVocabulary`). Given it, the reviewer accepted corrections toward known brand names it had otherwise rejected *(measured on one Mac, one run)*.
- The reviewer's answer is read **one decision at a time**. A single surrounding markdown code fence is removed; missing null fields and extra keys are tolerated; a malformed decision is skipped and logged by kind.
- **Every correction sent must get a decision.** When the answer leaves some out (an empty list, a short list, decisions whose ID matches no correction sent, or an answer that is not a JSON array at all), the app asks once more about only those corrections, under the same IDs. Corrections still without a decision after that are **not** treated as rejected: they go back to the queue, and the app raises the Auto Learn warning, "The AI did not return a decision for N of M corrections." The review panel then shows that message instead of "No Corrections to Review". A timeout or network error fails the review as before, with every correction left queued.
- **The reviewer is unreliable.** On the same 14 corrections, three runs accepted 3, 5 and 2 *(measured on one Mac)*. In manual review, rejected corrections, and those whose decision could not be applied as given, are therefore listed too, unticked and marked "AI rejected", with the changed words taken from the diff. Applying the list unchanged adds only what the reviewer accepted.
- When the list holds corrections and the reviewer accepted none of them, a line above the list reads "The AI accepted none of these corrections. Check each one before you dismiss them.", so "Dismiss All" is not pressed on the reviewer's word alone.
- Before reporting "no provider", the app asks Ollama again. At login VoiceInk can start before Ollama does and would otherwise treat Ollama as absent all day.

**Ollama settings that matter:**
- VoiceInk does not tell Ollama how much context to reserve, so Ollama's default window applies. With a 65,536-token default, the 12B model used here reserved 19 GB and stalled Ollama *(measured on one Mac)*.
- Fix: create a model alias with a fixed window and select it for Auto Learn.
  ```
  FROM <your model>
  PARAMETER num_ctx 8192
  ```
  `ollama create <alias> -f Modelfile`. Confirm with `ollama ps` that the CONTEXT column shows 8192.
- How long Ollama keeps the model loaded after use follows the person's `OLLAMA_KEEP_ALIVE` setting. Check it before promising memory use.
- Reasoning models must be called with thinking disabled. With thinking on, the test model returned empty answers.

### 6.7 Dictation journal

One JSON line per dictation in `~/.config/dictation/dictation-log.jsonl`. The journal records no dictated text.

```json
{"at":"2026-09-20T18:21:10Z","clip_s":16.8,"level_db":-41.3,"api_s":0.12,"path":"stream","model":"Soniox V5","chars":42,"fallback":null,"error":null}
```

- `path` is `stream` when the result came within 1.0 s, `upload` when it took longer, `local` when the local model produced it, and `unknown` without timing.
- The file keeps its last 5000 lines. Writing never makes a dictation fail.

### 6.8 Cloud cost on the dashboard

- `GET https://api.soniox.com/v1/usage/summary?start_time=…&end_time=…` with `Authorization: Bearer <key>`. Timestamps are UTC ISO-8601; the window may not exceed 366 days.
- The dashboard sums the response's daily `cost_usd`, `input_audio_duration_ms` and `num_requests` into this month and last month. Months are UTC months.
- The card refreshes when the dashboard appears, at most every 10 minutes, and on its refresh button.
- Soniox exposes **no prepaid balance**, so none is shown. The figures cover everything billed to that key, including use outside the app.

---

## 7. Build and environment

### 7.1 Signing and macOS permissions

- macOS ties Accessibility, Microphone and Input Monitoring grants to the app's code signature. An unsigned (ad-hoc) build gets a new identity every time, so **every rebuild silently removes those grants** while System Settings still shows them ticked. The symptom is a dictation key that does nothing.
- **Fix:** a self-signed code-signing certificate named exactly `VoiceInk Local`, created by the person in Keychain Access (Certificate Assistant → Create a Certificate → Certificate Type: Code Signing). `make local` detects it and re-signs the finished app. No paid Apple Developer account is needed.
- **One-time exception:** a permission first granted to an older unsigned build stays tied to that build, and macOS asks once more after the first signed install. To check before telling the person "no re-grant needed":
  ```
  /usr/bin/log show --last 5m --info --predicate 'process == "tccd" AND eventMessage CONTAINS "Failed to match existing code requirement"'
  ```
  Any line naming the app is a permission the person will be asked for again.
- In zsh, `log` is a shell builtin. Call `/usr/bin/log`, or the command silently returns nothing.

### 7.2 Commands

| Purpose | Command |
|---|---|
| Unit tests (no Xcode needed) | `make test-core` |
| Build the app into `~/Downloads/VoiceInk.app` | `make local` |
| Install | Quit the running app, then copy the app to `/Applications` and reopen it |
| Read the app's logs | `/usr/bin/log show --last 30m --info --predicate 'subsystem == "com.prakashjoshipax.voiceink"'` |
| Auto Learn logs only | add `AND category BEGINSWITH "AutoLearn"` |

If the repository sits in an iCloud-synced folder (Desktop or Documents with iCloud Drive), builds may fail with "modified during the build", and code signing may fail on extended attributes. Build from a folder outside iCloud.

### 7.3 Updates are off in local builds

- Upstream VoiceInk updates itself through Sparkle from the official feed (`SUFeedURL` in `Info.plist`). That feed's update is signed with the official EdDSA key, which this fork also carries (`SUPublicEDKey`). Sparkle's rules allow the code-signing identity to change while the EdDSA key stays the same, so Sparkle would accept the official app, install it over this build and remove every change listed in `NOTICE.md`. This was not tested by installing it.
- A `make local` build therefore never starts the updater, and the "Check for Updates" items in the app menu, the menu bar and Settings are hidden (`UpdaterViewModel.isEnabled`, false under `LOCAL_BUILD`).
- To take upstream's later changes, port this fork's diff onto the newer upstream (route C in section 2) and rebuild.

---

## 8. Measurements, for expectations only

All figures are from one speaker, one microphone and one Mac (Mac mini, M4 Pro, 24 GB). They show the size of the differences, not what the recipient will get.

Test speech: four scripted passages (English inside Japanese, a formal email, a paragraph that starts in English, a run of 18 names). Score = share of characters wrong against the script; punctuation and spacing ignored.

| Setup | Characters wrong | Names right (of 32) |
|---|---|---|
| Soniox live `stt-rt-v5`, with vocabulary | 14.1% | 27 |
| Soniox file upload, with vocabulary | 13.6% | 25 |
| Deepgram nova-3 multi, file upload, with vocabulary | 14.2% | 3 |
| Soniox file upload, no vocabulary | 15.2% | 18 |
| Qwen3-ASR 1.7B, on-device | 17.0% | 10 |
| Whisper large-v3-turbo, on-device | 21.3% | 5 |
| Deepgram live, with vocabulary | 21.7% | 9 |
| The dictation built into a chat app (the tool being replaced) | 37.6% | 6 |

- The remaining errors were mostly English words written in katakana (フック for "hook"). Adding a few unambiguous katakana-to-English replacement rules removed most of them at no cost.
- A **local LLM clean-up pass after transcription was tested and rejected.** It looked better on the passages its instructions were written from. On unseen speech it doubled the error rate by inventing plausible words, and it took 4–57 s per dictation. Do not add one without measuring on speech it has never seen.

---

## 9. Things that went wrong, and what each teaches

Each is a stop point or a reason the agent can act on.

1. **Rebuilds removed permissions silently.** Sign with a fixed certificate before the second build (7.1), and tell the person after every install which permissions, if any, to re-grant.
2. **A storage-cleanup agent deleted the built app and models**, because it treated "in Downloads" or "a cache" as safe to delete. Install the app into `/Applications`, never leave it in Downloads, and keep the person informed before deleting anything.
3. **The local model silently dropped about a third of long recordings** until audio was split at pauses. A measuring tool can lie; check its output length against the input.
4. **"The API returns nothing"** was a near-silent recording plus a new, loud error message. Check the recording level before blaming the service.
5. **A tool's reassurance was wrong:** Auto Learn was declared working without a test and had never learned a word. Verify a feature by making it do its job once.
6. **Japanese dictionary rules damage longer words** (6.5). Never add a rule for a katakana word that Japanese also uses on its own.
7. **The vocabulary sync loses case-only edits** (6.5). Use the workaround.
8. **A builder script that overwrote the shared file** would have erased learned words through the sync. Always merge.
9. **The AI reviewer's judgement varies run to run** (6.6). Show its rejections and let the person decide.
10. **Ollama's default context window** reserved 19 GB on a 24 GB Mac (6.6). Fix the window.
11. **Login order:** the app started before Ollama and never looked again (6.6).
12. **An imitation of a tool's settings gave misleading results.** The tool's own code, run on the same audio, gave the real ones. Measure the real thing.
13. **The fork kept upstream's self-updater.** One click on the dashboard's update button would have replaced the fork with the official app (7.3). When forking an app, look for anything that fetches and installs code from the original's servers.

---

## 10. What the agent must never do

- Never ask the person to paste an API key into the chat, and never write one into a file the agent created, a commit or a log. The person enters keys in the app's settings themselves.
- Never change macOS security settings (SIP, Gatekeeper) to make something work.
- Never publish, upload or commit the person's vocabulary, dictations, recordings or logs.
- Never install or replace the app without saying so in the same message, together with which permissions the person may need to re-grant.
- Never state that permissions survived an install without the check in 7.1.
- Never add features nobody asked for. In particular, do not add an LLM clean-up pass (section 8) or extra replacement rules the person did not approve.
- Never describe this repository as official VoiceInk.
- Never turn the updater back on in a local build (7.3).

---

## 11. Known limits and open questions

- **Unknown:** behaviour on Intel Macs.
- **Unknown:** accuracy for language pairs other than Japanese–English.
- **Unknown:** Auto Learn capture in Notion, Obsidian and Gmail. It was verified only in the Claude desktop app.
- **Unknown:** a smaller reviewer model for Macs with less memory.
- The vocabulary sync's case-only defect (6.5) is not fixed.
- VoiceInk can read the screen for its optional AI clean-up feature only if Screen Recording is granted. Dictation does not need that permission.

---

## 12. Where things are in this repository

| Area | Files |
|---|---|
| Fallback policy and orchestration | `VoiceInk/Features/Recording/Core/TranscriptionFallbackPolicy.swift`, `FallbackTranscriber.swift`, `Workflows/TranscriptionPipeline.swift`, `TranscriptionSession.swift` |
| Dictation key isolation | `VoiceInk/Features/Shortcuts/Core/ChordGuard.swift`, `Coordination/ShortcutMonitor.swift` |
| Filler removal | `VoiceInk/Features/Recording/Core/FillerStripper.swift`, `Processing/TranscriptionOutputFilter.swift` |
| Shared vocabulary | `VoiceInk/Features/Dictionary/Core/SharedVocabularyFile.swift`, `Workflows/SharedVocabularySync.swift` |
| Auto Learn | `VoiceInk/Features/Dictionary/AutoLearn/*` |
| Journal | `VoiceInk/Features/Recording/Core/DictationJournal.swift` |
| Cost card | `VoiceInk/Features/Dashboard/Usage/*`, `Components/SonioxUsageCard.swift` |
| Updates off in local builds | `VoiceInk/App/Updates/UpdaterViewModel.swift`, `App/MenuBar/MenuBarView.swift`, `Features/Settings/Views/SettingsView.swift` |
| Unit tests | `Tests/*` (run with `make test-core`) |
| Everything changed from upstream VoiceInk | `NOTICE.md`; `git diff d04a88f v2.21-jp.2` (`d04a88f` holds upstream `c09cc1f` unchanged; see 2.1) |
