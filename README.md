## Stacked PRs with squash & merge

### The problem

If you want stacked pull requests on GitHub, one way to do it that stays easy for people who aren't rebase wizards is to use a simple `git push` / `git merge` workflow while working on your PRs.

When you merge the lower PR in the stack, you just need to update the upper PR. This works fine if you use regular merge commits, but your trunk history becomes very hard to read with normal tooling like the GitHub commit history page (though you can still navigate it with `git log --first-parent`).

If you use squash & merge instead, your main branch history stays nice and clean, but now the upper PR in the stack gets a garbage diff and merge conflicts when you try to update it. This happens because the squash commit rewrites history, and GitHub can't figure out what the PR is actually trying to change.

### The solution

This action tries to fix that in a transparent way. Install it, and hopefully the workflow of stacking + merge during dev + squash merge when landing works.

---

### How it works

1. Triggers when a PR is squash merged
2. Finds PRs that were based on the merged branch
3. For direct children: creates a synthetic merge commit with three parents (child tip, deleted branch tip, squash commit) to preserve history without re-introducing code
4. For indirect descendants: merges the updated parent branch
5. Updates each PR's base branch to point to trunk
6. Force-pushes updated branches and deletes the merged branch

---

### Setup

Create a `.github/workflows/update-pr-stack.yml` file:
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
        uses: Phlogistique/autorestack-action@main
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Notes

* Currently only supports squash merges
* If a merge hits a conflict, you'll need to resolve it manually
* Very large stacks might hit GitHub rate limits

---

### Credits

Inspired by Graphite and Gerrit workflows but implemented with plain git + GitHub CLI.
