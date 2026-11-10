# Manual download checks

`ABSDownloads` runs every part download in one background `URLSession` with the
identifier `org.davidjensenius.Audiobookshelf.downloads`. The system process
`nsurlsessiond` owns those transfers, not the app. The package tests use an ephemeral
session with a stub `URLProtocol`, because background sessions don't support custom
protocols. Run these checks on a real device (and once on the Simulator) before a
release that changes downloads, the session identifier, or the app's scene setup.

These checks need the app to create a `DownloadEngine` at launch (the composition
root, P4-02). Until then `DownloadEngine.handleBackgroundEvents()` returns at once and
the events wait in `nsurlsessiond`.

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
   session, moves the file, updates the store, and only then lets the handler return.
6. Open the app. Check that:
   - the part shows as completed and nothing restarts;
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
     user force quit reason, and the engine queues the part again straight away. A
     force quit doesn't count as a failure and doesn't wait for a retry delay;
   - if the server supports range requests, the transfer continues from the resume
     data rather than from 0% (watch the first progress value). Resume data is stored
     encrypted in `ResumeData/` and deleted as soon as the new task starts;
   - if there was no resume data, the part starts again from 0%;
   - the part completes and its file is in `Downloads/` as in (a).

Repeat (b) after signing out and back in, or after changing the server's custom headers.
The old resume data was made with the old credentials, so the engine must throw it away
and start the part from 0%.

## macOS

macOS doesn't suspend apps, so transfers continue while the app is open, even in the
background. The app doesn't rely on being relaunched in the background on macOS. Check:

1. Start the 500 MB download, then quit the app with ⌘Q.
2. Wait a minute, then open the app again.
3. The part either completes (the transfer kept running and the engine collects the
   result when it recreates the session at launch) or continues from resume data or
   from 0%. It must never stay stuck as "downloading" with no task.

Builds without the App Group entitlement (the ad-hoc macOS build) create the session
without `sharedContainerIdentifier`. Downloads still land in the app's own Application
Support folder.

## Known limits

- Background sessions follow redirects without asking the app, so the request headers,
  including the server's custom headers, may reach the redirect target. If the final
  response comes from a different origin, the engine fails the part for good and never
  moves the body into `Downloads/`. If a server you support redirects downloads
  to another host, test with it.
- A 401 response triggers one token refresh and one new task. A second 401 fails the
  part.
