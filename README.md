# Claude Code CLI — Reverse Engineering Design Documents

> Implementation-ready reverse engineering specifications for Anthropic's Claude Code CLI tool.
> Based on source map analysis of the npm package (March 2026).

## Overview

Claude Code is Anthropic's official CLI tool for AI-powered software engineering. These documents provide comprehensive reverse-engineered specifications covering:

- **~1,900 source files**, 512,000+ lines of code
- **Runtime:** Bun (not Node.js), TypeScript strict, ESM
- **UI:** React 19 + custom Ink fork (terminal renderer)
- **Architecture:** Tool-based agent system with multi-agent coordination

## Documents

| # | Document | Description |
|---|----------|-------------|
| 01 | [Architecture Overview](docs/01-architecture-overview.md) | Bootstrap, modules, build system, feature flags |
| 02 | [Core Engine](docs/02-core-engine.md) | Tool system, query engine, streaming, compaction |
| 03 | [Permission & Security](docs/03-permission-security.md) | Permission pipeline, shell security, path validation |
| 04 | [Multi-Agent & Memory](docs/04-multi-agent-memory.md) | Agent coordination, memory hierarchy, team sync |
| 05 | [Extension Systems](docs/05-extension-systems.md) | MCP, plugins, skills, hooks, LSP, bridge |
| 06 | [UI Layer](docs/06-ui-layer.md) | Ink reconciler, Yoga layout, components, events |
| 07 | [Services & Infrastructure](docs/07-services-infrastructure.md) | API client, auth, analytics, migrations |
| 08 | [Types, Schemas & API](docs/08-types-schemas-api.md) | Type system, Zod schemas, env vars, feature flags |

## Verification Status

These documents have been through **8 passes of verification** against the actual source code:
- 39 factual corrections applied
- 42 implementation caveats added
- 24/24 random spot-checks verified in final pass
- All BLOCKING implementation gaps resolved

## Disclaimer

This is a reverse-engineering effort for educational and security research purposes. All rights to the original Claude Code software belong to Anthropic.

## License

MIT (documentation only — does not cover the original Claude Code software)
