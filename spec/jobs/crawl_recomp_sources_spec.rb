# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::CrawlRecompSources do
  subject(:crawl_job) { described_class.new }

  fab!(:releases_category) { Fabricate(:category, name: "Releases", slug: "releases") }

  let(:sample_items) do
    (1..3).map do |idx|
      {
        source_url: "https://github.com/example/game-#{idx}",
        alt_urls: [],
        repo: "github:example/game-#{idx}",
        dedup_key: "github:example/game-#{idx}",
        external_ids: ["adg:game-#{idx}"],
        title: "Sample Game #{idx}",
        category: "releases",
        original_system: "n64",
        game_tag: "sample-game-#{idx}",
        method_tags: %w[recomp playable],
        target_platforms: %w[Windows Linux],
        cover_image_url: nil,
        cover_svg: nil,
        stars: 50 * idx,
        downloads: 0,
        sources: ["Awesome Decomp Games"],
        summary: "Summary for sample game #{idx}.",
      }
    end
  end

  before do
    Jobs.run_later!
    SiteSetting.recomp_ingest_enabled = true
    SiteSetting.recomp_ingest_crawl_enabled = true
    SiteSetting.recomp_ingest_default_category = "releases"
    SiteSetting.recomp_ingest_batch_size = 2
    SiteSetting.recomp_ingest_update_existing = true
  end

  it "does not run when recomp_ingest_crawl_enabled is false unless forced" do
    SiteSetting.recomp_ingest_crawl_enabled = false
    expect(RecompIngest::Crawler).not_to receive(:new)

    expect { crawl_job.execute({}) }.not_to change { RecompIngest::Run.count }
  end

  it "creates a Run, filters unchanged items by content_hash, chunks into batches, and updates Run counters via IngestRecompBatch" do
    # Pre-ingest item 1 so its content_hash already matches in Postgres
    pre_res = RecompIngest::Ingestor.new.ingest_one(sample_items.first)
    expect(pre_res[:status]).to eq("created")

    crawler_double = instance_double(RecompIngest::Crawler)
    allow(RecompIngest::Crawler).to receive(:new).and_return(crawler_double)
    allow(crawler_double).to receive(:crawl).and_return(
      items: sample_items,
      stats: { total_raw: 3, unique_merged: 3, matched_count: 3, selected_count: 3 },
    )

    Sidekiq::Testing.fake! do
      Jobs::IngestRecompBatch.jobs.clear

      run = crawl_job.execute({})
      expect(run).to be_present
      expect(run.status).to eq("running")
      expect(run.skipped_count).to eq(1)
      expect(run.summary["unchanged_skipped"]).to eq(1)
      expect(run.summary["enqueued_items"]).to eq(2)
      expect(run.summary["total_batches"]).to eq(1)

      expect(Jobs::IngestRecompBatch.jobs.size).to eq(1)
      batch_args = Jobs::IngestRecompBatch.jobs.first["args"].first
      expect(batch_args["items"].size).to eq(2)

      # Execute the enqueued batch job and verify atomic Run counter updates + completion
      Jobs::IngestRecompBatch.new.execute(batch_args)

      run.reload
      expect(run.status).to eq("completed")
      expect(run.finished_at).to be_present
      expect(run.created_count).to eq(2)
      expect(run.updated_count).to eq(0)
      expect(run.skipped_count).to eq(1)
      expect(run.error_count).to eq(0)
      expect(run.summary["completed_batches"]).to eq(1)
    end
  end

  it "chunks enqueued items according to recomp_ingest_batch_size and completes only after all batches finish" do
    SiteSetting.recomp_ingest_batch_size = 2

    crawler_double = instance_double(RecompIngest::Crawler)
    allow(RecompIngest::Crawler).to receive(:new).and_return(crawler_double)
    allow(crawler_double).to receive(:crawl).and_return(
      items: sample_items,
      stats: { total_raw: 3, unique_merged: 3 },
    )

    Sidekiq::Testing.fake! do
      Jobs::IngestRecompBatch.jobs.clear

      run = crawl_job.execute({})
      expect(Jobs::IngestRecompBatch.jobs.size).to eq(2)
      expect(run.summary["total_batches"]).to eq(2)

      first_args = Jobs::IngestRecompBatch.jobs[0]["args"].first
      second_args = Jobs::IngestRecompBatch.jobs[1]["args"].first
      expect(first_args["items"].size).to eq(2)
      expect(second_args["items"].size).to eq(1)

      Jobs::IngestRecompBatch.new.execute(first_args)
      expect(run.reload.status).to eq("running")
      expect(run.created_count).to eq(2)

      Jobs::IngestRecompBatch.new.execute(second_args)
      expect(run.reload.status).to eq("completed")
      expect(run.created_count).to eq(3)
      expect(run.finished_at).to be_present
    end
  end
end
