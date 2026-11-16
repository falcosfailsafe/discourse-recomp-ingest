# frozen_string_literal: true

require "net/http"

module Jobs
  class PollRecompFeed < ::Jobs::Scheduled
    every 6.hours

    def execute(args)
      return unless SiteSetting.recomp_ingest_enabled
      feed_url = SiteSetting.recomp_ingest_feed_url.to_s.strip
      return if feed_url.blank?

      uri = URI.parse(feed_url)
      response = Net::HTTP.get_response(uri)
      return unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      items = payload.is_a?(Hash) ? (payload["items"] || [payload]) : Array(payload)
      RecompIngest::Ingestor.new.ingest_many(items)
    rescue StandardError => e
      Rails.logger.warn("[RecompIngest] PollRecompFeed error: #{e.message}")
    end
  end
end
