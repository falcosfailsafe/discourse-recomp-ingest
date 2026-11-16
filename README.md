# discourse-recomp-ingest

Discourse plugin for discovering and ingesting game recompilations, decompilations, and AI-rewritten ports into **recomp.club** via native Sidekiq crawlers and JSON feeds.

## Features
- **Postgres-Backed Deduplication (`RecompIngest::Entry` & `RecompIngest::Alias`):**
  - Indexed lookup across `canonical_repo` (GitHub, GitLab, Codeberg, sourcehut), `canonical_url`, `alt_urls`, `external_ids`, and `dedup_key`
  - Automatic fallback to legacy `TopicCustomField` metadata with on-match backfilling into `recomp_ingest_entries` and `recomp_ingest_aliases`
  - Tracks `cover_source_url` and `content_hash` to skip redundant remote artwork downloads (`FileHelper.download` / `UploadCreator`) and unnecessary `PostRevisor` revisions
- **Native Multi-Source Crawler (`RecompIngest::Crawler`):**
  - Crawls and normalizes `awesome-decomp-games`, `recomplauncher.com`, and `recomp.gg` (`/api/games` + paginated `/api/v1/projects`)
  - Cross-source merging, popularity/quality scoring, and automatic SVG fallback cover generation when remote artwork is unavailable
- **Sidekiq Periodic Crawling & Run Tracking:**
  - `Jobs::CrawlRecompSources` (`every 6.hours`) creates a `RecompIngest::Run` audit record, pre-filters unchanged entries by `content_hash`, and enqueues `Jobs::IngestRecompBatch` chunks (`recomp_ingest_batch_size`)
- **Interfaces:**
  - `POST /recomp-ingest/items` (admin / API-key authenticated)
  - `bin/rails recomp_ingest:crawl[limit]` rake task for manual crawls
  - `bin/rails recomp_ingest:import[path/to/items.json]` rake task
  - `Jobs::PollRecompFeed` scheduled job (polls `recomp_ingest_feed_url` every 6 hours when configured)

## Installation
Add to your Discourse `app.yml` `hooks.after_code` plugins list:
```yaml
- git clone https://github.com/falcosfailsafe/discourse-recomp-ingest.git
```
