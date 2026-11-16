# frozen_string_literal: true

module RecompIngest
  class Run < ::ActiveRecord::Base
    self.table_name = "recomp_ingest_runs"

    STATUSES = %w[running completed failed].freeze

    validates :status, presence: true

    def self.record_batch_results!(run_id, created: 0, updated: 0, skipped: 0, errors: 0)
      return nil if run_id.blank?

      where(id: run_id).update_all(
        [
          "created_count = created_count + ?, " \
            "updated_count = updated_count + ?, " \
            "skipped_count = skipped_count + ?, " \
            "error_count = error_count + ?, " \
            "summary = jsonb_set(" \
            "COALESCE(summary, '{}'::jsonb), " \
            "'{completed_batches}', " \
            "(COALESCE((summary->>'completed_batches')::int, 0) + 1)::text::jsonb, " \
            "true" \
            "), " \
            "updated_at = NOW()",
          created.to_i,
          updated.to_i,
          skipped.to_i,
          errors.to_i,
        ],
      )

      run = find_by(id: run_id)
      return nil unless run

      run.with_lock do
        total_batches = run.summary.is_a?(Hash) ? run.summary["total_batches"] : nil
        completed_batches =
          run.summary.is_a?(Hash) ? run.summary["completed_batches"].to_i : 1

        if total_batches.nil? || completed_batches >= total_batches.to_i
          run.update!(status: "completed", finished_at: Time.zone.now)
        end
      end

      run
    end
  end
end
