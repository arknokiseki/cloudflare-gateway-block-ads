# Cloudflare Gateway Block Ads

A GitHub Actions script to automatically create and update Cloudflare Zero Trust Gateway ad blocking lists and policy.

The script works by periodically downloading multiple **AdGuard blocklists** (including Mobile Ads, Tracking, Spyware, and more), combining them into a single master list, removing duplicates, splitting it into smaller chunks, and uploading them to Cloudflare. It then creates a Gateway Policy that blocks all traffic to these domains.

It does not use the Cloudflare API unnecessarily; it checks if the combined blocklist has changed since the last run before attempting an update.

## Setup

### Cloudflare

First, ensure you have a Cloudflare account with a Zero Trust subscription. The free plan is sufficient for this script. You can sign up at [https://dash.cloudflare.com/sign-up/teams](https://dash.cloudflare.com/sign-up/teams).

You will then need to create a **User API Token** with the following permissions:
- **Account** -> **Zero Trust** -> **Edit**

You can do this at [https://dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens).

You will also need to find your **Cloudflare Account ID**. You can find this by logging into the Cloudflare dashboard and looking at the URL: `https://dash.cloudflare.com/{ACCOUNT_ID}/...`. It is a 32-character string of letters and numbers.

Please take note of the **API Token** and **Account ID** for use in the next step.

### GitHub

1. **Fork this repository** by clicking the "Fork" button in the top right of the page.
2. Go to the **Settings** tab of your new fork.
3. Under **Secrets and variables** in the sidebar, click **Actions**.
4. Click **New repository secret** and add the following two secrets:
   - Name: `API_TOKEN`
     - Value: *(Your Cloudflare API Token)*
   - Name: `ACCOUNT_ID`
     - Value: *(Your Cloudflare Account ID)*
5. Finally, ensure GitHub Actions are enabled. Go to the **Actions** tab and click "I understand my workflows, go ahead and enable them."
