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
| Oracle Cloud | https://ocistatus.oraclecloud.com | `services/oci.json` | `SLACK_WEBHOOK_URL_OCI` | `OCI_` |
| Slack | https://slack-status.com | `services/slack.json` | `SLACK_WEBHOOK_URL_SLACK` | `SLACK_` |
| Salesforce (CAN56) | https://status.salesforce.com/instances/CAN56 | `services/salesforce.json` | `SLACK_WEBHOOK_URL_SALESFORCE` | `SF_` |

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
| Cloudflare, SMTP2GO | component names and group names (Cloudflare regions: `North America`, `Europe` ...) | the incident's own impact |
| AWS | service name (`Amazon Elastic Compute Cloud`), region name (`N. Virginia`), region code (`us-east-1`), service code (`ec2-us-east-1`) | informational = minor, degraded = major, disruption = critical |
| Oracle Cloud | service name (`Networking`), region (`US East (Ashburn)`), category (`Cloud Services`) | service disruption = major, other degraded states = minor |
| Slack | service (`Messaging`, `Login/SSO`, `Huddles`, `Notifications`, `Apps/Integrations/APIs` ...) | notice = none, incident = minor, outage = major |
| Salesforce | service key or name: `coreService` / `Core service`, `Communities` / `Experience Cloud`, `liveAgent` / `Chat` ... (defaults to the services a support portal relies on; Data Cloud, Marketing Cloud and Agentforce are left out) | disruption or major severity = major, otherwise minor |

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

For a private repo on a free account, change the cron to `'*/30 * * * *'` to stay within the
2,000 free Actions minutes a month (five services take five times the minutes of one).
