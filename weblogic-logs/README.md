# WebLogic log check

Watches CMiC's WebLogic log index (one folder per AWS-hosted server) and alerts when a server's
logs stop updating. It posts to #hostingsupport and shows as the **WebLogic Logs** tile on the
status page, under "CMiC Internal Checks".

## What's public and what isn't

This repository and the status page are public. So:

- **Slack** gets the server name, the file and a link to its log folder.
- **The page** shows only a count, such as "3 of 47 servers' logs not updating (6%)". No server
  names, no links.
- **The log index address** is not in any file here. `-SaveSecrets` asks for it and keeps it on
  the machine that runs the check.

## Why it doesn't run in GitHub Actions

The log index is only reachable on CMiC's network (VPN). GitHub and Cloudflare can't see it. So
the check runs on a Windows machine inside the network, from Task Scheduler. After each check it
pushes its result to the `weblogic-logs-data` branch, and the workflow puts that on the page.

If that machine stops (shut down, off the VPN, token expired), the tile turns grey with
"No recent data" after 20 minutes. A stopped check is visible, not silent.

## What counts as "not updating"

Settings are under `"logs"` in `services/weblogic-logs.json`.

| Setting | Default | Meaning |
|---|---|---|
| `files` | `{server}_*_adminServer.out` | Files to watch. `{server}` is the folder name. The `.out` file is written every minute or so on a healthy server. |
| `zeroMinutes` | 5 | A watched file at 0 bytes for this long opens an incident. It stays open until the file has data again. |
| `notUpdatedMinutes` | 0 (off) | Also flag a file that has data but hasn't changed for this long. |
| `ignoreOlderThanDays` | 14 | Files untouched for longer are treated as a retired server and skipped. |
| `ignoreServers` | none | Folder names (wildcards) to skip, e.g. a server being rebuilt. |
| `minorUpToPercent` | 5 | Up to this share of servers not updating, the tile shows **Minor issue**. |
| `majorUpToPercent` | 15 | Up to this share it shows **Major issue**. Above it, **Critical**. |

Slack gets one post per server when its logs stop, and one when they come back. The post's
color follows the tile's level at that moment.

The percentage is rounded to a whole number. With 47 servers: 1 to 2 servers is minor, 3 to 7
is major, 8 or more is critical.

The count can't be acknowledged with a ✅ reaction, unlike the vendor incidents. That's on
purpose: an acknowledgement of a small problem shouldn't hide it growing into a large one.

The very first run only records what's already broken and posts nothing. The page still shows it.

## Setup on the machine that runs it

1. Copy the whole repository folder to the machine (it needs `status-to-slack.ps1`,
   `providers\`, `services\` and this folder).
2. Make the secrets:
   - **Slack:** a new Slack app "WebLogic Logs" with an incoming webhook to #hostingsupport.
   - **GitHub:** signed in as nlazarevski, Settings → Developer settings → Fine-grained tokens →
     Generate new token. Resource owner **hosting-support**, only the **status-pages-slack**
     repository, permission **Contents: Read and write**.
3. In PowerShell, in this folder, signed in as the Windows user the task will run as:

   ```powershell
   .\run-weblogic-logs.ps1 -SaveSecrets
   .\run-weblogic-logs.ps1 -DryRun
   .\run-weblogic-logs.ps1
   .\run-weblogic-logs.ps1 -Install
   ```

   `-SaveSecrets` asks for the log index address, the webhook and the token, and stores them for
   that user on that machine (the webhook and token encrypted). `-DryRun` checks and prints
   without posting. The plain run posts and pushes once. `-Install` adds the Task Scheduler job
   "WebLogic log check", every 5 minutes. A file that empties is flagged after 5 minutes at
   0 bytes, so an alert can take up to about 10 minutes to arrive.
4. On a server, open Task Scheduler → WebLogic log check → Properties, and pick
   **Run whether user is logged on or not**. On a laptop, the default (only while signed in) is fine.

`run.log` in this folder has each run's result.

## When it goes wrong

| In `run.log` | Fix |
|---|---|
| `Check failed: ... unable to connect` | The machine can't reach the log index. Check the VPN. |
| `Push to GitHub failed: (401)` | The GitHub token expired. Make a new one, run `-SaveSecrets`. |
| `Push to GitHub failed: (403)` or `(404)` | The token lacks Contents: Read and write on the repository. |
| `No Slack webhook saved` or `No log index address saved` | Run `-SaveSecrets`. |
