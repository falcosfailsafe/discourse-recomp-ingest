# frozen_string_literal: true

# name: discourse-recomp-ingest
# about: Ingests decompilation, static recompilation, and AI-rewritten game ports from crawlers and JSON feeds.
# version: 0.2.0
# authors: homelab
# url: https://github.com/falcosfailsafe/discourse-recomp-ingest

enabled_site_setting :recomp_ingest_enabled

after_initialize do
  module ::RecompIngest
    PLUGIN_NAME = "discourse-recomp-ingest"
  end

  require_relative "app/models/recomp_ingest/entry"
  require_relative "app/models/recomp_ingest/alias"
  require_relative "app/models/recomp_ingest/run"
  require_relative "app/services/recomp_ingest/ingestor"
  require_relative "app/services/recomp_ingest/crawler"
  require_relative "app/controllers/recomp_ingest/items_controller"
  require_relative "app/jobs/regular/ingest_recomp_batch"
  require_relative "app/jobs/scheduled/crawl_recomp_sources"
  require_relative "app/jobs/scheduled/poll_recomp_feed"

  Discourse::Application.routes.append do
    post "/recomp-ingest/items" => "recomp_ingest/items#create"
  end
end
