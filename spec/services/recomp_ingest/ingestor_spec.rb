# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecompIngest::Ingestor do
  subject(:ingestor) { described_class.new }

  fab!(:releases_category) { Fabricate(:category, name: "Releases", slug: "releases") }

  before do
    SiteSetting.recomp_ingest_enabled = true
    SiteSetting.recomp_ingest_default_category = "releases"
    SiteSetting.tagging_enabled = true
  end

  describe "Postgres Entry & Alias deduplication" do
    it "creates Entry and Alias rows and deduplicates across repo, URL, alt_url, external_id, and dedup_key" do
      base_item = {
        title: "Zelda 64: Recompiled — Majora's Mask",
        source_url: "https://github.com/Zelda64Recomp/Zelda64Recomp",
        alt_urls: ["https://recomplauncher.com/game/zelda64recomp"],
        repo: "github:zelda64recomp/zelda64recomp",
        dedup_key: "title:majorasmask|n64",
        external_ids: ["adg:zelda64recomp", "rl:zelda64recomp"],
        original_system: "n64",
        method_tags: %w[recomp playable],
        stars: 5200,
        downloads: 12_000,
        sources: ["Awesome Decomp Games", "RecompLauncher"],
        summary: "Static recompilation of Majora's Mask for PC.",
      }

      res = ingestor.ingest_one(base_item)
      expect(res[:status]).to eq("created")

      entry = RecompIngest::Entry.find_by(topic_id: res[:topic_id])
      expect(entry).to be_present
      expect(entry.canonical_repo).to eq("github:zelda64recomp/zelda64recomp")
      expect(entry.canonical_url).to eq("https://github.com/Zelda64Recomp/Zelda64Recomp")
      expect(entry.dedup_key).to eq("title:majorasmask|n64")
      expect(entry.stars).to eq(5200)
      expect(entry.downloads).to eq(12_000)
      expect(entry.content_hash).to be_present

      expect(entry.aliases.where(kind: "repo").pluck(:value)).to include(
        "github:zelda64recomp/zelda64recomp",
        "zelda64recomp/zelda64recomp",
      )
      expect(entry.aliases.where(kind: "url").pluck(:value)).to include(
        "https://github.com/zelda64recomp/zelda64recomp",
        "https://recomplauncher.com/game/zelda64recomp",
      )
      expect(entry.aliases.where(kind: "external_id").pluck(:value)).to include(
        "adg:zelda64recomp",
        "rl:zelda64recomp",
      )

      # Match by canonical_repo (with different URL)
      by_repo =
        ingestor.ingest_one(
          {
            title: "Zelda64Recomp Mirror",
            source_url: "https://example.org/mirror",
            repo: "zelda64recomp/zelda64recomp",
          },
        )
      expect(by_repo).to include(status: "duplicate", topic_id: res[:topic_id], matched_by: "repo")

      # Match by alt_url as incoming source_url
      by_url =
        ingestor.ingest_one(
          {
            title: "Zelda64Recomp RL",
            source_url: "https://recomplauncher.com/game/zelda64recomp/",
          },
        )
      expect(by_url).to include(
        status: "duplicate",
        topic_id: res[:topic_id],
        matched_by: "source_url",
      )

      # Match by incoming alt_urls hitting stored URL alias
      by_alt =
        ingestor.ingest_one(
          {
            title: "Zelda64Recomp Alt",
            source_url: "https://recomp.gg/g/mm",
            alt_urls: ["https://recomplauncher.com/game/zelda64recomp"],
          },
        )
      expect(by_alt).to include(
        status: "duplicate",
        topic_id: res[:topic_id],
        matched_by: "alt_url",
      )

      # Match by external_ids
      by_ext =
        ingestor.ingest_one(
          {
            title: "Zelda64Recomp External",
            source_url: "https://another.example.org/mm",
            external_ids: ["rl:zelda64recomp"],
          },
        )
      expect(by_ext).to include(
        status: "duplicate",
        topic_id: res[:topic_id],
        matched_by: "external_id",
      )

      # Match by dedup_key
      by_dedup =
        ingestor.ingest_one(
          {
            title: "Majora's Mask N64",
            source_url: "https://yetanother.example.org/mm",
            dedup_key: "title:majorasmask|n64",
          },
        )
      expect(by_dedup).to include(
        status: "duplicate",
        topic_id: res[:topic_id],
        matched_by: "dedup_key",
      )
    end
  end

  describe "legacy TopicCustomField fallback and backfill" do
    it "matches legacy custom fields and backfills Entry and Alias rows" do
      post =
        PostCreator.create!(
          Discourse.system_user,
          title: "Legacy Wipeout Rewrite",
          raw: "Legacy imported topic body for Wipeout Rewrite.",
          category: releases_category.id,
          skip_validations: true,
        )
      topic = post.topic
      topic.custom_fields["recomp_source_url"] = "https://github.com/phoboslab/wipeout-rewrite"
      topic.custom_fields["recomp_repo"] = "phoboslab/wipeout-rewrite"
      topic.custom_fields["recomp_external_ids"] = "adg:wipeout-rewrite"
      topic.custom_fields["recomp_alt_urls"] = "https://phoboslab.org/wipeout"
      topic.save_custom_fields(true)

      expect(RecompIngest::Entry.find_by(topic_id: topic.id)).to be_nil

      res =
        ingestor.ingest_one(
          {
            title: "Wipeout Rewrite",
            source_url: "https://recomplauncher.com/game/wipeout",
            external_ids: ["adg:wipeout-rewrite", "rl:wipeout"],
            original_system: "ps1",
          },
        )

      expect(res).to include(
        status: "duplicate",
        topic_id: topic.id,
        matched_by: "external_id",
      )

      entry = RecompIngest::Entry.find_by(topic_id: topic.id)
      expect(entry).to be_present
      expect(entry.canonical_repo).to eq("github:phoboslab/wipeout-rewrite")
      expect(entry.aliases.where(kind: "external_id").pluck(:value)).to include(
        "adg:wipeout-rewrite",
        "rl:wipeout",
      )
      expect(entry.aliases.where(kind: "url").pluck(:value)).to include(
        "https://phoboslab.org/wipeout",
        "https://recomplauncher.com/game/wipeout",
      )

      # Even if legacy custom fields are deleted, Postgres Entry/Alias dedup now matches directly
      TopicCustomField.where(topic_id: topic.id).delete_all

      res2 =
        ingestor.ingest_one(
          {
            title: "Wipeout Rewrite",
            source_url: "https://phoboslab.org/wipeout",
          },
        )
      expect(res2).to include(status: "duplicate", topic_id: topic.id)
    end
  end

  describe "cover_source_url and content_hash skip behavior" do
    let(:png_bytes) do
      # Minimal valid 1x1 PNG
      Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      )
    end

    def make_png_tempfile
      tf = Tempfile.new(["test-cover", ".png"])
      tf.binmode
      tf.write(png_bytes)
      tf.rewind
      tf
    end

    it "skips FileHelper.download, UploadCreator, and PostRevisor when content_hash is unchanged" do
      allow(FileHelper).to receive(:download).and_return(make_png_tempfile)

      item = {
        title: "Sonic Unleashed Recompiled",
        source_url: "https://github.com/hedge-dev/UnleashedRecomp",
        original_system: "xbox360",
        method_tags: %w[recomp playable],
        cover_image_url: "https://recomplauncher.com/covers/unleashed.png",
        stars: 4100,
        summary: "Xbox 360 static recompilation of Sonic Unleashed.",
      }

      created = ingestor.ingest_one(item)
      expect(created[:status]).to eq("created")
      topic = Topic.find(created[:topic_id])
      expect(topic.first_post.raw).to match(%r{\A!\[Sonic Unleashed Recompiled\]\(upload://})

      expect(FileHelper).not_to receive(:download)
      expect(UploadCreator).not_to receive(:new)
      expect(PostRevisor).not_to receive(:new)

      unchanged = ingestor.ingest_one(item, update_existing: true)
      expect(unchanged[:status]).to eq("skipped")
      expect(unchanged[:reason]).to eq("unchanged")
      expect(unchanged[:topic_id]).to eq(topic.id)
    end

    it "skips FileHelper.download and UploadCreator but runs PostRevisor when cover_source_url is unchanged and metadata changes" do
      allow(FileHelper).to receive(:download).once.and_return(make_png_tempfile)

      item = {
        title: "Star Fox 64: Recompiled",
        source_url: "https://github.com/Sonicdcer/Starfox64Recomp",
        original_system: "n64",
        method_tags: %w[recomp playable],
        cover_image_url: "https://recomplauncher.com/covers/sf64.png",
        stars: 1800,
        summary: "Initial release summary.",
      }

      created = ingestor.ingest_one(item)
      expect(created[:status]).to eq("created")
      topic = Topic.find(created[:topic_id])
      original_upload_match = topic.first_post.raw.match(%r{\((upload://[^)]+)\)})
      expect(original_upload_match).to be_present
      original_short_url = original_upload_match[1]

      expect(FileHelper).not_to receive(:download)
      expect(UploadCreator).not_to receive(:new)
      expect(PostRevisor).to receive(:new).and_call_original

      updated_item =
        item.merge(
          stars: 2500,
          release_version: "v1.1.0",
          summary: "Updated release summary with ultrawide support.",
        )

      updated = ingestor.ingest_one(updated_item, update_existing: true)
      expect(updated[:status]).to eq("updated")

      topic.reload
      expect(topic.first_post.raw).to include(original_short_url)
      expect(topic.first_post.raw).to include("Updated release summary with ultrawide support.")
      expect(topic.first_post.raw).to include("v1.1.0")
    end

    it "uploads SVG fallback cover via Tempfile + UploadCreator and reuses it when unchanged" do
      svg =
        RecompIngest::Crawler.make_svg(
          "Super Mario 64",
          "n64",
          "decomp",
          "Awesome Decomp Games",
        )

      item = {
        title: "Super Mario 64",
        source_url: "https://github.com/n64decomp/sm64",
        original_system: "n64",
        method_tags: %w[decomp playable],
        cover_svg: svg,
        summary: "Decompilation of Super Mario 64.",
      }

      created = ingestor.ingest_one(item)
      expect(created[:status]).to eq("created")
      topic = Topic.find(created[:topic_id])
      expect(topic.first_post.raw).to match(%r{\A!\[Super Mario 64\]\(upload://.*\.svg\)})

      entry = RecompIngest::Entry.find_by(topic_id: topic.id)
      expect(entry.cover_source_url).to start_with("svg:sha256:")

      expect(UploadCreator).not_to receive(:new)
      updated =
        ingestor.ingest_one(
          item.merge(summary: "Updated SM64 decomp summary."),
          update_existing: true,
        )
      expect(updated[:status]).to eq("updated")
      expect(topic.reload.first_post.raw).to include("Updated SM64 decomp summary.")
    end
  end
end
