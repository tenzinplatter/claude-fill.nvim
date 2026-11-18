# Fork every Fill from a per-root Primer

Each Project root has one Primer: a headless Claude session that has already explored the project. Every Fill starts as a fork of it (`--resume <primer> --fork-session`), so it inherits that exploration and the shared prefix is served from the prompt cache. A Primer goes stale when the root's git HEAD moves; it is rebuilt in the background while Fills keep forking the Stale Primer.

## Considered Options

- **Fresh session per Fill**: always current, but every Fill pays for a full exploration in time and tokens.
- **One long-lived session handling Fills in turn**: context grows without bound, earlier Fills bleed into later ones, and Fills cannot run concurrently.

## Consequences

- Knowledge a Fill gathers is lost when it ends; only rebuilding the Primer shares new knowledge.
- Primer and Fills must use the same model, tools and `--json-schema`, or the cache is not shared. The schema adds a tool, so the Primer is built with the Fill schema too and its own structured answer is ignored.
