# Contributing

Thanks for helping out. This is a small project, so the process is light.

1. Fork the repository and create a topic branch.
2. Keep the change focused; avoid unrelated edits.
3. Run the checks before opening a pull request:

   ```sh
   flutter pub get
   flutter analyze
   flutter test
   ```

4. Test the affected build on a device or emulator (`--flavor mobile` or
   `--flavor tv`); behaviour differs between the two.
5. Open a pull request that says what changed, which flavor it affects, and how
   you tested it.

Please do not commit APKs, keystores, `key.properties`, `local.properties`, or
any credentials. Release binaries are published on GitHub Releases.

By contributing you agree that your work is licensed under the MIT License.

## Code style

The project follows `flutter_lints` (see `analysis_options.yaml`). Keep the
injected page scripts defensive: YouTube changes its markup and API payloads
without notice.
