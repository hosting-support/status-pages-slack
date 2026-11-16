# WebLogic log check

Watches CMiC's WebLogic log index (one folder per AWS-hosted server) and alerts when a server's
logs stop updating. It posts to #hostingsupport and shows as the **WebLogic Logs** tile on the
status page, under "CMiC Internal Checks".

## What's public and what isn't

This repository and the status page are public. So:

- **Slack** gets the server name, the file and a link to its log folder.
- **The page** shows only a count ("2 of 47 servers' logs not updating") and one entry per server
  with a reference, such as "Server logs not updating (WL-3f9a2c)". The Slack post ends with the
  same reference, which is how a ✅ reaction there acknowledges the entry on the page.
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
| `impact` | `major` | How an open incident colors the tile: `minor`, `major` or `critical`. |

One incident per server. Slack gets one post when it opens and one when the logs come back.
A ✅ reaction acknowledges it on the page, like the vendor incidents.

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
   "WebLogic log check", every 2 minutes.
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
