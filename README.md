# discourse-recomp-ingest

Discourse plugin for ingesting game recompilations, decompilations, and AI-rewritten ports into **recomp.club** from external crawlers and JSON feeds.

## Features
- **Multi-key Deduplication (`RecompIngest::Ingestor`):**
  - Normalizes and matches against `recomp_repo` (GitHub, GitLab, Codeberg, sourcehut), `recomp_source_url`, `recomp_alt_urls`, `recomp_dedup_key`, and `recomp_external_ids`
  - Supports `update_existing: true` to refresh existing topics with updated artwork and merged metadata
- **Automatic Cover Downloads:** Downloads remote `cover_image_url` artwork into Discourse `Upload` records (or accepts `upload://` short URLs) so topic thumbnails generate automatically
- **Structured Topic Formatting:** Renders spec tables (`Original System`, `Target Platforms`, `Method / Status`, `Source / Repo`), summaries, and optional AI Rewrite / Lifting notes, and applies system/game/method tags
- **Interfaces:**
  - `POST /recomp-ingest/items` (admin / API-key authenticated)
  - `bin/rails recomp_ingest:import[path/to/items.json]` rake task
  - `Jobs::PollRecompFeed` scheduled job (polls `recomp_ingest_feed_url` every 6 hours when configured)

## Installation
Add to your Discourse `app.yml` `hooks.after_code` plugins list:
```yaml
- git clone https://github.com/falcosfailsafe/discourse-recomp-ingest.git
```
