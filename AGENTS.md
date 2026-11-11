# Repository instructions

- Product implementation lives in `macos/`; preserve that platform boundary.
- Read the relevant source and `macos/README.md` before changing behavior. `macos/ROADMAP.md` describes proposals, not implemented features.
- Keep secrets, local app data, generated downloads, build caches, and recovered third-party material out of Git. Do not weaken the root `.gitignore` to publish them.
- Use focused feature/fix branches and conventional commit subjects. Review staged paths and the diff before committing. Push validated logical milestones and use pull requests for feature work.
- Run checks appropriate to the change. Transfer/state changes require the local integration suite. App packaging changes require a release build. Report only checks that actually ran and distinguish local results from GitHub CI.
- Use generated/local fixtures for tests; avoid public swarms and personal credentials or files.
- Preserve the owned aria2 lifecycle, private authenticated loopback control, resumable transfer state, and compatibility with existing history.
- Keep dependencies explicit, document third-party notices, and never copy recovered FDM assets into the product.
- Do not claim a roadmap item is complete until the implementation, usable UI or interface, and meaningful verification are present. Record unresolved external requirements such as distribution signing separately.
