## Summary

- Describe the user-visible image or shared pipeline change.

## Scope

- [ ] Image changes are confined to one `images/<name>` or `patched/<name>` context.
- [ ] Shared workflow, matrix, catalog, or scanner changes use a prerequisite PR.

## Validation

- [ ] `./check`
- [ ] The native-architecture happy path and one meaningful failure path were exercised.
- [ ] Required changed-scope CI is green.

## Source and provenance

- [ ] APKO inputs and lock are reviewed, or not applicable.
- [ ] A Melange source build pins immutable source and dependency overrides, or not applicable.
- [ ] The signed image-local repository lock and provenance evidence are present, or not applicable.

## Review

- [ ] Every review thread has a reply and is resolved.
- [ ] The final paginated scan reports zero unresolved threads.
