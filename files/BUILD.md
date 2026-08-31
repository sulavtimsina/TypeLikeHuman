# Fancy Keyboard — building it locally

You need Xcode and its command line tools. A free Apple ID is enough; there is no paid developer account required for something you only run yourself. You also need XcodeGen, which is what turns the small project.yml in the folder above this one into an Xcode project, so nothing has to be clicked together by hand and the project can be regenerated at any time. Install it with `brew install xcodegen` if `which xcodegen` comes up empty.

## Making the project

The layout is one folder containing project.yml with this `files` folder beside it, holding AppDelegate.swift, TypingEngine.swift and this document. From the folder containing project.yml, run `xcodegen generate`. That writes FancyKeyboard.xcodeproj and a FancyKeyboard/Info.plist next to it. Both are generated output; if you change project.yml, run xcodegen again and they are rebuilt from scratch, so never edit them directly.

## What project.yml sets

The file declares a single macOS application target called FancyKeyboard with the two Swift files from this folder as its sources. The deployment target is macOS 13.0, since the code uses SF Symbols and modern AppKit APIs, and the bundle identifier is com.fancykeyboard.app. Code signing is set to Automatic, which without a Team configured falls back to ad-hoc "Sign to Run Locally" signing; that is fine for a build you only run on your own machine.

The Info.plist is generated from the `info` block. It sets LSUIElement to true, which keeps the app out of the Dock and the app switcher so it exists only as the menu bar icon. There is deliberately no NSMainStoryboardFile key: the app has no storyboard, and if that key is present AppKit tries to load a storyboard that does not exist and crashes on launch. If you ever add settings to the plist, do not add that one.

App Sandbox is off (ENABLE_APP_SANDBOX is NO) and the target has no entitlements file. A sandboxed app cannot post keyboard events into other applications, so the sandbox has to be off for this to work at all. Hardened Runtime is also off, which keeps the debug build simple.

## Building

Run `xcodebuild -project FancyKeyboard.xcodeproj -scheme FancyKeyboard -configuration Debug build`. The built app lands in Xcode's default DerivedData location under ~/Library/Developer/Xcode; `xcodebuild -showBuildSettings` prints BUILT_PRODUCTS_DIR if you want the exact path. You can equally open FancyKeyboard.xcodeproj in Xcode and press Run.

One thing that bites if the project lives in a folder synced by iCloud Drive or another file provider, as Documents often is: if you point `-derivedDataPath` at a folder inside the project, the sync client stamps Finder metadata onto the freshly built bundle and codesign fails with "resource fork, Finder information, or similar detritus not allowed". Leave the build products in the default DerivedData location and this does not happen. Relatedly, if the Swift files arrived with a quarantine attribute (a download, an AirDrop, a file saved by another app), `xattr -cr files` clears it before the first build.

## First run

Launch the app with `open` on the built bundle, or Run from Xcode. The keyboard icon appears in the menu bar and macOS shows a dialog asking to allow the app to control your computer. Open System Settings → Privacy & Security → Accessibility, unlock it, and switch Fancy Keyboard on. You will probably need to quit and relaunch the app afterwards for it to notice.

One thing that will bite you: the Accessibility grant is tied to the app's code signature. If you rebuild after changing the signing identity or the bundle identifier, macOS treats it as a different app and you have to remove the old entry from that list and add the new one. With ad-hoc signing the signature also changes on every rebuild, so after each build you may need to toggle the entry off and on again, or remove it and re-add the new bundle. If typing silently does nothing after a rebuild, that is almost always the cause.

## Using it

Copy some text. Click into the field where you want it. Left-click the menu bar icon: after a silent five second pause, the clipboard is typed out. Press Escape at any point to stop, or click the icon again.

Right-click the icon for the menu. The gauge submenu sets words per minute from 30 to 70, and the cross submenu sets what share of characters get a wrong key first, from none up to 30%.

## The Hubstaff countdown icon

Next to the keyboard icon there is a second item showing 10. Click it and a ten minute countdown starts: the number drops once a minute, and when it reaches 0 the app stops the Hubstaff timer if it is running, using Hubstaff's scripted control CLI (see https://support.hubstaff.com/what-is-scripted-control/ — the `HubstaffCLI stop` command inside the Hubstaff app bundle). Clicking the number again while it is counting cancels the countdown and resets it to 10.

Because the CLI ships inside Hubstaff.app itself, this works unchanged on any machine you clone and build this on — the app looks for Hubstaff in /Applications and ~/Applications and falls back to a Spotlight search, so there is nothing to configure. The first time the stop fires on a machine, Hubstaff pops up a dialog asking whether to allow scripted control; choose "Always allow" and it never asks again. If Hubstaff isn't running when the countdown hits zero, nothing happens, which is the point — there is no timer to stop.

## Where to change the behaviour

Everything about the rhythm lives in TypingEngine.Profile and the two timing functions below it. The delay function is a lognormal draw around the mean interval derived from words per minute; raising jitter makes the typing more erratic, lowering it makes it more mechanical. trailingPause adds the extra beat after sentence and clause punctuation. The hesitation logic in the main loop adds the longer occasional pauses.

The typo behaviour picks a key physically adjacent on a QWERTY row, types it, waits, backspaces, waits again, then types the right one. Adjust the three random ranges there if the correction feels too fast or too slow.

## Known limits

Password fields and terminals with secure input enabled block synthetic events entirely. The app checks for this before starting and tells you rather than typing into nothing.

Some applications, particularly Java-based ones and certain remote desktop clients, handle Unicode key events oddly. If a target app drops characters, the fix is usually to slow the typing down and lengthen the key hold time in the emit function.
