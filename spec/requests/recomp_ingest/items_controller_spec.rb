# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecompIngest::ItemsController do
  fab!(:admin)
  fab!(:user)
  fab!(:releases_category) { Fabricate(:category, name: "Releases", slug: "releases") }

  before do
    SiteSetting.recomp_ingest_enabled = true
    SiteSetting.recomp_ingest_default_category = "releases"
  end

  it "rejects non-admin users" do
    sign_in(user)
    post "/recomp-ingest/items.json",
         params: {
           item: {
             title: "Unauthorized Game",
             source_url: "https://github.com/example/unauth",
           },
         }
    expect(response.status).to eq(403)
    expect(response.parsed_body["errors"]).to be_present
  end

  it "ingests items for admin users and persists Entry and Alias rows" do
    sign_in(admin)
    post "/recomp-ingest/items.json",
         params: {
           item: {
             title: "OpenRCT2",
             source_url: "https://github.com/OpenRCT2/OpenRCT2",
             original_system: "pc",
             method_tags: %w[decomp playable],
             stars: 14_000,
             summary: "Open-source re-implementation of RollerCoaster Tycoon 2.",
           },
         }

    expect(response.status).to eq(200)
    body = response.parsed_body
    expect(body["results"].first["status"]).to eq("created")
    topic_id = body["results"].first["topic_id"]
    expect(RecompIngest::Entry.find_by(topic_id: topic_id)&.canonical_repo).to eq(
      "github:openrct2/openrct2",
    )
  end
end
