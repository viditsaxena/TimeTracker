# TimeTracker

I wanted one key to start a timer and the same key to stop it. I also wanted to keep work time and music time apart. That's what TimeTracker does.

Press **Option–Space** to start or stop the timer, even when you're in another app. Every new timer starts as **Work**. If you're doing music, click the timer in the menu bar and choose **Music**. You don't have to stop the timer first. TimeTracker saves the work part and starts a music part right away. The next time you start a timer, it goes back to Work.

## Get it on your Mac

[Download the latest version](https://github.com/viditsaxena/TimeTracker/releases/latest). Choose the **TimeTracker ZIP** under Assets. The source code ZIPs are for people who want to build the app themselves.

You need **macOS 14 or newer**. The download includes versions for Apple Silicon and Intel Macs. I've tested it on Apple Silicon, but not on an Intel Mac yet.

1. Unzip the download and move **TimeTracker.app** to **Applications**.
2. Open it and press **Option–Space** when you want to start or stop tracking.

Apple hasn't verified this app, so your Mac may stop you the first time you open it. If you trust the download, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple explains this here](https://support.apple.com/en-us/102445). A work or school Mac may not let you make that choice.

If Option–Space opens Spotlight instead, turn that shortcut off in **System Settings → Keyboard → Keyboard Shortcuts → Spotlight**. If some other app uses the keys, you'll need to change its shortcut. You can always use the button in TimeTracker instead.

## What you'll see

When the timer is off, you'll see a timer icon in the menu bar. When it's running, you'll see the time next to a briefcase for Work or a music note for Music. Click there to switch between them, add missed time, or open the TimeTracker window.

The window shows your Work and Music time separately. Each day has two bars, and you can look back at earlier weeks. Hover over a bar to see the exact time. You can also see each session and export your sessions as a CSV file. The CSV uses UTC for its dates and times.

If you forgot to track a few minutes, find the session and click **+5m**, **+10m**, **+15m**, or **+20m** right there. The time is added to that session in one click. The totals and bars update too. You can click again to add more. If that would run into another session, TimeTracker will tell you on the same row.

If you got more than the duration wrong, click the session itself. You can change when it started, how long it lasted, and whether it was Work or Music. For the duration, type minutes like `45`, or hours and minutes like `1:30`. You can also type hours, minutes, and seconds like `0:45:30`. Click **Save** when you're done. TimeTracker won't save an edit that overlaps another session.

If there's no session to add to, click **Add missed time** in the window or menu bar. Pick when you finished and whether it was Work or Music, then click **5 min**, **10 min**, **15 min**, or **20 min**. That click saves a new session. You can also type a different duration and click **Add**. TimeTracker puts the new block before the end time you chose and won't add it on top of another session.

Closing the window leaves TimeTracker running in the menu bar. Quitting the app, putting your Mac to sleep, or switching users stops the timer. It won't start again on its own. If the app closes unexpectedly, it recovers time through its last save, which happens about every 30 seconds. A session that crosses midnight or a week boundary counts toward the right days and weeks.

Your sessions stay on your Mac in `~/Library/Application Support/TimeTracker/sessions.json`. The app doesn't need an account, an internet connection, or permission to watch your keyboard. The GitHub download doesn't contain anyone's sessions. Sessions from older versions count as Work.

To have TimeTracker open when you log in, add it in **System Settings → General → Login Items & Extensions**. When you install a new version, quit the old one first. Replacing the app won't remove your saved sessions.

## Build it yourself

Install Apple's Command Line Tools, then run:

```sh
bash build.sh
open build/TimeTracker.app
```

This builds one app for both Apple Silicon and Intel Macs. To run the checks and make a ZIP with its SHA-256 checksum, run `bash package.sh`. To run just the checks, run `bash test.sh`.

For now there are only two kinds of time, Work and Music. You can't add more categories, sync between Macs, or get automatic updates yet. If your Mac stays awake and you stay signed in, the timer keeps going until you stop it.
