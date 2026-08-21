# Contributing to Flamina

Thank you for contributing to Flamina.

## Before You Start

- Read and follow [AGENTS.md](AGENTS.md).
- Keep changes focused, lightweight, and native to macOS whenever practical.
- Open an issue before starting a large feature or architectural change so its scope can be discussed.
- Do not add a third-party dependency unless the same result cannot reasonably be achieved with Apple frameworks or a small local implementation.

## Development

1. Create a branch from the current main development branch.
2. Implement the smallest coherent change that solves the problem.
3. Add or update tests for changed behavior.
4. Keep English and Simplified Chinese localizations complete.
5. Run the relevant tests before submitting the change:

   ```sh
   xcodebuild test \
     -project flamina.xcodeproj \
     -scheme flamina \
     -destination 'platform=macOS'
   ```

6. Use concise English Conventional Commit messages.

## Licensing of Contributions

Flamina is licensed under the [MIT License](LICENSE). By submitting a contribution, you agree that your contribution is provided under the same MIT License and that you have the right to grant that license.

Contributors retain attribution through Git history. File headers must identify the human contributor using the active `git config user.name`; agent, model, assistant, and tool names must not be used as authors.

Do not submit code, assets, documentation, or other material that cannot legally be distributed under the project's license. Clearly identify any compatible third-party material and include all required copyright and license notices.
