# ReArc releases

Every distributed build (a DMG or an update in the appcast) has an entry here, newest
first. The entry lists everything that changed since the previous release, written for
the people who use ReArc. `shell/scripts/release.sh --dmg` refuses to build until the
committed `RELEASES.md` has a heading for the build it is about to make:

    ## ReArc <VERSION> (<build>) — <YYYY-MM-DD>

`<build>` is the commit count of the commit that adds the entry, so write it as the last
commit before the release, with `echo $(( $(git rev-list --count HEAD) + 1 ))` as the
number. Details: engine/docs/RELEASE.md, "Release notes".

## ReArc 0.1.0 (544) — 2026-11-10

Security release candidate. It fixes the findings of the security review of build 500.

**Security**
- The engine moves to Chromium 156.0.8078.96, with 65 security fixes from Google, including
  CVE-2026-125350, which is exploited in the wild. Release builds now refuse an engine that is
  behind Chrome's latest Mac security release.
- Safe Browsing works: ReArc warns before known phishing and malware pages and dangerous
  downloads. Settings says when Safe Browsing is unavailable instead of claiming protection.
- ReArc ignores debugging and sandbox-weakening launch switches, so another program can no
  longer relaunch it with remote debugging to read your cookies.
- Permission prompts ignore clicks and keys for half a second after they appear, and
  "Remember this decision" starts off. Extension install and permission dialogs work the same
  way, and Return means Cancel on permission requests.
- Extensions from another browser install from the Chrome Web Store only, and only the ones
  counted when you agreed. A Web Store version asking for more permissions than your old copy
  asks you first. Unpacked extensions are listed with their folder, to load by hand.
- Onboarding no longer copies the password database, even to count it, and the importer no
  longer opens Arc's sign-in file.
- A password found in a data breach now shows a warning.
- Page full screen names the site that took it over.
- Links opened from the context menu open as link clicks, from http and https only, and carry
  the page that linked to them.
- Automatic Peek ignores clicks a page fakes with script.
- The call card shows a microphone or camera as live whenever it is recording, whatever the
  page says.
- Script boosts that arrive by iCloud sync stay off until you approve them on this Mac.
- Updates: the Sparkle feed is signed and each update is verified before it is unpacked.
- Search suggestions are fetched over https only, and prompts show http:// for insecure sites.

## ReArc 0.1.0 (500) — 2026-11-10

Release candidate. Developer ID signed, notarized, Production iCloud.

**Onboarding and first run**
- The sunrise onboarding now plays on every new install, and again on the next launch if
  it was quit or interrupted before it finished. Existing installs are never onboarded again.
- A new install starts empty, with no sample spaces, tabs or favorites. The onboarding
  creates your spaces; skipping it gives one empty space.
- Resuming an interrupted onboarding reuses what it had already imported, with no duplicate
  spaces or profiles, and the welcome page counts your spaces correctly.

**Importing from Arc, Chrome and Brave**
- Extensions install by themselves in the background after the onboarding, with a quiet
  progress count and one "N extensions installed" toast. No list to step through.
- Extensions are consolidated first: one copy of each across browsers and profiles, and none
  that are built in, turned off everywhere, retired or already installed.
- Extensions' welcome pages open unselected at the bottom of Today; ReArc's own welcome page
  stays in front.
- Importing again never duplicates anything. Sources already brought over say "Imported",
  and only new items come over.
- Arc's bookmarks no longer come in as an extra space that repeats your sidebar.
- The Import window's Spaces & Sidebar pane shows what came over.

**Sidebar**
- Closing a pinned tab ("—", Close and Keep Pinned, ⌘W) unloads it without opening the next
  pinned tab in the folder.
- Folders show an open-folder icon when expanded and slide open and closed, as in Arc; a
  folder holding a loaded tab shows "•••" and offers Close This Folder.
- The close button sits on a rounded chip: "—" for pinned tabs, × for Today tabs.

**Developer tools**
- ⋮ › Dock side: right, left, bottom or a separate window, remembered between uses.
- The device toolbar (⌘⇧M) works docked and in a separate window.

**Windows**
- ⌘W closes About, Settings, Import and the developer tools window when they are in front,
  instead of the tab behind them.
- The About window's sting and text no longer overlap.
- The DMG window leaves room for Finder's path bar and status bar.

**Reliability**
- A page capture and the toolbar colour sampling no longer collide.

## ReArc 0.1.0 (469) — 2026-11-09

First notarized alpha, distributed as a Developer ID signed DMG.

- About ReArc, first in the ReArc menu, with the ReArc sting, version, Chromium engine
  version and copyright, and links to the Chromium credits.
- chrome://credits opens in ReArc with Chromium's open source licences.
- Automatic updates through Sparkle: ReArc › Check for Updates…, with an "Update Available"
  badge, from https://rearc.imara.ae/updates/appcast.xml.
- Developer ID signing, notarization and a signed DMG.
