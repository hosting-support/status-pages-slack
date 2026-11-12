// Cloudflare Worker that starts the "Status pages to Slack" workflow every 5 minutes.
// GitHub's own schedule is best-effort and often runs hours apart; a workflow_dispatch call
// (the same as the "Run workflow" button) starts right away.
//
// Setup (Cloudflare dashboard -> Workers & Pages -> this Worker):
//   Settings -> Variables and Secrets: secret GITHUB_TOKEN = a fine-grained GitHub token with
//     access to this one repository and "Actions: Read and write" permission
//   Settings -> Trigger Events: cron trigger */5 * * * *

const REPO = 'hosting-support/status-pages-slack';
const WORKFLOW = 'status-to-slack.yml';
const BRANCH = 'main';

export default {
  async scheduled(event, env, ctx) {
    const res = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.GITHUB_TOKEN}`,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'status-pages-trigger',
      },
      body: JSON.stringify({ ref: BRANCH }),
    });
    // GitHub answers 204 when the run was started; anything else shows as an error in the
    // Worker's logs (e.g. 401 = token expired or wrong, 404 = no access to the repo/workflow)
    if (res.status !== 204) {
      throw new Error(`GitHub returned ${res.status}: ${await res.text()}`);
    }
  },

  // Visiting the Worker's URL doesn't start anything; it just says what this is.
  async fetch() {
    return new Response(`Starts the ${WORKFLOW} workflow in ${REPO} every 5 minutes.\n`, {
      headers: { 'Content-Type': 'text/plain' },
    });
  },
};
