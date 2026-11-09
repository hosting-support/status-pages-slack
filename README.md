# Status pages to Slack

A GitHub Actions workflow that checks vendor status pages every 5 minutes and posts to Slack
(one channel per service) when:

- the overall status changes (where the page has one)
- an incident gets a new update (investigating / identified / monitoring / resolved)

| Service | Status page | Settings file | Webhook secret | Variable prefix |
|---|---|---|---|---|
| Cloudflare | https://www.cloudflarestatus.com | `services/cloudflare.json` | `SLACK_WEBHOOK_URL_CLOUDFLARE` | `CF_` |
| SMTP2GO | https://smtp2gostatus.com | `services/smtp2go.json` | `SLACK_WEBHOOK_URL_SMTP2GO` | `SMTP2GO_` |
| AWS | https://health.aws.amazon.com/health/status | `services/aws.json` | `SLACK_WEBHOOK_URL_AWS` | `AWS_` |
| OCI (Oracle Cloud Infrastructure) | https://ocistatus.oraclecloud.com | `services/oci.json` | `SLACK_WEBHOOK_URL_OCI` | `OCI_` |
| Slack | https://slack-status.com | `services/slack.json` | `SLACK_WEBHOOK_URL_SLACK` | `SLACK_` |
| Salesforce (CAN56) | https://status.salesforce.com/instances/CAN56 | `services/salesforce.json` | `SLACK_WEBHOOK_URL_SALESFORCE` | `SF_` |
| Dynatrace | https://dynatrace.status.io | `services/dynatrace.json` | `SLACK_WEBHOOK_URL_DYNATRACE` | `DT_` |
| Jira | https://jira-software.status.atlassian.com | `services/jira.json` | `SLACK_WEBHOOK_URL_JIRA` | `JIRA_` |

## How it fits together

- `status-to-slack.ps1`: the shared part. Remembers what was already posted, applies the
  filters, formats and sends the Slack posts. The same for every service.
- `providers/*.ps1`: one small adapter per *kind* of status page. It reads that page's data
  and maps its own wording (AWS "Service disruption", Slack "outage", OCI "ServiceDisruption" ...)
  onto a common impact scale (`none` < `minor` < `major` < `critical`) and a post color.
  `statuspage.ps1` covers every Atlassian Statuspage site (Cloudflare, SMTP2GO, GitHub, Okta ...).
- `services/*.json`: one per service. Which provider and URL, the Slack header, and the
  default filters.
- `.github/workflows/status-to-slack.yml`: one workflow; each run checks all services side by
  side (a failure in one doesn't stop the others).

## Setup

1. In Slack, create an incoming webhook for each channel (api.slack.com/apps → your app →
   Incoming Webhooks → Add New Webhook to Workspace → pick the channel).
2. In this repo: **Settings → Secrets and variables → Actions → New repository secret**, one per
   service, named as in the table above, with the webhook URL as the value.
   A service without its secret is skipped (with a warning), not failed.
3. **Actions** tab → **Status pages to Slack** → **Run workflow**.

The first run for each service only records the current state and posts nothing. After that,
each run posts what changed since the previous one.

## Filters and settings

Each service's defaults are in its `services/<id>.json`:

| Setting | Example | Effect |
|---|---|---|
| `categories` | `["us-east-1", "Amazon Elastic Compute Cloud*"]` | Only updates affecting a matching name (see below). `*` wildcards. Empty = everything. |
| `minImpact` | `"major"` | Skip incidents below this impact: `none` (default), `minor`, `major`, `critical`. |
| `skipUntagged` | `true` | With `categories`, also drop incidents that list nothing they affect. |
| `skipOverallStatus` | `true` | Don't post overall status changes. |
| `includeMaintenance` | `true` | Also post scheduled maintenance (Statuspage sites, Slack and Salesforce). |
| `components` | `["Dashboard", "*Workers*"]` | Also post when one of these components changes status (Statuspage sites). |
| `label` | `":cloud: *Cloudflare Status*"` | Small header on every post. |

Any of the first four, and the label, can also be overridden without editing files: under
**Settings → Secrets and variables → Actions → Variables**, add `<prefix>CATEGORIES`,
`<prefix>MIN_IMPACT`, `<prefix>SKIP_UNTAGGED`, `<prefix>SKIP_OVERALL_STATUS` or
`<prefix>SLACK_LABEL` (e.g. `AWS_CATEGORIES`). In a variable, separate categories with `;` or
new lines (names contain commas). Changing a filter never replays old updates.

What `categories` matches, and what the impact levels mean, per service:

| Service | `categories` matches | Impact mapping |
|---|---|---|
| Cloudflare, SMTP2GO, Jira | component names, group names (Cloudflare regions: `North America`, `Europe` ...), or `Group / Component` for one component in one group | the incident's own impact |
| AWS | service name (`Amazon Elastic Compute Cloud`), region name (`N. Virginia`), region code (`us-east-1`), service code (`ec2-us-east-1`) | informational = minor, degraded = major, disruption = critical |
| Oracle Cloud | service name (`Networking`), region (`US East (Ashburn)`), category (`Cloud Services`) | service disruption = major, other degraded states = minor |
| Slack | service (`Messaging`, `Login/SSO`, `Huddles`, `Notifications`, `Apps/Integrations/APIs` ...) | notice = none, incident = minor, outage = major |
| Salesforce | service key or name: `coreService` / `Core service`, `Communities` / `Experience Cloud`, `liveAgent` / `Chat` ... (defaults to the services a support portal relies on; Data Cloud, Marketing Cloud and Agentforce are left out) | disruption or major severity = major, otherwise minor |
| Dynatrace | container names: `Analyze-AWS-americas` (Process / Retain / Analyze / Automate, per cloud and region) and the global services, which all start with `Dynatrace` (`Dynatrace Support Portal`, `Dynatrace Hub` ...). Default: `*-AWS-americas` and `Dynatrace *` | degraded = minor, partial disruption = major, disruption or security event = critical |

## Adding another status page

1. If it's an Atlassian Statuspage site (`<url>/api/v2/summary.json` returns JSON), copy
   `services/smtp2go.json` and change `name`, `url` and `label`. Otherwise it needs a new
   adapter in `providers/` (copy the closest one).
2. In `.github/workflows/status-to-slack.yml`, add a line under `matrix: include:` and the id to
   the `options:` list near the top.
3. Add the webhook secret.

## Trying it locally

```powershell
.\status-to-slack.ps1 -Service aws -DryRun            # first run: baseline
.\status-to-slack.ps1 -Service aws -DryRun -TestPost  # print the newest update as it would post
```


## Status page

Every run also publishes a one-page overview of all services to GitHub Pages:
`https://<your-user>.github.io/<repo>/`. One card per service, worst first, each with its open
incidents (same filters as the Slack posts) and the last few closed ones. It refreshes itself
every minute. A service whose data is over 20 minutes old shows as "No recent data".

- `?embed=1` hides the page header and history, for dashboards or iframes.
- `?theme=dark` or `?theme=light` forces a theme (default follows the viewer's system).
- The data behind it is `status.json` on the `status-data` branch
  (`https://raw.githubusercontent.com/<your-user>/<repo>/status-data/status.json`), if another
  tool wants to read it.

Setup: **Settings → Pages → Build and deployment → Source: GitHub Actions**. The page is public
for a public repo (it only shows what the vendors' status pages already publish).

Files: `site/index.html` (the page), `build-status-page.ps1` (combines each service's
snapshot from `status-to-slack.ps1` into `status.json`), and two jobs in the workflow:
`publish` saves `status.json` to the `status-data` branch on every run (a quick git push; the
branch holds a single commit that is replaced each time), and `deploy-site` redeploys the page
to GitHub Pages only when `site/` changes, hourly, or on a manual run with **deploy_page**.
Deploying Pages every 5 minutes doesn't work: a deployment can take longer than that.

### Acknowledging an incident

When an open incident doesn't affect us, react to its Slack post with ✅ (`:white_check_mark:`;
✔️ and ☑️ also work). Within 5 minutes the page shows the incident as acknowledged, with who
reacted, when the page first saw it, and a comment, and it no longer turns the tile red or amber.
The comment is the newest reply in that post's thread ("Not impacting us" if there's none).
Removing the reaction undoes it; once the incident is resolved it leaves the open list anyway.
Slack still gets every update. Other emoji can be set with the `ACK_EMOJI` variable
(comma-separated names).

This needs a Slack app that can read the channels: a **bot token** with the scopes
`channels:history`, `groups:history`, `channels:read`, `groups:read` and `users:read`, saved as
the repository secret `SLACK_BOT_TOKEN`, and the app added to each vendor channel (and to any
channel where the posts are shared, e.g. #hostingsupport). The `publish` job reads the last 30
days of those channels, only while some incident is open. Without the secret, nothing is
acknowledged.

## Timing: the Cloudflare Worker

GitHub's own schedule is best-effort: on this repo it ran every 3-8 hours instead of every
5 minutes. So a Cloudflare Worker (`cloudflare-worker/trigger.js`) starts the workflow every
5 minutes through GitHub's API, the same as pressing **Run workflow**. The workflow's own
hourly schedule stays as a backup in case the Worker stops.

The Worker needs a secret `GITHUB_TOKEN`: a fine-grained GitHub token limited to this
repository with **Actions: Read and write**. When the token expires, the Worker's logs show
`GitHub returned 401` and runs fall back to the hourly schedule; create a new token and update
the secret.

This only works for a public repo on a free account: a private repo would run out of the
2,000 free Actions minutes a month within a few days.
