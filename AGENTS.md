# Repository guidance

- Build a lightweight native macOS file manager using Swift and AppKit.
- Read `README.md` and the relevant files in `docs/` before changing behavior.
- Windows Explorer is the UX baseline; MDI child views, multiple native parent windows,
  independent app processes, and saved projects are core requirements.
- Track current implementation status in `docs/roadmap.md`; distinguish plans from working features.
- Keep filesystem work off the main thread and release observers, tasks, and caches with their owners.
- Test file mutations using synthetic data in an isolated temporary directory.
- Preserve originals on failed saves and moves. Never replace failed trash operations with permanent deletion.
- Consider other running processes for project saves, session recovery, settings, and file operations.
- Keep user paths, personal projects, recovery state, credentials, and signing material out of version control.
- Prefer standard frameworks. Explain new dependencies and their resource cost.
- Add meaningful tests for data integrity and behavior; document manual UI checks and untested environments.
- Use the repository-local Git identity. Do not change the user's global Git configuration.
- Follow the current user request's scope; update relevant documentation alongside implementation.
