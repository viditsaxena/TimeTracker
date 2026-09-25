# TimeTracker

A small native macOS menu-bar app for keeping Work and Music time separate. Press **Option–Space** anywhere to start or stop a session.

## Download

[**Download TimeTracker for Mac**](https://github.com/viditsaxena/TimeTracker/releases/latest/download/TimeTracker-v1.0.0-macOS-universal.zip) · [All releases](https://github.com/viditsaxena/TimeTracker/releases)

Requires **macOS 14 Sonoma or later**. The app includes Apple Silicon and Intel binaries. It has been tested on Apple Silicon; the Intel build has not been tested on Intel hardware.

1. Download the ZIP, unzip it, and drag **TimeTracker.app** into **Applications**.
2. Open TimeTracker. This release is not Apple Developer ID signed or notarized, so macOS may block the first launch. If you trust the download, try opening it once, then use **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).
3. Press **Option–Space** to start or stop. If Spotlight or another app uses that shortcut, disable its assignment first. For Spotlight: **System Settings → Keyboard → Keyboard Shortcuts → Spotlight**.

Click the menu-bar timer to choose Work/Music or **Show TimeTracker**. Closing the dashboard keeps the app and shortcut running. To open the app automatically when you log in, add it in **System Settings → General → Login Items & Extensions**. Quit the app before installing an update; replacing the app preserves your saved sessions.

## Features

- Every new timer starts as **Work**. While tracking, click the menu-bar timer and choose **Music** (or Work) to switch. Switching saves the current portion and immediately continues in the chosen category. Stopping and starting again always resets to Work.
- While tracking, the menu bar shows elapsed time with a briefcase for Work or a music note for Music. When paused it shows only a timer icon, with no time displayed.
- Separate Work and Music daily/weekly totals, two bars per day, and category labels in session history. Hover a bar for its exact duration. Older sessions count as Work.
- Browse previous weeks and export all completed sessions as CSV (UTC timestamps and a category column).
- Sessions crossing midnight or week boundaries are allocated to the correct days and weeks.
- Timer stops on system sleep, user switching, and normal app quit. It does not automatically resume.
- Active time is checkpointed every 30 seconds. After an unexpected exit, recovery stops at the last checkpoint so downtime is not counted.
- Data stays in `~/Library/Application Support/TimeTracker/sessions.json`. No account or network access needed.

The global shortcut uses the macOS hot-key API; no Accessibility or Input Monitoring permission is required. If another app has claimed the shortcut, use the on-screen or menu-bar button. No personal session data is included in the repository or release download.

## Build and run

With Apple's Command Line Tools installed:

```sh
bash build.sh
open build/TimeTracker.app
```

For everyday use, copy the built app into your Applications folder and open it there. To start it automatically, add TimeTracker in System Settings → General → Login Items & Extensions.

The build produces a universal app for Apple Silicon and Intel. To run tests and build the release ZIP and checksums:

```sh
bash package.sh
```

## Verify

```sh
bash test.sh
```

This MVP tracks Work and Music. It does not yet include custom projects, manual session edits, idle detection, or syncing. If your Mac remains awake, the timer continues until you stop it.
