# cron-job.org Setup for Precise 5-Minute Scheduling

GitHub's built-in `schedule` cron is best-effort and can be delayed by 30–60 minutes
on public repos. Use cron-job.org to trigger `workflow_dispatch` at exact intervals.

## Steps

### 1. Create a GitHub Personal Access Token

Go to: https://github.com/settings/tokens/new?scopes=workflow
- Note: `Trigger GitHub Actions workflows`
- Expiration: set to your preference (or "No expiration")
- Required scope: **workflow**

Copy the token (starts with `ghp_...`).

### 2. Set up cron-job.org

1. Log in at https://cron-job.org
2. Create a new cron job:

| Setting | Value |
|---------|-------|
| URL | `https://api.github.com/repos/BKPepe/monitoring-agent/actions/workflows/monitor.yml/dispatches` |
| Execution schedule | Every **5 minutes** |
| Request method | **POST** |
| Request headers | See below |
| Request body | `{"ref":"main"}` |

**Headers to add:**
```
Accept: application/vnd.github+json
Authorization: Bearer ghp_YOUR_TOKEN_HERE
Content-Type: application/json
X-GitHub-Api-Version: 2022-11-28
```

### 3. Test

After saving, click "Run now" in cron-job.org.
Then check: https://github.com/BKPepe/monitoring-agent/actions

You should see a new "Monitor Agent" run triggered by `workflow_dispatch`.

### 4. Optional: Disable the built-in schedule

Once cron-job.org is working reliably, you can keep both (redundancy)
or remove the `schedule:` block from `monitor.yml` to avoid duplicate runs.
