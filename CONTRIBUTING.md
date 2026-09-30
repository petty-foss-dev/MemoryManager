# Contributing to Memory Manager

Focused fixes, accessibility work, documentation, and well-scoped features are welcome.

Questions and early ideas belong in [GitHub Discussions](https://github.com/petty-foss-dev/MemoryManager/discussions). Use Issues for reproducible bugs and work that is ready to be tracked. Report vulnerabilities privately through [GitHub's security advisory form](https://github.com/petty-foss-dev/MemoryManager/security/advisories/new), never in an issue or discussion.

## Before writing code

1. Search the existing discussions, issues, and pull requests.
2. Start a discussion before committing to a large feature, architecture change, or new dependency. Once the scope is concrete, open an issue so the work can be tracked.
3. Keep each contribution focused on one problem.
4. Build the unmodified app first so existing failures are not mistaken for regressions.

## Fork and open a pull request

The quickest command-line workflow is:

```sh
gh repo fork petty-foss-dev/MemoryManager --clone
cd MemoryManager
git switch -c fix/short-description

# Make and verify your changes, then:
git push -u origin fix/short-description
gh pr create --repo petty-foss-dev/MemoryManager --base main
```

You can also use GitHub's **Fork** button, clone your fork, create a focused branch, and open a pull request against this repository's `main` branch. The upstream repository keeps `main` as its only long-lived branch; contribution branches live in contributor forks and are deleted after merge.

## Project conventions

- Use only public macOS APIs. Features that need private APIs, administrator privileges, helper tools, or kernel extensions are out of scope.
- Anything that signals processes or moves files must stay conservative: verify process identity before sending a signal, confirm destructive actions, and never offer removal of system or protected user data.
- The Xcode project is generated from `project.yml` with XcodeGen. Change `project.yml` and run `xcodegen generate` rather than editing the project in Xcode.
- Prefer clear names and small focused types. Comment reasoning, compatibility constraints, and non-obvious workarounds when the code alone cannot explain them.
- Do not add section banners or comments that narrate obvious code.
- Do not add placeholder code or speculative abstractions.
- Match the app's established visual language and accessibility behavior.

## Privacy

Never commit or paste into an issue:

- personal file names, folder paths, or storage scan results
- unredacted diagnostic snapshots or history exports
- signing certificates, notarization credentials, or keychain profiles

Use invented values in tests and reports.

## Verifying a change

Before opening a pull request:

1. Review the complete diff for unrelated changes, temporary files, and private data.
2. Build the `MemoryManager` scheme and run the unit tests (see the README). Quit any installed copy of Memory Manager first; only one instance can run at a time.
3. Confirm there are no new errors or warnings.
4. Launch the app and exercise every affected user-facing path.
5. Update documentation when setup, behavior, or safety assumptions change.

## Pull requests

Include:

- the problem and user-visible outcome
- the important implementation choice, when one exists
- exact build and runtime checks performed
- screenshots or a short recording for visible UI changes
- known limitations or follow-up work

## Contribution licensing

Contributions are accepted on an inbound-equals-outbound basis. By intentionally submitting a contribution, you license it under the GNU Affero General Public License v3.0 only (`AGPL-3.0-only`) in [LICENSE.md](LICENSE.md). You retain ownership of your contribution. No separate contributor agreement grants the maintainer broader relicensing rights unless you separately agree to one in writing.
