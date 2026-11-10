# Manual download checks

`ABSDownloads` runs every part download in one background `URLSession` with the
identifier `org.davidjensenius.Audiobookshelf.downloads`. The system process
`nsurlsessiond` owns those transfers, not the app. The package tests use an ephemeral
session with a stub `URLProtocol`, because background sessions don't support custom
protocols. Run these checks on a real device (and once on the Simulator) before a
release that changes downloads, the session identifier, or the app's scene setup.

These checks need the app to create a `DownloadEngine` at launch and call `activate()`
each time it comes to the foreground (the composition root, P4-02). The app already calls
`DownloadEngine.deactivate()` when its scene goes to the background. Until an engine
exists, the static `DownloadEngine.handleBackgroundEvents()` waits up to 10 seconds for
one, then returns; the events stay in `nsurlsessiond` for the next session. To pause or
resume a download, the app calls `pause(recordID:)` or `resume(recordID:)`, which set the
record's state before stopping or starting its parts. The engine only starts a part after
`DownloadStore.beginRunning` accepts it, which refuses parts of paused, failed and
completed downloads; a transfer that survived a relaunch is only adopted the same way, and
otherwise cancelled, keeping its resume data.

## Before you start

- Use a server with an item whose audio file is about 500 MB, so the transfer lasts
  long enough to interrupt.
- **Don't keep the debugger attached while the app is in the background.** The
  debugger stops iOS from suspending the app, so you would test a state that users
  never see. Start the app from Xcode and stop it as described below, or start it
  from the Home Screen.
- Watch the logs in Console.app: select the device, filter on subsystem
  `org.davidjensenius.Audiobookshelf` and category `downloads`, and add the process
  `nsurlsessiond` to see the transfers themselves.
- To debug a background relaunch, use **Debug > Attach to Process by PID or Name**,
  enter `Audiobookshelf`, and choose to wait for the process to launch before the
  transfer finishes.

## (a) The system terminates the app during a download

The transfer must keep going without the app, and the system must relaunch the app in
the background when it finishes.

1. Start the 500 MB download and wait until progress shows a few percent.
2. Go to the Home Screen so the app is in the background. Don't open the app switcher.
3. End the process the way the system would, not the way a user would:
   - From Xcode: click **Stop** (⌘.) while the app is in the background. Xcode kills
     the process; iOS doesn't treat that as a force quit.
   - On the Simulator you can also run
     `xcrun simctl terminate booted org.davidjensenius.Audiobookshelf`, or find the
     process with `pgrep -fl Audiobookshelf` and end it with `kill -9 <pid>`.

   **Debug > Simulate Background Fetch** doesn't help here: it tests background app
   refresh, not URL session events.
4. In Console.app, `nsurlsessiond` keeps logging the task. Leave the device alone until
   the transfer finishes.
5. When it finishes, iOS relaunches the app in the background (`sessionSendsLaunchEvents`)
   and runs the `.backgroundTask(.urlSession(...))` handler. The engine recreates the
   session, checks the response (200 or 206, not an HTML, text, JSON or XML error body,
   the expected size), moves the file, records its size, and only then lets the handler
   return. A background wake doesn't restart other queued parts; that waits for
   `activate()` in the foreground.
6. Open the app. Check that:
   - the item shows as downloaded and nothing restarts. Once every part of a download
     has completed, the engine turns it into a local item and deletes the download
     record. If the app stopped between those two steps, the next launch finishes the
     job;
   - the file is at `Library/Application Support/Downloads/<relative path>` in the app
     container (**Window > Devices and Simulators > Download Container**, or
     `xcrun simctl get_app_container booted org.davidjensenius.Audiobookshelf data` on
     the Simulator), and its size matches the server's;
   - `Library/Application Support/ResumeData/` holds no file for that part.

Also try it with the app opened again by hand **before** the transfer finishes. The
engine must find the running task through `getAllTasks`, match it by the part ID in
`taskDescription`, and keep showing progress without starting a second transfer.

## (b) The user force-quits the app

A force quit from the app switcher cancels every background transfer that belongs to the
app. The app must recover the next time it opens.

1. Start the 500 MB download and wait until progress shows a few percent.
2. Open the app switcher and swipe the app away.
3. In Console.app, `nsurlsessiond` cancels the task.
4. Open the app from the Home Screen. Check that:
   - the cancelled task reports `NSURLErrorBackgroundTaskCancelledReasonKey` with the
     user force quit reason, and the engine queues the part again and restarts it at
     once (the cancellations arrive after `activate()`). A force quit doesn't count as a
     failure and doesn't wait for a retry delay; after three such restarts of a part in
     one activation, further ones count as failures with the usual retry delays;
   - if the server supports range requests, the transfer continues from the resume
     data rather than from 0% (watch the first progress value). Resume data is stored
     encrypted in `ResumeData/` and deleted as soon as the new task starts;
   - if there was no resume data, the part starts again from 0%;
   - the part completes and its file is in `Downloads/` as in (a).

Repeat (b) after signing out and back in, after changing the server's custom headers, or
after changing the cellular or Low Data Mode download settings. The old resume data was
made with other credentials or network settings, so the engine must throw it away and
start the part from 0%. The engine always gets current credentials (refreshing the token
if needed) before it resumes a part, so a refreshed token also means a fresh start.

The system can also cancel transfers because Background App Refresh is off
(`backgroundUpdatesDisabled`) or the device is short of resources
(`insufficientSystemResources`). The engine queues the part again without counting a
failure, but doesn't restart it until the next `activate()`, when the app comes to the
foreground: these cancellations happen while the app is in the background. To check the
first, turn off **Settings > General > Background App Refresh** for the app, start a
download, and go to the Home Screen. When you open the app again, the part continues. If
the cancellation only reaches the app after it has come to the foreground and finished
its restart pass, the part waits for the next time the app comes to the foreground.

## macOS

macOS doesn't suspend apps, so transfers continue while the app is open, even in the
background. The app doesn't rely on being relaunched in the background on macOS. Check:

1. Start the 500 MB download, then quit the app with ⌘Q.
2. Wait a minute, then open the app again.
3. The part either completes (the transfer kept running and the engine collects the
   result when it recreates the session at launch) or continues from resume data or
   from 0%. It must never stay stuck as "downloading" with no task.

The session doesn't set `sharedContainerIdentifier`: nothing outside the app reads the
downloads, and they land in the app's own Application Support folder on every platform.

The ad hoc macOS build has no Keychain access group, so the Keychain refuses the
resume-data key with `errSecMissingEntitlement` (-34018). The engine logs this once per
process as a fault (`downloads` category) and doesn't keep resume data, so an interrupted
part starts again from 0%. Downloads still work. A signed build keeps resume data as on
iOS.

## Failures

- The engine only accepts a 200 or 206 response. Another status, an HTML, text, JSON or
  XML body (an error page or message), or a file whose size differs from the expected
  length never reaches `Downloads/`. The exception is a size that matches the length the
  server declared (`Content-Length`, or the total in a 206's `Content-Range`): the file
  changed since the download was planned, so the engine keeps it and records the new size
  as the expected size.
- A 401 triggers one token refresh and one new task for the part. A second 401 in a row
  fails the part. The count starts over once the part gets a successful response, and a
  401 for a token that was already replaced doesn't count.
- 408, 429, 5xx, network errors, an unexpected body or a size mismatch are retried after
  1–2, 2–4, 4–8, 8–16 and 16–32 seconds. If it fails after the fifth retry, the part
  fails.
- A full disk, any other status (such as 404 or 204), or a response from another origin
  fails the part at once.
- If the download's state can't be saved when a part starts, that counts as a failure
  and is retried like the others; after the fifth retry the part fails for good with the
  `store` code.
- When a part fails for good, the engine stops the download's other parts, keeps their
  resume data, and marks the download failed. Starting it again continues those parts.
- If `nsurlsessiond` disconnects the session (`backgroundSessionWasDisconnected`, or the
  session becomes invalid), the engine creates it again after a retry delay (1–2, 2–4,
  then 4–8 seconds) and restarts the affected parts without counting a failure. After
  three attempts without a finished file, it reports the session as lost and waits for
  the next `activate()`.
- If another process holds the session (`backgroundSessionInUseByAnotherProcess`), the
  engine queues the parts, logs a fault, reports it, and creates no session until the
  next `activate()`, which tries once more.
- If the resume data can't be read (the Keychain or the file is unavailable, for
  example while the device is locked), the part starts from 0% without counting a
  failure, and the resume data is kept for a later attempt.

## Known limits

- Background sessions follow redirects without asking the app. `URLSession` drops
  `Authorization` on a redirect, so the bearer token never reaches the target, but the
  server's custom headers may. If the final response comes from a different origin, the
  engine fails the part for good and never moves the body into `Downloads/`. A 401 after
  a redirect fails the part as "redirected, credentials not forwarded" without a token
  refresh. If a server you support redirects downloads to another host, test with it. A
  follow-up issue tracks a foreground redirect check before the background task starts.
