# frozen_string_literal: true

module Jobs
  class IngestRecompBatch < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.recomp_ingest_enabled

      run_id = args[:run_id] || args["run_id"]
      items = Array(args[:items] || args["items"])
      update_existing =
        if args.key?(:update_existing)
          ActiveModel::Type::Boolean.new.cast(args[:update_existing])
        elsif args.key?("update_existing")
          ActiveModel::Type::Boolean.new.cast(args["update_existing"])
        else
          SiteSetting.recomp_ingest_update_existing
        end

      created = 0
      updated = 0
      skipped = 0
      errors = 0

      ingestor = RecompIngest::Ingestor.new
      items.each do |raw_item|
        begin
          item = raw_item.respond_to?(:to_unsafe_h) ? raw_item.to_unsafe_h : raw_item.to_h
          result = ingestor.ingest_one(item, update_existing: update_existing)
          case result[:status]
          when "created"
            created += 1
          when "updated"
            updated += 1
          when "skipped", "duplicate"
            skipped += 1
          else
            errors += 1
          end
        rescue StandardError => e
          errors += 1
          Rails.logger.warn("[RecompIngest] IngestRecompBatch item error: #{e.message}")
        end
      end

      if run_id.present?
        RecompIngest::Run.record_batch_results!(
          run_id,
          created: created,
          updated: updated,
          skipped: skipped,
          errors: errors,
        )
      end

      { created: created, updated: updated, skipped: skipped, errors: errors }
    end
  end
end
