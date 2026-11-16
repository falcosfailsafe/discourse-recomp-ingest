# frozen_string_literal: true

namespace :recomp_ingest do
  desc "Import recomp/decomp items from a JSON file"
  task :import, [:file_path] => :environment do |_t, args|
    path = args[:file_path]
    raise "Usage: bin/rails recomp_ingest:import[/path/to/items.json]" if path.blank? || !File.exist?(path)

    payload = JSON.parse(File.read(path))
    items = payload.is_a?(Hash) ? (payload["items"] || [payload]) : Array(payload)
    results = RecompIngest::Ingestor.new.ingest_many(items)
    puts JSON.pretty_generate(results)
  end
end
