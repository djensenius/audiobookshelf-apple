# Manual download checks

`ABSDownloads` runs every part download in one background `URLSession` with the
identifier `org.davidjensenius.Audiobookshelf.downloads`. The system process
`nsurlsessiond` owns those transfers, not the app. The package tests use an ephemeral
session with a stub `URLProtocol`, because background sessions don't support custom
protocols. Run these checks on a real device (and once on the Simulator) before a
release that changes downloads, the session identifier, or the app's scene setup.

`AppEnvironment` builds the download stack (`AppDownloads`) when it's created, and starts
the manager and controller without a scene, so a CarPlay-only launch or a background
relaunch has an engine. `DownloadsLifecycle` gets every scene phase from the app, in
order: `.active` calls `activate()` and, when that succeeds, sweeps orphaned files;
`.background` calls `deactivate()`. Until an engine exists, the static
`DownloadEngine.handleBackgroundEvents()` waits up to 10 seconds for one, then returns;
the events stay in `nsurlsessiond` for the next session. To pause or resume a download,
the app calls `pause(recordID:)` or `resume(recordID:)`, which set the record's state
before stopping or starting its parts. The engine only starts a part after
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

Repeat (b) after signing out and back in, or after changing the cellular or Low Data
Mode download settings (once #145 allows custom headers, also after changing them). The
old resume data was made with other credentials or network settings, so the engine must
throw it away and start the part from 0%. The engine always gets current credentials
(refreshing the token if needed) before it resumes a part, so a refreshed token also
means a fresh start.

The system can also cancel transfers because Background App Refresh is off
(`backgroundUpdatesDisabled`) or the device is short of resources
(`insufficientSystemResources`). The engine queues the part again without counting a
failure, but doesn't restart it until the next `activate()`, when the app comes to the
foreground: these cancellations happen while the app is in the background. To check the
first, turn off **Settings > General > Background App Refresh** for the app, start a
download, and go to the Home Screen. When you open the app again, the part continues. If
the cancellation only reaches the app after it has come to the foreground and finished
its restart pass, the part waits for the next time the app comes to the foreground.

## (c) Sign-out, removal and a CarPlay-only launch

Signing out, an expired session or removing a server pauses that connection's queued and
running downloads, then deletes its resume data (ADR 0003). The paused downloads stay
paused after signing back in.

The clean-up (`DownloadEngine.quiesce(connectionID:pausing:)`) pauses the records, attaches
to the session, stops every transfer of the connection and waits for failures being handled
before deleting the resume data; meanwhile a failure's replay doesn't queue a record again.
A removal runs it once the Keychain items are deleted and before the store removes the
server (`AccountManager.credentialsRemoved`), so a failed removal keeps the downloads'
progress. A new sign-in to the same server waits for a clean-up still running (a wait over
5 seconds is logged). One that found no session still deletes the resume data, cancels the
connection's transfers that survived a relaunch once the session is created, and is
retried at the next activation unless the server is signed in to first. Nothing is
activated until the download folders are prepared.

1. Start the 500 MB download, then sign out from the Account tab. Check that the
   download shows as paused, `nsurlsessiond` cancels the task, and `ResumeData/` holds
   nothing for it.
2. Sign in again. The download stays paused; resume it and check that the part starts
   from 0%.
3. With two servers, start a download on the inactive one, then remove that server from
   the server list. Its downloads stop and its resume data is deleted.
4. Quit the app, connect to CarPlay with the phone locked, and start the app from the
   CarPlay screen only. In Console.app, check that the engine is created (its session
   is recreated and stored downloads are tracked) without a window scene. Then verify
   whether the engine activates while only CarPlay is connected: the app's `scenePhase`
   combines every scene, so note what it reports. Unlock the phone and open the app: the
   engine is active afterwards, whichever phases came first.
5. Switch between the app and the Home Screen a few times during a download. Each time
   the app comes back, the transfers resume and the clean-up runs; going to the
   background never leaves the engine active.

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
  XML body (an error page or message), an empty file, or a file whose size differs from
  the expected length never reaches `Downloads/`. The exception is a size that matches
  the length the server declared (`Content-Length`, or the total in a 206's
  `Content-Range`): the file changed since the download was planned, so the engine keeps
  it and records the new size as the expected size. When the planned size is unknown, the
  declared length is the expected length. After a 206 the file must always be the whole
  file the `Content-Range` total describes; a 206 that covers only part of it is a size
  mismatch.
- A 401 triggers one token refresh and one new task for the part. A second 401 in a row
  fails the part. The count starts over once the part gets a successful response, and a
  401 for a token that was already replaced doesn't count.
- 408, 429, 5xx, network errors, an unexpected body or a size mismatch are retried after
  1–2, 2–4, 4–8, 8–16 and 16–32 seconds. If it fails after the fifth retry, the part
  fails. The count is saved with the part (`retryCount`), so a relaunch continues it: a
  part that failed twice before the app was terminated waits 4–8 seconds after its next
  failure, and one that used up its retries fails for good. Only starting the download
  again (`start(partIDs:)` or `resume(recordID:)`) starts the count over, or the restart
  that completes such a start (below); `activate()` doesn't. A part being completed or
  failed for good is skipped by the reset. In the foreground the engine waits out the
  delay itself. After `deactivate()`
  (and during a background wake) it creates the part's next task at once, with the delay
  as the task's `earliestBeginDate`, before it lets the wake end: iOS may suspend the
  process afterwards, and the system starts that task on time without it. A relaunch
  adopts it like any surviving transfer. A 401's new task is also created before the
  wake ends. To check, put the device in the background during a download, make the
  server answer 503 once, and look for a second request in the server log about 1–2
  seconds later, without opening the app.
- A full disk, any other status (such as 404 or 204), or a response from another origin
  fails the part at once.
- If the download's state can't be saved when a part starts, that counts as a failure
  and is retried like the others; after the fifth retry the part fails for good with the
  `store` code.
- When a part fails for good, the engine stops the download's other parts, keeps their
  resume data, and marks the download failed. Starting it again continues those parts. A
  `resume(recordID:)` that overlaps any part of the failure (before the failure is saved,
  while the siblings are stopping, or after) restarts the part that failed, with a fresh
  retry count, and every sibling the failure stopped, once the failure is settled. A
  plain `start(partIDs:)` that overlaps the failure restarts only the parts it named, not
  the siblings. If another part fails for good while that failure is under way (its write of
  the download's `failed` state changes nothing, because the download is already failed), the
  replay doesn't queue the download again: restarting only the named parts would leave the
  other part failed and the download unfinished. The download stays failed, and
  `resume(recordID:)` restarts every part (`plainStartReplayDoesNotStrandASiblingsNewerFailure`).
  A pause or deletion while a replay is pending, before or after it queues the download, is
  respected: nothing restarts. A resume that begins while the siblings are stopping restarts
  each part once. The replay happens once per part for each resume: if the restarted part
  fails for good again, that failure is final and fails the download, even while the
  resume is still starting. A newer failure of another part (the download is `failed`
  again) is not overwritten by the replay of an older resume.
- If a surviving transfer fails permanently while `activate()` is adopting it and a
  `resume(recordID:)` is pending, the failure replay uses the already-created session
  inside activation rather than waiting on `ensureSession()` (which would wait for that
  same activation). Activation and a background wake therefore remain pending until the
  replay has created the retry transfer. This also applies when a retryable transfer
  response exhausts its persisted retry budget, the inline background retry fails while
  preparing its request, or a launch initiated by that replay fails while a sibling is
  still pending. The deterministic regression
  `retryFailureDuringAdoptionWithPendingResumeDoesNotDeadlockBackgroundWake` covers all
  three paths during a background wake, with a five-second timeout so a regression fails
  rather than hanging the suite.
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
- If a finished file can't be recorded (the store write fails), the file stays in
  `Downloads/` and the engine tries to record it again after the retry delays above, then
  on each `activate()`. A download whose parts are all recorded but that couldn't be
  added to the library is added again on each `activate()`.
- At the end of a background wake, the engine tries the writes that failed (finished files
  and failed downloads) up to three times, a second apart, before it lets the wake end:
  iOS may end the process afterwards. If they still fail, the next activation finds the
  part "downloading" without a task and its file already in `Downloads/`, and records it
  as finished without a request. It only accepts a file of the expected size that the
  part's current transfer moved: each start of a part writes a marker in
  `Application Support/Transfers/` (after deleting the last one), and only a file
  modified after that marker counts. So a file from an earlier transfer (for example a
  completed part that was queued again) or a file whose size changed on the server is
  downloaded again. To check, set a breakpoint in `DownloadStore.completePart`, start a
  small download, go to the Home Screen, and when the wake stops at the breakpoint, stop
  the app from Xcode. Open the app again: the download completes without a new request in
  the server log.
- A file already in `Downloads/` only completes its part at activation if the store still
  has the part running in a download that isn't paused or failed, checked when the file is
  found. A file that a surviving transfer of a paused or failed download moved stays
  unused, and the download stays paused or failed.
- At activation, a part the store has "downloading" without a task is queued again only
  if the store still has it running then: a transfer that failed for good while the
  engine listed the session's tasks keeps its failed state and error.
- If a part's state can't be saved after a failure, the part stays "downloading" in the
  store without a task; the engine still retries it (or restarts it on the next
  `activate()`).
- If a download's failed state can't be saved after a part fails for good, the engine
  starts none of its parts and saves the state again on each `activate()` and at the end
  of a background wake. Pausing or starting the download again (`pause(recordID:)`,
  `resume(recordID:)` or `start(partIDs:)`) replaces that state.
- A transfer that survived a relaunch is adopted only if its download is still meant to
  run, and its result (a finished file or a failure) counts only once it is adopted. If
  its download was paused or failed, or its state can't be saved, the transfer is
  cancelled and its part queued, keeping its resume data: a file it finished stays in
  `Downloads/` until the part's next transfer replaces it, and a failure doesn't change
  the download's state.
- Pauses and resumes of a download run one at a time, in the order they were called: a
  resume waits for the whole pause (its state change and every cancellation), so every
  part of the download continues. A `start(partIDs:)` during a pause waits for each part's
  cancellation.
- If a background wake can't read the downloads from the store, it ends at once without a
  session. Its events wait for a later session, and the engine doesn't let them end a later
  wake early, even when they arrive while that wake waits: an abandoned wake's
  events-finished call is matched first.
- Discarding a connection's resume data (`discardResumeData(connectionID:)`, on sign-out or
  a credential change) deletes the sealed files and clears only each part's resume-data
  flag: a part that fails or starts meanwhile keeps its new state, error and retry.

## Known limits

- If a background wake's events-finished call never arrives after the wake was abandoned
  (the store couldn't be read), the next wake waits for one more call than it needs, until
  iOS suspends the app when its background time runs out.
- Pausing a download while a background retry waits for its `earliestBeginDate` cancels
  that task; its resume data was moved into it, so the part may continue from 0%.
- Retries already waiting in the process when the app goes to the background stay in the
  process; if iOS suspends it, they run when the app comes back.
- Until #145 adds a foreground redirect check, the engine refuses to download from a
  server connection that has custom headers (for example `CF-Access-Client-Id` and
  `CF-Access-Client-Secret`): the part fails for good with the
  `customHeadersUnsupported` code, without a request. A background session follows
  redirects without asking the app, so these headers could reach another host.
- Background sessions follow redirects without asking the app. `URLSession` drops
  `Authorization` on a redirect, so the bearer token never reaches the target. If the
  final response comes from a different origin, the engine fails the part for good and
  never moves the body into `Downloads/`. A 401 after a redirect fails the part as
  "redirected, credentials not forwarded" without a token refresh. If a server you
  support redirects downloads to another host, test with it. #145 tracks a foreground
  redirect check before the background task starts.
