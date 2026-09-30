# TimeTracker

I wanted one key to start a timer and the same key to stop it. I also wanted to keep work time and music time apart. Now I can track standing time too, without mixing it into either one.

Press **Option–T** to start Work right away, even when you're in another app. Press it again to stop. There's no project popup now. If you're starting Music, click TimeTracker in the menu bar and choose **Music** instead. You can also choose Music there while Work is running.

If you switch from Work to Music within 10 seconds, TimeTracker drops that little Work block. It also drops any new Work, Music, or standing block shorter than 5 seconds. A block that's exactly 5 seconds is kept. This only affects new blocks; it won't remove anything you've already saved.

If you forget to start a timer but keep moving or scrolling the mouse for three minutes, TimeTracker sends one reminder. Choose **Work +3 min** or **Music +3 min** to start that timer with those three minutes already counted. It won't keep reminding you during the same stretch of mouse activity. Moving the mouse doesn't always mean you're working, so you can ignore the reminder. Your Mac will ask to allow notifications the first time this happens.

## Get it on your Mac

[Download the latest version](https://github.com/viditsaxena/TimeTracker/releases/latest). Choose the **TimeTracker ZIP** under Assets. The source code ZIPs are for people who want to build the app themselves.

You need **macOS 14 or newer**. The download includes versions for Apple Silicon and Intel Macs. I've tested it on Apple Silicon, but not on an Intel Mac yet.

1. Unzip the download and move **TimeTracker.app** to **Applications**.
2. Open it and press **Option–T** when you want to start or stop tracking.

Apple hasn't verified this app, so your Mac may stop you the first time you open it. If you trust the download, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple explains this here](https://support.apple.com/en-us/102445). A work or school Mac may not let you make that choice.

If another app already uses Option–T, you'll need to change that shortcut. You can always use the button in TimeTracker instead. TimeTracker no longer uses Option–Space, so you can turn Spotlight's old shortcut back on if you want.

## What you'll see

When the timer is off, you'll see a timer icon in the menu bar. When it's running, you'll see the time next to a briefcase for Work or a music note for Music. Click there to start Music, switch projects, add missed time, or open the TimeTracker window.

To track standing, click **Stand up** in the window or menu bar menu. Click **Sit down** when you sit. This is a second timer. It can run while you're doing Work or Music, or while neither project timer is running. It doesn't add to your Work or Music hours.

The standing card says **Standing now** or **Sitting now**, so you can tell which state it's in. The menu bar menu says the same thing. Only standing time is counted; sitting isn't a separate timer.

The window shows your Work and Music time separately. Each day still has two project bars. Under them, you'll see standing time for each day. The Today and This week boxes show all three totals separately. You can look back at earlier weeks and hover over a bar or a standing total to see the exact time. You can also see each session and export your sessions as a CSV file. Standing blocks are included as rows marked Standing. The CSV uses UTC for its dates and times.

If you forget to click **Sit down**, click the standing block in the window to fix when it started or how long it lasted. You can delete a standing block there too. Standing blocks can overlap Work or Music, but not another standing block.

If you forgot to track a few minutes, use **− 5 min + Add** near the top of the window. The number starts at 5 and changes in 5-minute steps. Click **Add**, and TimeTracker puts those minutes in the latest open space today. It won't put them on top of time you've already tracked. If a timer is running, it first tries to add the minutes immediately before that timer started. The message below the button tells you where the time went. Work is the default; you can pick Music when the timer is off. If there isn't a long enough gap today, it will tell you.

If you got more than the duration wrong, click the session itself. You can change when it started, how long it lasted, and whether it was Work or Music. For the duration, type minutes like `45`, or hours and minutes like `1:30`. You can also type hours, minutes, and seconds like `0:45:30`. Click **Save** when you're done. TimeTracker won't save an edit that overlaps another session. To remove a session, click the trash icon beside it, then confirm **Delete** on that row.

If the missed time happened at a particular time, click **Choose exact time** in the window or menu bar. Pick when you finished and whether it was Work or Music, then click **5 min**, **10 min**, **15 min**, or **20 min**. That click saves a new session. You can also type a different duration and click **Add**. TimeTracker puts the new block before the end time you chose and won't add it on top of another session.

Closing the window leaves TimeTracker running in the menu bar. Quitting the app, putting your Mac to sleep, or switching users stops both timers. They won't start again on their own. If the app closes unexpectedly, it recovers time through the last save, which happens about every 30 seconds. A session that crosses midnight or a week boundary counts toward the right days and weeks.

Your sessions stay on your Mac in `~/Library/Application Support/TimeTracker/sessions.json`. The app doesn't need an account or an internet connection. It checks how recently you moved or scrolled the mouse, but doesn't record where you pointed or what you typed. The GitHub download doesn't contain anyone's sessions. Sessions from older versions count as Work.

To have TimeTracker open when you log in, add it in **System Settings → General → Login Items & Extensions**. When you install a new version, quit the old one first. Replacing the app won't remove your saved sessions.

## Build it yourself

Install Apple's Command Line Tools, then run:

```sh
bash build.sh
open build/TimeTracker.app
```

This builds one app for both Apple Silicon and Intel Macs. To run the checks and make a ZIP with its SHA-256 checksum, run `bash package.sh`. To run just the checks, run `bash test.sh`.

For now there are only two project categories, Work and Music. Standing is separate. You can't add more categories, sync between Macs, or get automatic updates yet. If your Mac stays awake and you stay signed in, a timer keeps going until you stop it.
