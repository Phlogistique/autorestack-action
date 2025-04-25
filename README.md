## README – Updating Stacked PRs After a Squash‑Merge

### Why this script exists
When you work with **stacked pull‑requests**—a chain of feature branches where each PR is based on the previous one—life is good right up to the moment the bottom PR is merged with **"Squash & Merge."**  
A squash merge rewrites history and then deletes the source branch, which breaks every open PR that depended on it.

**Pain points the script eliminates**

| Pain | Why it happens | Consequence in GitHub UI |
|------|----------------|---------------------------|
| 1. **Descendant branches lose their base** | The commit they were branched from no longer exists on the target branch. | GitHub shows a red *"This branch is out‑of‑date with the base branch"* banner. |
| 2. **Diffs are garbage** | GitHub compares the child‑branch to `main`, not to the commit it actually diverged from. | Reviewers see a giant diff containing code from *all* earlier PRs, making review impossible. |
| 3. **"Update branch" button explodes** | The missing commits mean Git can't perform a clean rebase or merge. | Clicking *Update branch* opens a web conflict‑editor with dozens of unrelated hunks. |
| 4. **Manual recovery is tedious** | Each branch must be rebased/merged and force‑pushed one‑by‑one. | Hours of menial work and risk of errors. |

This action automates that recovery:
1. Replays the missing history onto every direct child PR with a synthetic three‑parent merge.
2. Recursively updates indirect descendants so they stay clean and reviewable.
3. Updates each PR's base branch so GitHub's diff & merge logic are correct.
4. Deletes the merged branch.

The net result: **your stack stays green and reviewers only see the intended diff**.

---

### How the action works (high level)
1. **Trigger** – Fires when a PR is closed *and* `merged == true` *and* has `merge_commit_sha` (i.e. a squash merge).
2. **Discover hierarchy** – Uses `gh pr list` to find PRs whose `base` was the merged branch; walks the tree recursively.
3. **Direct children** – For each child branch it creates a synthetic merge commit that records three parents: (a) the child's old tip, (b) the deleted branch tip, (c) the squash commit. This preserves history without re‑introducing code.
4. **Indirect descendants** – Simply merge the now‑updated parent branch; no custom commit needed.
5. **PR metadata** – Switches each direct child PR's base to the trunk branch (or next living base).
6. **Push & clean up** – Force‑pushes updated branches where necessary and deletes the obsolete branch on the remote.

---

### Using this action in your repository

#### As a GitHub Action workflow
1. Create a `.github/workflows/update-pr-stack.yml` file with the following content:
```yaml
name: Update Stacked PRs on Squash Merge

on:
  pull_request:
    types: [closed]

permissions:
  contents: write
  pull-requests: write
  repository-projects: read

jobs:
  update-pr-stack:
    if: github.event.pull_request.merged == true && github.event.pull_request.merge_commit_sha != ''
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v3
        with:
          fetch-depth: 0

      - name: Update PR stack
        uses: username/test-stack@v1
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```
2. Replace `username/test-stack@v1` with the appropriate repository reference (e.g., `your-username/your-repo@main` or use a version tag).

#### Repository contents
| File | Purpose |
|------|---------|
| `update-pr-stack.sh` | Bash script that performs all git/gh operations. |
| `.github/workflows/update-pr-stack.yml` | GitHub Actions workflow that runs the script after every squash merge. |
| `action.yml` | GitHub Action definition for reuse in other repositories. |

---

### Caveats & Tips
* Only supports **squash merges** for the base PR.
* TODO: If a merge in the chain hits a conflict the workflow exits neutral, comments on the PR, and waits for the developer to resolve & push. A follow‑up label or comment automatically resumes the stack update.
* Very large stacks may hit GitHub rate limits; TODO: throttle or batch API calls if needed.---

---

### Credits
Inspired by *Graphite* and *Gerrit* workflows but implemented with plain git + GitHub CLI.