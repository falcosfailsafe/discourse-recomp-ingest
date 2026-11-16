# frozen_string_literal: true

class CreateRecompIngestAliases < ActiveRecord::Migration[7.0]
  def change
    create_table :recomp_ingest_aliases do |t|
      t.bigint :recomp_ingest_entry_id, null: false
      t.string :kind, null: false
      t.string :value, null: false
      t.string :source_name

      t.timestamps
    end

    add_index :recomp_ingest_aliases, :recomp_ingest_entry_id
    add_index :recomp_ingest_aliases, %i[kind value], unique: true
    add_foreign_key :recomp_ingest_aliases,
                    :recomp_ingest_entries,
                    column: :recomp_ingest_entry_id,
                    on_delete: :cascade
  end
end
