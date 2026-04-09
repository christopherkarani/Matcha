# Lessons

- When republishing a codebase as a genuinely new project, default to a fresh root history instead of preserving inherited commits unless the user explicitly asks to keep lineage.
- Before creating an orphan release commit, confirm `.gitignore` is present and that build/output directories are excluded from the index.
- Keep repo-facing task logs aligned with the product the user wants to publish, not the internal migration path used to get there.
