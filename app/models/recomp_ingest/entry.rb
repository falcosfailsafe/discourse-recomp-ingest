# frozen_string_literal: true

module RecompIngest
  class Entry < ::ActiveRecord::Base
    self.table_name = "recomp_ingest_entries"

    belongs_to :topic, optional: true
    has_many :aliases,
             class_name: "RecompIngest::Alias",
             foreign_key: :recomp_ingest_entry_id,
             dependent: :destroy,
             inverse_of: :entry

    before_validation :normalize_fields

    def register_aliases!(alias_tuples, default_source_name: nil)
      return if alias_tuples.blank?

      now = Time.zone.now
      rows =
        alias_tuples
          .filter_map do |tuple|
            kind = tuple[:kind].to_s.strip
            value = tuple[:value].to_s.strip
            next if kind.blank? || value.blank?

            {
              recomp_ingest_entry_id: id,
              kind: kind,
              value: value,
              source_name: (tuple[:source_name].presence || default_source_name),
              created_at: now,
              updated_at: now,
            }
          end
          .uniq { |r| [r[:kind], r[:value]] }

      return if rows.empty?

      RecompIngest::Alias.insert_all(rows, unique_by: %i[kind value])
    end

    private

    def normalize_fields
      self.canonical_repo = canonical_repo.to_s.strip.downcase.presence
      self.canonical_url = canonical_url.to_s.strip.presence
      self.dedup_key = dedup_key.to_s.strip.downcase.presence
      self.original_system = original_system.to_s.strip.downcase.presence
      self.stars = stars.to_i
      self.downloads = downloads.to_i
    end
  end
end
