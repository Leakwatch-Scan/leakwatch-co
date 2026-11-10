# LeakWatch CI

Stop a commit or a build that carries an API key, with one HTTPS call to [LeakWatch](https://leakwatch.net).

This repository holds the GitHub Action, the CI script and the commit hook. They are plain POSIX shell on top of `curl` and `jq`: no binary to install, nothing to keep updated in your runner image.

| You want to… | Use | Where |
|---|---|---|
| Fail a pull request on GitHub | The GitHub Action | [`action.yml`](action.yml) |
| Fail a build on GitLab CI, CircleCI or anything else | The CI script | [`scripts/leakwatch.sh`](scripts/leakwatch.sh) |
| Refuse a commit on your machine | The commit hook | [`scripts/leakwatch-hook.sh`](scripts/leakwatch-hook.sh) |
| Stop a coding agent from committing a secret | The same hook, in Claude Code or Cursor | [`examples/`](examples) |

## How it works

The job sends the diff to `POST https://leakwatch.net/api/v1/scan/content` and reads how many secrets came back. If the count is not zero, it exits non-zero and prints the type, severity and line of each one. The secret value is never printed.

- **Your content is not stored.** The diff is scanned in memory and discarded when the response is sent. Only counts are recorded (how many secrets, of which types and severities), which is what the CI/CD tab of your dashboard shows.
- **Keys are not tested against the provider on this route.** Validating a key means sending it onwards, which this endpoint never does. Live validation is part of LeakWatch monitoring, not of the CI gate.
- **Detection** uses the LeakWatch rule catalogue (443 rules, public at [`/api/v1/detectors`](https://leakwatch.net/api/v1/detectors)).

## Before you start

1. Create an API key in your [LeakWatch dashboard](https://leakwatch.net). It is shown once.
2. Store it as a CI secret named `LEAKWATCH_API_KEY`.

The Free plan allows 50 content scans a day. Solo is unlimited.

## GitHub Actions

```yaml
name: Secret scan
on: pull_request

jobs:
  leakwatch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # the diff needs the base commit
      - uses: Leakwatch-Scan/leakwatch-ci@v1
        with:
          api-key: ${{ secrets.LEAKWATCH_API_KEY }}
```

| Input | Required | Default | Purpose |
|---|---|---|---|
| `api-key` | yes | | Your LeakWatch API key, from a repository secret. |
| `base` | no | PR base, or the commit before the push | Ref or SHA to diff against. |
| `api-url` | no | `https://leakwatch.net/api/v1/scan/content` | Scan endpoint, for a self-hosted LeakWatch. |

On a failure the findings are also written to the job summary.

Pull requests from forks do not receive repository secrets, so the action cannot scan them. Do not work around this with `pull_request_target` unless you understand what that trigger exposes.

## GitLab CI, CircleCI and others

The script takes the base ref as its only argument. Ready-to-copy files are in [`examples/`](examples).

```yaml
# .gitlab-ci.yml
leakwatch:
  image: alpine:3
  variables:
    GIT_DEPTH: 0
  before_script:
    - apk add --no-cache curl jq git
    - curl -fsSL https://raw.githubusercontent.com/Leakwatch-Scan/leakwatch-ci/v1/scripts/leakwatch.sh -o leakwatch.sh
  script:
    - sh leakwatch.sh "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
```

If you prefer not to download a script at build time, copy `scripts/leakwatch.sh` into your repository and review it there. It is about 80 lines.

Exit codes of `leakwatch.sh`:

| Code | Meaning |
|---|---|
| `0` | No secret in the diff, or the diff is empty. |
| `1` | At least one secret found. |
| `2` | The scan could not run (base not found, network error, quota spent, unexpected response). |

A scan that cannot run fails the build on purpose: a gate that goes green when the API is unreachable is not a gate.

## Commit hook

`leakwatch-hook.sh` sends only the lines a commit **adds**, so the commit that removes a key goes through.

### With pre-commit

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/Leakwatch-Scan/leakwatch-ci
    rev: v1.0.0
    hooks:
      - id: leakwatch
```

### As a plain git hook

```sh
mkdir -p ci
curl -fsSL https://raw.githubusercontent.com/Leakwatch-Scan/leakwatch-ci/v1/scripts/leakwatch-hook.sh -o ci/leakwatch-hook.sh
printf '#!/bin/sh\nexec sh ci/leakwatch-hook.sh\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### In Claude Code and Cursor

The same script, with `--claude` or `--cursor`, runs before any shell command that contains a `git commit`. A refusal is handed back to the agent with the file and line to fix.

- Claude Code: copy [`examples/claude-code-settings.json`](examples/claude-code-settings.json) into `.claude/settings.json`.
- Cursor: copy [`examples/cursor-hooks.json`](examples/cursor-hooks.json) into `.cursor/hooks.json`.

Both expect the script at `ci/leakwatch-hook.sh` in your project.

LeakWatch also exposes the scan as an MCP tool, so an agent can check content before writing it: see [`examples/mcp.json`](examples/mcp.json).

### When the hook cannot scan

No key, no network or the daily quota spent: the hook lets the commit through and says so. A local hook that blocks you offline gets removed within a week. Set `LEAKWATCH_STRICT=1` to block instead.

This is the opposite of the CI default, deliberately. The hook is a convenience and can be skipped with `--no-verify`. The pipeline is the control.

## Environment variables

| Variable | Used by | Purpose |
|---|---|---|
| `LEAKWATCH_API_KEY` | both scripts | Your API key. Required. |
| `LEAKWATCH_API` | both scripts | Override the scan endpoint. |
| `LEAKWATCH_STRICT` | hook | `1` blocks the commit when the scan cannot run. |

## Troubleshooting

- **Zero findings on a repository that has some.** The clone is shallow. Use `fetch-depth: 0` on GitHub or `GIT_DEPTH: 0` on GitLab.
- **`base 'origin/main' not found`.** Your default branch has another name, or history was not fetched. Pass the base explicitly.
- **HTTP 402.** The Free daily quota is spent. It resets at midnight UTC.
- **HTTP 413.** The diff is larger than your plan allows. Split it and scan in parts.
- **HTTP 429.** You hit the rate limit. Retry later.
- **A false positive.** Tell us at `security@leakwatch.net` so the rule gets fixed.

## Why scan the diff and not the whole tree

A key committed two years ago would fail every build from now on, including the ones that fix it, and the job would be disabled within a week. The diff is what the pull request is responsible for. To audit what is already in the history, run a deep scan from your LeakWatch dashboard: it walks every branch and tag.

A CI gate only sees what goes through your pipeline. Most keys leak from somewhere else: a fork, a contributor's own repository, a gist. That is what [LeakWatch monitoring](https://leakwatch.net/product) covers.

## Links

- [CI guide and API documentation](https://leakwatch.net/docs?tab=ci)
- [Revocation guides, one per credential type](https://leakwatch.net/secrets)
- [What to do after pushing an API key to GitHub](https://leakwatch.net/blog/i-accidentally-pushed-an-api-key-to-github)

## License

MIT. See [`LICENSE`](LICENSE).
