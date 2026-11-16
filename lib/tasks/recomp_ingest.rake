# frozen_string_literal: true

namespace :recomp_ingest do
  desc "Import recomp/decomp items from a JSON file"
  task :import, [:file_path] => :environment do |_t, args|
    path = args[:file_path]
    if path.blank? || !File.exist?(path)
      raise "Usage: bin/rails recomp_ingest:import[/path/to/items.json]"
    end

    payload = JSON.parse(File.read(path))
    items = payload.is_a?(Hash) ? (payload["items"] || [payload]) : Array(payload)
    results = RecompIngest::Ingestor.new.ingest_many(items)
    puts JSON.pretty_generate(results)
  end

  desc "Crawl configured recomp/decomp sources and ingest discovered items"
  task :crawl, [:limit] => :environment do |_t, args|
    limit = args[:limit].presence&.to_i
    run =
      Jobs::CrawlRecompSources.new.execute(
        limit: limit,
        force: true,
        sync: true,
        raise_errors: true,
      )

    output = {
      run_id: run&.id,
      status: run&.status,
      started_at: run&.started_at,
      finished_at: run&.finished_at,
      created_count: run&.created_count,
      updated_count: run&.updated_count,
      skipped_count: run&.skipped_count,
      error_count: run&.error_count,
      summary: run&.summary,
    }
    puts JSON.pretty_generate(output)
  end
end
