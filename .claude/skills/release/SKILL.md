---
name: release
description: Use when the user wants to release, publish or ship a new version of Pluginarium ("udělej release", "vydej novou verzi", "make a release"), or to build the signed and notarized DMG for distribution.
---

# Releasing Pluginarium

A release is: version bump → tests → signed + notarized DMG + appcast →
merge + tag → GitHub Release → website → live checks. Every step
below has a check; a step is not done until its check passed.

**Pushing needs the user's explicit OK** (global rule). Before step 5 ask
one bold question that names all three pushes of this release (tag, GitHub
Release, `main`) and, if the repo is still private, making it public, unless
the user has already said yes to exactly that in the conversation.

## 1. Prepare

1. `git status` clean, on `main`, up to date. Create the branch `release/vX.Y.Z`.
2. Pick the version. The **first release is 0.1.0** (the version the skeleton
   already carries and the website links point at). After that: patch for
   fixes and small additions, minor for new features or removed UI, major only
   when the user says so. Say which and why.
3. `CHANGELOG.md`: rename `## Unreleased` to `## X.Y.Z — YYYY-MM-DD`. If there
   is no Unreleased section, write the entries from `git log` since the last tag
   first. These lines become the GitHub Release notes and the text of the update
   dialog.
4. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in
   `Resources/Info.plist`.
5. Replace the old version in the website: `grep -rn "<old version>" docs/*.html docs/cs/*.html`
   (download links `releases/download/v…/Pluginarium-….dmg` and version texts).

Check: `swift test` green (redirect the output to a file, read the summary line).

## 2. Build the DMG

`./build.sh dist` — takes several minutes (two notarizations); run it in the
background and wait for it to finish.

Check, all of them:
- the log shows `status: Accepted` twice and ends with `Done!`;
- `spctl -a -vv build/release/Pluginarium.app` says `source=Notarized Developer ID`;
- `git diff docs/appcast.xml` shows the new version, the new download URL
  and a new `sparkle:edSignature`.

A `403 … agreement is missing or has expired` from notarytool means the user
must accept the new Apple agreement at developer.apple.com/account — stop and
tell them.

## 3. Screenshot (when the UI changed)

Open `build/release/Pluginarium.app`, capture only its window
(`screencapture -x -o -l <window id>`; the window id from
`CGWindowListCopyWindowInfo`), look at the image, then copy it to
`docs/assets/pluginarium-window.png`. Never capture the whole screen or other
apps' windows. Quit the app afterwards.

## 4. Commit, merge, tag

1. Update `.planning` if the project uses it (ROADMAP row, STATE line,
   `phases/NN-vX.Y.Z-release/VERIFICATION.md` with the checks above).
2. `git status`, then commit (never with AI attribution trailers): `chore(release): vX.Y.Z — version bump, CHANGELOG, appcast, website`.
3. `git switch main && git merge --no-ff <branch> -m "chore: merge … — vX.Y.Z release"`,
   delete the branch, `git tag vX.Y.Z` (lightweight).

## 5. Publish (order matters)

0. `gh repo view jiripisa/pluginarium --json visibility --jq .visibility`. If it says
   `PRIVATE` (the project was kept private until its first release), and the
   user agreed in the bold question:
   `gh repo edit jiripisa/pluginarium --visibility public --accept-visibility-change-consequences`,
   then turn on Pages:
   `gh api -X POST repos/jiripisa/pluginarium/pages -f "source[branch]=main" -f "source[path]=/docs"`.
1. `git push origin vX.Y.Z`
2. Copy `build/Pluginarium.dmg` to a scratch folder as `Pluginarium-X.Y.Z.dmg` and run
   `gh release create vX.Y.Z <that file> --title "Pluginarium X.Y.Z" --notes-file <CHANGELOG section>`.
3. Check: `curl -sIL -o /dev/null -w "%{http_code}" https://github.com/jiripisa/pluginarium/releases/download/vX.Y.Z/Pluginarium-X.Y.Z.dmg` → `200`.
4. Only now `git push origin main` (it carries the appcast; the DMG must
   already exist).

## 6. Live checks

1. Wait for the Pages deploy: `gh run list --limit 1`, then `gh run watch <id> --exit-status`.
2. `curl -s "https://jiripisa.github.io/pluginarium/?x=$RANDOM" | grep -o "X.Y.Z"` shows the new version;
   the same for `https://jiripisa.github.io/pluginarium/cs/`.
3. Download the DMG from the release URL and the live appcast
   (`https://jiripisa.github.io/pluginarium/appcast.xml`), then
   `.build/artifacts/sparkle/Sparkle/bin/sign_update --verify <dmg> <edSignature from the live appcast>`
   must print nothing and exit 0 — the feed's signature matches the published bytes.

## Report

Tell the user: the release URL, what was pushed, the results of every check,
the version choice and why, and ask them to confirm that an installed older
version offers the update.
