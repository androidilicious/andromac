# AndroMac

Use your Android phone from your Mac. AndroMac links the two over your own Wi-Fi: no account, no cloud
server, nothing leaves your network.

- **Phone screen on the Mac** in its own window, with mouse, keyboard and sound, while the phone's display stays dark
- **Phone apps in their own Mac windows**
- **Notifications** on the Mac, with reply and dismiss
- **Text messages (SMS)**: read, reply, start new ones
- **Clipboard** shared both ways
- **Files** both ways by drag and drop, and **photos** to browse and save
- **Contacts**, and the **phone camera as a webcam** preview

It is two apps: one for macOS 14 or later, one for Android 11 or later.

**Download:** [AndroMac for Mac](https://github.com/androidilicious/andromac/releases/latest/download/AndroMac-mac.zip) · [AndroMac for Android](https://github.com/androidilicious/andromac/releases/latest/download/AndroMac-android.apk) · [all releases](https://github.com/androidilicious/andromac/releases)

## Set up

Allow about ten minutes the first time. Steps 1 to 4 give you notifications, messages, clipboard, files and
photos. Step 5 adds the phone screen and app windows.

### 1. Install the Mac app

Download [AndroMac-mac.zip](https://github.com/androidilicious/andromac/releases/latest/download/AndroMac-mac.zip) (or build it, see [Build](#build)), unzip it and move
`AndroMac.app` to Applications. The app is not notarized by Apple, so run this once in Terminal before opening it:

    xattr -dr com.apple.quarantine /Applications/AndroMac.app

Open it and allow **local network access** and **notifications** when macOS asks. It shows a QR code.

### 2. Install the phone app

Download [AndroMac-android.apk](https://github.com/androidilicious/andromac/releases/latest/download/AndroMac-android.apk) on the phone and open it. Android asks you to allow installs from your browser or
file manager; allow it and tap **Install**. If Play Protect warns about an unknown developer, choose
**Install anyway**.

### 3. Pair

Put both devices on the same Wi-Fi. On the phone, open AndroMac and tap **Scan the QR code on your Mac**.
The code holds the encryption key, so do not share a screenshot of it. Pairing is remembered; from now on the
two link by themselves whenever they are on the same network.

### 4. Turn on the phone features

In the phone app, under **Set up**, tap each row until it shows a tick:

- **Permissions**: allow messages, photos, contacts and camera.
- **Notification sync**: switch AndroMac on in the list that opens.
- **Remote control**: switch on "AndroMac remote control" under Accessibility. Only needed for cast mode.

If Android shows these switches greyed out with "Restricted setting": open Settings > Apps > AndroMac, tap the
three dots at the top right, choose **Allow restricted settings**, and try again. Step 5 removes this block
for you, so you can also do step 5 first.

### 5. Phone screen and app windows (one-time USB setup)

Phone makers give this kind of access only to apps they build in. For everyone else, Android's developer
option "USB debugging" is the supported way to let a computer you trust control the phone. AndroMac uses it
through the open-source [scrcpy](https://github.com/Genymobile/scrcpy) tool.

On the Mac, install the two tools (needs [Homebrew](https://brew.sh)):

    brew install scrcpy
    brew install --cask android-platform-tools

On the phone:

1. Open **Settings > About phone** (on Samsung: then **Software information**) and tap **Build number** seven
   times. The phone says you are now a developer.
2. Open **Settings > Developer options** (on some phones under **System**) and switch on **USB debugging**.
3. Connect the phone to the Mac with a USB cable.
4. The phone asks **Allow USB debugging?** Tick **Always allow from this computer** and tap **Allow**.

On the Mac, open AndroMac, go to **Phone Screen** and press **Check again**. When it shows **Ready** you can
unplug the cable. Press **Open phone screen**.

What this setup does, so there are no surprises:

- It switches the phone to wireless debugging, so the cable is only needed this once.
- It lets the phone app switch wireless debugging back on after the phone restarts.
- It lifts the "Restricted setting" block from step 4.
- It makes the clipboard two-way without tapping anything on the phone.

Security: wireless debugging stays on while the phone is linked. Other devices on your network can try to
connect, but the phone only accepts computers you approved on the "Allow USB debugging" prompt. To undo
everything, switch off USB debugging in Developer options.

### Everyday use

- Open the phone screen from **Home** or **Phone Screen**. While that window is open the Mac keeps the phone
  awake with its own display dark. If the phone is locked you see the lock screen; type your PIN in the window.
  Closing the window gives the display back and the phone locks as usual.
- **Apps** opens one phone app per Mac window.
- **Cast instead** in Phone Screen works without step 5, but Android asks for permission every time and the
  phone's screen must stay on.
- From the phone, share anything to **Send to Mac**, or use the app's Clipboard and Files tiles.

### If something does not work

| Problem | What to do |
|---|---|
| Mac app shows the QR code and never connects | Check both devices are on the same Wi-Fi and that it is not a guest network that isolates devices. Open the phone app once. |
| Phone Screen says it needs setup again after a phone restart | Unlock the phone and wait a few seconds; the phone app switches wireless debugging back on. If it stays that way, plug in the cable once and press **Check again**. |
| "The phone is plugged in but has not allowed this Mac" | Unlock the phone and tap **Allow** on the USB debugging prompt. If no prompt appears, unplug and plug in again. |
| Phone window opens and closes immediately | Press **Check again** in Phone Screen. Make sure `scrcpy` is installed. |
| Notifications or accessibility show as denied | See "Restricted setting" in step 4. |
| Copying on the phone does not reach the Mac | That needs step 5. Without it, use the **Clipboard to Mac** Quick Settings tile. |
| No messages listed | Tap **Permissions** in the phone app again. Only SMS is supported, not RCS chats. |

## How it works

| Feature | Phone side | Mac side |
|---|---|---|
| Pairing | Scan QR code | Shows QR code |
| Notifications, with reply and dismiss | Notification listener | Notification Center + list |
| Text messages (SMS) | SMS store + SmsManager | Conversation list and composer |
| Clipboard, two-way | Clipboard watcher run over adb; otherwise Quick Settings tile, "Send to Mac", share sheet | Automatic on copy |
| Files, both directions | Share sheet or file picker | Drag and drop, menu bar |
| Photos | MediaStore | Thumbnail grid, full-size viewer, save to Downloads |
| Contacts | Read-only | Searchable list |
| Phone screen and app windows | USB debugging (adb) | Separate windows through scrcpy |
| Phone screen, cast | MediaProjection + H.264 | Live view in the app |
| Control of the cast screen | Accessibility service | Click, drag, scroll, type |
| Phone as webcam | Camera2 + H.264 | Preview + virtual camera extension |

Everything travels over one encrypted connection on the local network. See [PROTOCOL.md](PROTOCOL.md).

## Status

This is an early project. Both apps build cleanly and have been used together on one Samsung phone
(Android 17) and one Mac, and tested more methodically on an Android 14 emulator.

Tested on the emulator: pairing, clipboard both ways, files both ways, photos, notification sync and dismiss,
SMS list, read, send and live update, screen cast and camera video arriving, reconnecting after a reboot,
and opening an app window in native mode.

Checked on the real phone: pairing by QR code, casting, keeping a locked phone awake with its display dark,
the clipboard watcher, and switching wireless debugging back on by command.

Not yet tested: a full phone restart followed by a cable-free reconnect, typing into the cast screen,
notification replies, and the virtual webcam. Expect rough edges and please report them.

## Build

**Mac, quickest** (only the Xcode Command Line Tools are needed):

    cd mac && ./build.sh install     # builds, copies to /Applications, launches

This gives everything except the virtual webcam, which needs the Xcode route below.

**Android** (JDK 17 and the Android SDK 34; the Gradle wrapper fetches Gradle 8.9):

    cd android && ./gradlew assembleDebug
    adb install -r app/build/outputs/apk/debug/app-debug.apk     # phone plugged in with USB debugging on

Or copy `app-debug.apk` to the phone and open it (allow installs from your file manager).

**Mac with Xcode** (Xcode 15.3+ and XcodeGen, needed for the virtual webcam):

    brew install xcodegen
    cd mac && xcodegen && open AndroMac.xcodeproj

**GitHub Actions.** The workflow in `.github/workflows/build.yml` builds both apps on every push and
attaches them to the run as artifacts.

## The virtual webcam

The camera preview works in any build. Showing up as a camera in Zoom, Meet or FaceTime needs the
system extension, which macOS only loads when:

- you have a paid Apple Developer account and set `DEVELOPMENT_TEAM` in `mac/project.yml`,
- the app is built and signed from Xcode on your Mac, and
- `AndroMac.app` is in `/Applications`.

Then: start the phone camera, click **Install virtual camera**, approve it in System Settings,
and click **Feed virtual camera**.

## Known limits

- Android only lets the app in front read the clipboard. With the USB setup the Mac runs a small watcher under the debugging shell, which is allowed to, so phone copies arrive by themselves. Without it, phone-to-Mac clipboard takes one tap.
- Cast mode: Android asks for consent every time, and the picture does not follow screen rotation. Stop and start again after rotating.
- Hold the phone in landscape for the camera. Portrait is sent sideways.
- Typing rewrites the focused text field, which some apps (games, custom editors) ignore.
- Messages covers SMS only. MMS, group chats and RCS chats do not appear, and there is no calling from the Mac.
- The Mac keeps the pairing key in `~/Library/Application Support/AndroMac/pairing-key`, readable only by your user.
- Works only when both devices can reach each other on the same network. See PROTOCOL.md if you add a relay later.

## Layout

    android/   Kotlin app (min Android 11)
    docs/      the project website (GitHub Pages)
    mac/       Swift app + camera extension (macOS 14+), generated with XcodeGen
    tools/     protocol interoperability test
    PROTOCOL.md

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

You may use, change and redistribute this, including commercially, as long as you keep the copyright and
NOTICE file (the attribution to the original author) and say what you changed.
