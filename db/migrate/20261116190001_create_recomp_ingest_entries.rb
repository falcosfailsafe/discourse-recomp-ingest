# frozen_string_literal: true

class CreateRecompIngestEntries < ActiveRecord::Migration[7.0]
  def change
    create_table :recomp_ingest_entries do |t|
      t.bigint :topic_id
      t.string :canonical_repo
      t.string :canonical_url
      t.string :dedup_key
      t.string :title
      t.string :original_system
      t.integer :stars, null: false, default: 0
      t.integer :downloads, null: false, default: 0
      t.string :cover_source_url
      t.string :content_hash
      t.datetime :last_seen_at
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :recomp_ingest_entries, :topic_id
    add_index :recomp_ingest_entries,
              :canonical_repo,
              unique: true,
              where: "canonical_repo IS NOT NULL"
    add_index :recomp_ingest_entries, :canonical_url
    add_index :recomp_ingest_entries,
              :dedup_key,
              unique: true,
              where: "dedup_key IS NOT NULL"
  end
end
