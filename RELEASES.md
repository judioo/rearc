# ReArc releases

Every distributed build (a DMG or an update in the appcast) has an entry here, newest
first. The entry lists everything that changed since the previous release, written for
the people who use ReArc. `shell/scripts/release.sh --dmg` refuses to build until the
committed `RELEASES.md` has a heading for the build it is about to make:

    ## ReArc <VERSION> (<build>) — <YYYY-MM-DD>

`<build>` is the commit count of the commit that adds the entry, so write it as the last
commit before the release, with `echo $(( $(git rev-list --count HEAD) + 1 ))` as the
number. Details: engine/docs/RELEASE.md, "Release notes".

## ReArc 0.1.0 (677) — 2026-11-12

**New**
- Peek looks and works like Arc's. ⇧-click a link and it opens in a borderless card over the
  page, with three round buttons floating at its top right: close, expand into a tab, and open
  in Split View. Click anywhere outside the card, the sidebar included, and it closes. Esc
  closes it too. Expand (or ⌘O) keeps the page as it is: the same scroll position, what you
  typed, and its back history.
- Select several tabs. ⌘-click adds or removes a sidebar row and ⇧-click selects a range; the
  tab you are on is part of the selection. Right-click the selection for Copy Links, Copy
  Links as Markdown, Pin, Unpin, Add to Favorites, Duplicate, Open in Split View, Move to
  Folder, New Folder with Selection, Move to Space and Archive. Move to Profile sends the
  selection to a space of another profile, after one confirmation that says what stays behind
  (cookies and sign-ins). ⌘C and ⇧⌘C copy the selection's links one per line and ⌘W closes
  the whole selection. Drag one selected row and the rest come with it. Esc clears the
  selection.
- Mini sidebar. ⇧⌘S shrinks the sidebar to a column of site icons, in the same order as the
  full sidebar; ⇧⌘S again brings the full sidebar back. ⌘S still hides and shows the sidebar,
  and a mini sidebar comes back mini. Each window remembers its own mode. View › Show Mini
  Sidebar does the same.

**Changed: Sync Sidebar is off by default**
- 608 switched Sync Sidebar on by itself after onboarding. If your iCloud already held a ReArc
  sidebar from an earlier install, that sidebar was merged into what you had just imported,
  without a word. ReArc no longer turns sync on by itself, on a new install or an existing
  one.
- If Sync Sidebar was on in 602, 605 or 608, it is off after this update, whether ReArc or you
  switched it on: those builds did not record which. Nothing on your Mac or in iCloud is
  changed by that. If you sync between Macs, turn it on again in Settings › Account on each.
- Turning it on looks first. Settings › Account › Sync Sidebar reads what is in iCloud before
  anything is merged. If iCloud already has a ReArc sidebar, a sheet says so, with how many
  spaces, pinned tabs and favorites it holds, and warns that it can change what is on this
  Mac, including what you just imported. You choose: use the iCloud sidebar on this Mac,
  replace what is in iCloud with this Mac's sidebar, merge both, or cancel. Each of the first
  three saves this Mac's sidebar to a backup file before it changes anything. Cancel is the
  default and changes nothing.
- Manage what is in iCloud. Settings › Account has a new "Sidebar in iCloud" box that shows
  what iCloud holds and when it was last edited, with Use on This Mac…, Replace iCloud with
  This Mac… and Delete iCloud Content…. Reading a large sidebar can take half a minute or
  more; the box shows progress while it reads.

**Fixes**
- Imported spaces no longer look empty, and Arc spaces are no longer duplicated. Up to 608,
  every install imported each Arc space as a new space, and merging with iCloud left several
  copies of one space, only one of which held the tabs. Switching between spaces landed on
  the empty copies, so it looked as if the tabs were gone. They were not. On first launch this
  build merges the copies of each Arc space into one and keeps every tab. Your sidebar file
  is saved first, beside the original, as `sidebar.before-arc-twin-repair-<time>.json`. From
  now on, importing the same Arc space on two Macs, or twice, gives one space.

**Security**
- The engine is updated to Chromium 156.0.8078.100, Chromium's latest security update for
  the 156 line.
- A shipped ReArc no longer accepts a data folder, a profile folder, the self-test or the
  launch probe from the command line or the environment, so another program cannot start
  your ReArc on a folder of its choosing.
- Sync uploads a pinned tab's saved address, never the page you happen to have open in it,
  and only web pages become synced tabs. A first join keeps iCloud's copy of rows it already
  has, and records that cannot be valid are set aside instead of applied.
- Boost CSS is checked the way the engine reads it, and CSS that arrives in a Boost file waits
  for your review. A Boost with no approval record approves nothing.
- Importing from other browsers opens no links, stays inside the browser's own folder, and
  limits how deep and how large a bookmarks file it reads.
- A shipped ReArc ignores the engine trace switch, so a program that starts ReArc cannot make
  it write page addresses and titles to a file of its choosing.
- A release build clears the TLS key log and Google key overrides from its environment before
  the engine starts.
- The Delete Profile dialog says when a container's browsing data stays on disk, and a deleted
  container that comes back through sync is not deleted again at the next launch.

**Known**
- ⇧⌘S was Save Page As in Arc. ReArc never had Save Page As, and the keys now toggle the mini
  sidebar.
- ⇧⌘T after ⌘W on a selection can take two presses: the tab you were on comes back first,
  then the rest together.
- Using or merging the iCloud sidebar on a second Mac can put spaces in a profile that is new
  on that Mac. Sites then ask you to sign in again there, and the cookies and history of the
  profile those spaces were in stay on disk, where ReArc no longer shows them. The sheet warns
  about the sign-ins. Replace keeps no copy of what iCloud held.


- A page that adds history entries from script, without a click, gets no Back entry for them
  in a Peek or after Expand, as in Chrome.
- For sites opened in 605, their older local storage is still on disk but not yet restored
  (see 608).

## ReArc 0.1.0 (608) — 2026-11-11

This build replaces 605 and 602, which were both withdrawn within about an hour of release.

**If you installed 605**
- 605 lost website data on profiles made by earlier builds: sites' local storage read as
  empty, and a site's IndexedDB data was deleted the first time you opened that site in 605.
  Cookies and sign-ins that rely on them were not affected.
- This build stops the loss. Sites you did not open in 605 have all their data. For sites you
  did open, what they stored before 605 in IndexedDB is gone; their older local storage is
  still on disk but not yet restored.

**Fixes since 605**
- Website data made by builds 500, 544 and 564 reads back again. The engine runs with the
  same feature set those builds used, with one change: Safe Browsing uses the list protocol
  Google serves, so the threat lists arrive.
- HTTP cache and connection partitioning, which 602 and 605 had switched off, are on again.
- ReArc opens on profiles made by earlier builds. 602 quit at launch on them; if 602 will not
  open, install this build over it.
- Every release now has to read back, in the new build, website data stored by the release
  before it.

**New**
- Your Arc card comes with you. Settings › your name › Import Your Card from Arc brings over
  your Arc membership card: its title, shape and colours, and your Arc member-since date. The
  card plays an Arc to ReArc transition that you can replay, and the import is offered again
  after Randomize. From Arc's sign-in file ReArc reads only the account's creation date and
  name.
- Onboarding finds all your browsers. The browser step now lists every browser on your Mac,
  including the ones macOS keeps private: Chrome, Brave and Safari show as Locked, with one
  Allow access… button that opens System Settings beside the onboarding. Switch ReArc on (a
  small panel gives you the ReArc icon to drag in if it is not listed), come back, and they
  turn to Found. If macOS reopens ReArc, the onboarding resumes at the same step. The Import
  window works the same way.
- More browsers to import from: Chrome Beta, Dev and Canary, Brave Beta and Nightly, Edge,
  Vivaldi, Opera, Opera GX and Chromium, plus Safari (bookmarks, Reading List and history) and
  Firefox (bookmarks and history). Passwords and cookies are still never read.
- Manage Extensions: the site control panel has a Manage link beside the "+" that opens the
  Chrome Web Store, and every extension tile's right-click menu has Manage Extensions….
- Sync Sidebar is on by default once onboarding finishes, when you are signed in to iCloud. If
  you turned it off, it stays off. Sync problems show a plain message, with the technical text
  under Details.
- Little Arc is now called Little ReArc.

**Security**
- Safe Browsing now works. Builds 544 and 564 said it did, but their engine never received
  Google's threat lists, so they showed no phishing or malware warnings. The engine no longer
  runs Chromium's test configuration, the lists arrive within a few minutes of first launch,
  and Settings › Profiles shows the real state: Starting, On, Not working or Out of date. A
  release cannot be built unless a test launch receives the lists.
- With the address bar auto-hidden, it shows for three seconds whenever you arrive at a
  different site, and stays while a permission, sign-in or certificate prompt is up.
- A popup or new tab opened from a Little ReArc in another container opens in that container,
  under its own badge. Links, searches, Boosts and command-bar history no longer cross
  containers. Deleting a container closes its Little ReArcs and removes its data.
- Boost CSS needs your approval on each Mac, like Boost scripts, and can no longer load
  anything from the web. Approving a script shows its code first, and a script runs only if
  the code is what you approved.
- Extension install and permission sheets appear one at a time, and Return always cancels.
- A release build no longer runs its self-test against your real profile.

**Fixes**
- Sidebar text is readable on every space colour. On mid-tone and vivid themes the space
  name, New Tab and icons were almost the colour of the sidebar.
- Syncing Boosts no longer fails with "Cannot create new type SidebarBoostRecord", and one
  rejected kind of record no longer holds up everything else waiting to sync.
- Settings › Links shows rearc.imara.ae, and Share ReArc links to it.

## ReArc 0.1.0 (605) — 2026-11-11

Withdrawn. It lost website data on profiles made by earlier builds.

## ReArc 0.1.0 (602) — 2026-11-11

Withdrawn. It quit at launch on existing profiles. Everything it added is in the next build.

## ReArc 0.1.0 (564) — 2026-11-10

Correction, 2026-11-11: Safe Browsing did not work in this build. See the next release.

**New**
- Auto-hide address bar: Settings › Advanced › Auto-hide address bar. The address bar slides
  away when you move onto the page and comes back when the pointer reaches the top of the page
  or you press ⌘L. In split view each pane's bar hides and shows on its own. It is off by default.
- Containers: a space can have its own profile, with its own cookies and sign-ins, so the same
  site can be signed in with different accounts in different spaces. Choose it from the profile
  badge next to the space name, the space menu's Change Profile, or the space's edit sheet.
  Settings › General › New spaces decides whether new spaces share the default profile (the
  default) or get their own container.
- Onboard later: if you choose Onboard later, a card at the bottom of the sidebar and
  ReArc › Finish Setting Up ReArc… bring you back to importing from Arc, Chrome or Brave.
  Closing the card keeps the menu item; importing or choosing Start Fresh removes both.

**Fixes**
- The profile badge next to the space name is legible on every theme, and the profile list is
  never empty: it always shows your profiles, New Profile… and New Container for This Space.
- The New Tab row in the sidebar is easier to read on coloured themes.
- Opening split view while the page has keyboard focus no longer crashes.
- Removing or editing a boost while its page is loading no longer leaves the old boost applied.

## ReArc 0.1.0 (544) — 2026-11-10

Security release candidate. It fixes the findings of the security review of build 500.

**Security**
- The engine moves to Chromium 156.0.8078.96, with 65 security fixes from Google, including
  CVE-2026-125350, which is exploited in the wild. Release builds now refuse an engine that is
  behind Chrome's latest Mac security release.
- Safe Browsing was meant to work from this build: the key and the page checks are in.
  Correction, 2026-11-11: it did not. The engine never received Google's threat lists, so this
  build showed no warnings. The next release fixes it.
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
