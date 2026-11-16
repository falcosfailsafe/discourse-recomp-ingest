# frozen_string_literal: true

module Jobs
  class CrawlRecompSources < ::Jobs::Scheduled
    every 6.hours

    def execute(args = {})
      opts = (args || {}).symbolize_keys
      return unless SiteSetting.recomp_ingest_enabled
      return unless SiteSetting.recomp_ingest_crawl_enabled || opts[:force]

      run =
        RecompIngest::Run.create!(
          started_at: Time.zone.now,
          status: "running",
          summary: {},
        )

      crawler =
        RecompIngest::Crawler.new(
          sources: opts[:sources],
          min_stars: opts[:min_stars],
          include_archived: ActiveModel::Type::Boolean.new.cast(opts[:include_archived]),
        )
      crawl_result =
        crawler.crawl(
          limit: opts[:limit],
          system: opts[:system],
          method: opts[:method],
        )

      update_existing =
        if opts.key?(:update_existing)
          ActiveModel::Type::Boolean.new.cast(opts[:update_existing])
        else
          SiteSetting.recomp_ingest_update_existing
        end

      ingestor = RecompIngest::Ingestor.new
      items_to_enqueue = []
      unchanged_skipped = 0
      now = Time.zone.now

      crawl_result[:items].each do |item|
        existing_entry = ingestor.find_existing_entry(item)
        if existing_entry
          existing_entry.update_columns(last_seen_at: now, updated_at: now)
          if !update_existing
            unchanged_skipped += 1
            next
          end

          item_hash = RecompIngest::Ingestor.compute_content_hash(item)
          if existing_entry.content_hash.present? && existing_entry.content_hash == item_hash
            unchanged_skipped += 1
            next
          end
        end

        items_to_enqueue << item
      end

      batch_size = [SiteSetting.recomp_ingest_batch_size.to_i, 1].max
      batches = items_to_enqueue.each_slice(batch_size).to_a

      summary =
        crawl_result[:stats]
          .deep_stringify_keys
          .merge(
            "unchanged_skipped" => unchanged_skipped,
            "enqueued_items" => items_to_enqueue.size,
            "total_batches" => batches.size,
            "completed_batches" => 0,
          )

      if batches.empty?
        run.update!(
          skipped_count: unchanged_skipped,
          status: "completed",
          finished_at: Time.zone.now,
          summary: summary,
        )
        return run
      end

      run.update!(skipped_count: unchanged_skipped, summary: summary)

      batches.each do |batch|
        job_args = {
          run_id: run.id,
          items: batch.map(&:deep_stringify_keys),
          update_existing: update_existing,
        }
        if opts[:sync]
          Jobs::IngestRecompBatch.new.execute(job_args)
        else
          Jobs.enqueue(:ingest_recomp_batch, job_args)
        end
      end

      run.reload
    rescue StandardError => e
      if defined?(run) && run&.persisted?
        existing_summary = run.summary.is_a?(Hash) ? run.summary : {}
        run.update!(
          status: "failed",
          finished_at: Time.zone.now,
          error_count: run.error_count.to_i + 1,
          summary: existing_summary.merge("fatal_error" => e.message),
        )
      end
      Rails.logger.warn("[RecompIngest] CrawlRecompSources error: #{e.message}")
      raise if opts && opts[:raise_errors]

      run
    end
  end
end
