# frozen_string_literal: true

module RecompIngest
  class Alias < ::ActiveRecord::Base
    self.table_name = "recomp_ingest_aliases"

    KINDS = %w[repo url external_id dedup_key].freeze

    belongs_to :entry,
               class_name: "RecompIngest::Entry",
               foreign_key: :recomp_ingest_entry_id,
               inverse_of: :aliases

    before_validation :normalize_fields

    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :value, presence: true

    private

    def normalize_fields
      self.kind = kind.to_s.strip.downcase
      self.value = value.to_s.strip
    end
  end
end
