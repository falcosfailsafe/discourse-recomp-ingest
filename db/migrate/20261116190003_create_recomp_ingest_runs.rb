# frozen_string_literal: true

class CreateRecompIngestRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :recomp_ingest_runs do |t|
      t.datetime :started_at
      t.datetime :finished_at
      t.string :status, null: false, default: "running"
      t.integer :created_count, null: false, default: 0
      t.integer :updated_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.jsonb :summary, null: false, default: {}

      t.timestamps
    end
  end
end
