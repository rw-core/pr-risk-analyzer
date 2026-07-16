<div align="center">
  <img src="assets/logo.png" alt="PR Risk Analyzer Logo" width="128" />

  <h1>PR Risk Analyzer</h1>

  <p>
    <a href="https://github.com/rw-core/pr-risk-analyzer/actions"><img src="https://img.shields.io/github/actions/workflow/status/rw-core/pr-risk-analyzer/test.yml?branch=main&style=flat-square" alt="CI"></a>
    <a href="https://github.com/rw-core/pr-risk-analyzer/releases"><img src="https://img.shields.io/github/v/release/rw-core/pr-risk-analyzer?style=flat-square" alt="Latest release"></a>
    <a href="https://github.com/marketplace/actions/pr-risk-analyzer"><img src="https://img.shields.io/badge/marketplace-pr--risk--analyzer-blue?logo=github&style=flat-square" alt="GitHub Marketplace"></a>
    <a href="https://github.com/rw-core/pr-risk-analyzer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/rw-core/pr-risk-analyzer?style=flat-square" alt="License"></a>
  </p>
</div>


A GitHub Action that analyzes pull requests for historical risk factors. It uses the `rw_git` engine to identify if a PR modifies files that are known bug hotspots, exhibit high code volatility or have a high bus factor.

## Core Metrics
- **Bug Hotspots Detection (RA-SZZ)**: Evaluates the files modified in the PR against the repository's history to identify files that frequently caused bugs in the past (using the Refactoring-Aware SZZ algorithm).
- **Code Volatility Warning**: Identifies highly volatile files modified in the PR (files with high churn across many different authors), which often point to underlying architectural problems.
- **Bus Factor Analysis**: Analyzes the bus factor individually for each file modified in the PR, evaluating knowledge distribution and potential single points of failure.
- **PR Churn Metrics**: Calculates commit and author churn for the pull request's revision range.

## Compound Risks Analysis
Synthesizes the raw metrics above to produce highly actionable predictions of software defects and knowledge loss:
- **Tribal Knowledge Risk**: Bug hotspots owned by a single author (Bus factor > 50%).
- **Too Many Cooks Risk**: Bug hotspots with 3 or more minor contributors (< 5% ownership).
- **Departure Defect Risk**: A single author solely owning multiple bug hotspot files.
- **Defect-Injection Predictor**: Highly volatile, highly complex files requiring immediate refactoring.
- **Clean-up Exception**: High volatility on files safely explained by recent refactorings.

## Evidence & Reporting
- 📚 **Evidence-Based Reporting**: Automatically includes academic citations and rationales explaining *why* a flagged metric matters directly within the PR comment.
- 📌 **Sticky PR Comments**: Automatically posts and updates a warning comment on the PR if it flags risky files.

## Sample Usage

Add the following step to your GitHub Actions workflow:

```yaml
name: PR Analysis
on: [pull_request]

jobs:
  analyze:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write # Required for sticky comments
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Full history is required for SZZ and volatility checks

      - name: Run PR Risk Analyzer
        uses: rw-core/pr-risk-analyzer@v1
        with:
          # Optional configurable parameters
          # github-token: ${{ github.token }}
          # working-directory: '.'
          # volatility-threshold: '20.0'
          # fail-on-warning: 'false'
          # history-days: '730'
```

## Inputs

| Name | Description | Default | Required |
|------|-------------|---------|----------|
| `github-token` | Token used to post the sticky PR comment. | `${{ github.token }}` | No |
| `working-directory` | Path to the repository root to analyse. | `.` | No |
| `volatility-threshold`| Threshold of volatility score to flag a file as highly volatile. | `20.0` | No |
| `fail-on-warning` | When `true`, exits non-zero (fails the workflow) if the PR touches any bug hotspots or volatile files. | `false` | No |

## Outputs

| Name | Description |
|------|-------------|
| `bug-hotspots-count` | Number of bug hotspots touched by the PR. |
| `volatile-files-count`| Number of highly volatile files touched by the PR. |
| `bus-factor-score`| A JSON string mapping each modified file to an object containing its bus factor, total developers, and top contributors. |
| `tribal-knowledge-count` | Number of files flagged for tribal knowledge risk. |
| `too-many-cooks-count` | Number of files flagged for too many cooks risk. |
| `departure-defect-count` | Number of authors flagged for departure defect risk. |
| `defect-injection-count` | Number of files flagged as defect-injection predictors. |
| `clean-up-exception-count` | Number of highly volatile files safely explained by recent refactorings. |

## Example of how the end-result PR comment looks like

When risks are detected, the action posts a detailed sticky comment on the PR:

> ### 🎯 Compound PR Risks
> Actionable compound findings identified by combining multiple risk vectors:
> 
> #### 🔴 Tribal Knowledge Risk
> **Condition**: A bug hotspot file is owned by a single author (Bus factor > 50%).<br>
> **Rationale**: Undocumented tribal knowledge in bug-prone code increases the risk of injecting defects if the context is siloed.
> > **Citation**: Avelino et al. (2016) - Knowledge loss and defect proneness.
> 
> - **`lib/core/legacy_payment_gateway.dart`**
> 
> #### 🔴 Defect-Injection Predictor (Refactoring Targets)
> **Condition**: A highly volatile or high-churn file (> 10 commits in the window) whose diffs also added a substantial amount of control-flow complexity (≥ 30 branching tokens).<br>
> **Rationale**: Actively-changing complex code is the prime defect-injection risk. These are prime refactoring targets.
> > **Citation**: Nagappan & Ball (2005); Tornhill (2015) - Prioritizing tech debt in the PR.
> 
> - **`lib/ui/massive_dashboard_widget.dart`**
> 
> ---
> 
> ### 📊 PR Risk Analyzer Report
> 
> #### ⚠️ Bug Hotspots Detected
> This PR modifies files with a history of bug fixes. Reviewers should be extra cautious.
> > **Citation & Explanation**: *Śliwerski, Zimmermann, and Zeller (2005) - SZZ Algorithm.* Files that frequently required fixes in the past are highly likely to contain future bugs.
> 
> - **`a1b2c3d`**: Fixed in `e4f5g6h` (File: `lib/core/legacy_payment_gateway.dart`)
> 
> #### 🔄 PR Churn Metrics
> > **Citation & Explanation**: *Nagappan & Ball (2005).* The raw number of commits and authors modifying a file within the PR scope.
> 
> **Total PR Commits: 14**
> - **`lib/core/legacy_payment_gateway.dart`**: 8 changes by 2 authors in this PR.
> 
> #### 🚌 PR Files Bus Factor
> > **Citation & Explanation**: *Avelino et al. (2016).* A measure of knowledge concentration. A low bus factor indicates key developers hold critical, undocumented project knowledge.
> 
> - **`lib/core/legacy_payment_gateway.dart`**: Bus Factor **1** (out of 3 developers)
>   - `john.doe`: 45 commits (65.2%)
>   - `jane.smith`: 12 commits (17.4%)
