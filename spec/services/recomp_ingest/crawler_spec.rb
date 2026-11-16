# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecompIngest::Crawler do
  before do
    SiteSetting.recomp_ingest_sources = "awesome_decomp_games|recomplauncher|recomp_gg"
    SiteSetting.recomp_ingest_min_stars = 5
  end

  let(:adg_payload) do
    {
      "games" => [
        {
          "id" => "zelda64recomp",
          "title" => "The Legend of Zelda: Majora's Mask (N64)",
          "url" => "https://github.com/Zelda64Recomp/Zelda64Recomp.git",
          "homepage" => "https://zelda64.recomp.dev/",
          "platform" => "Nintendo 64",
          "type" => "static-recomp",
          "stars" => 5000,
          "release" => "v1.2.0",
          "description" => "Short description.",
          "og_image" => "https://example.com/adg-og.png",
          "archived" => false,
        },
        {
          "id" => "n64recomp-tool",
          "title" => "N64: Recompiled & Tools",
          "url" => "https://github.com/N64Recomp/N64Recomp",
          "platform" => "Nintendo 64",
          "type" => "tool",
          "stars" => 3200,
          "description" => "Tool to statically recompile N64 binaries into C.",
          "archived" => false,
        },
        {
          "id" => "mystery-dungeon-title-merge",
          "title" => "Chrono Trigger Remake",
          "url" => "https://github.com/example/chrono-decomp",
          "platform" => "Super Nintendo",
          "type" => "decompilation",
          "stars" => 120,
          "description" => "SNES decompilation of Chrono Trigger.",
          "archived" => false,
        },
      ],
    }
  end

  let(:recomplauncher_payload) do
    {
      "apps" => [
        {
          "id" => "zelda64recomp",
          "name" => "Zelda 64: Recompiled",
          "game" => "The Legend of Zelda: Majora's Mask",
          "repo" => "Zelda64Recomp/Zelda64Recomp",
          "host" => "github",
          "origin" => "N64",
          "stars" => 5400,
          "downloads" => 85_000,
          "version" => "v1.2.1",
          "blurb" =>
            "Much longer description of Zelda 64: Recompiled with raytracing, high framerate, and gyro aiming.",
          "hero" => "https://recomplauncher.com/art/zelda-hero.webp",
          "cover" => "https://recomplauncher.com/art/zelda-cover.webp",
          "systems" => %w[windows linux macos],
          "ai" => { "uses" => %w[lifting tooling] },
        },
      ],
    }
  end

  let(:recompgg_games_payload) do
    {
      "games" => [
        {
          "slug" => "chrono-trigger-snes",
          "title" => "Chrono Trigger Remake",
          "year" => 1995,
          "platform" => "SNES",
          "page" => "https://recomp.gg/g/chrono-trigger-snes",
          "project" => {
            "kind" => "decompilation",
            "kindLabel" => "Cleanroom Port",
          },
          "play" => {
            "url" => "https://play.recomp.gg/chrono",
          },
        },
      ],
    }
  end

  let(:recompgg_projects_p1) do
    {
      "items" => [
        {
          "slug" => "zelda64recomp",
          "name" => "Zelda64Recomp",
          "nature" => "game",
          "method" => "static-recomp",
          "repoUrl" => "https://github.com/Zelda64Recomp/Zelda64Recomp",
          "url" => "https://recomp.gg/p/zelda64recomp",
          "stars" => 5350,
          "ai" => false,
        },
      ],
      "page" => {
        "hasMore" => true,
        "nextCursor" => "cursor_page_2",
      },
    }
  end

  let(:recompgg_projects_p2) do
    {
      "items" => [
        {
          "slug" => "ps2-port",
          "name" => "Jak & Daxter OpenGOAL",
          "nature" => "game",
          "method" => "reimplementation",
          "homeUrl" => "https://opengoal.dev",
          "url" => "https://recomp.gg/p/opengoal",
          "stars" => 40,
          "ai" => true,
        },
      ],
      "page" => {
        "hasMore" => false,
        "nextCursor" => nil,
      },
    }
  end

  before do
    stub_request(:get, RecompIngest::Crawler::ADG_URL).to_return(
      status: 200,
      body: JSON.generate(adg_payload),
      headers: { "Content-Type" => "application/json" },
    )
    stub_request(:get, RecompIngest::Crawler::RECOMPLAUNCHER_URL).to_return(
      status: 200,
      body: JSON.generate(recomplauncher_payload),
      headers: { "Content-Type" => "application/json" },
    )
    stub_request(:get, RecompIngest::Crawler::RECOMPGG_GAMES_URL).to_return(
      status: 200,
      body: JSON.generate(recompgg_games_payload),
      headers: { "Content-Type" => "application/json" },
    )
    stub_request(:get, "#{RecompIngest::Crawler::RECOMPGG_PROJECTS_URL}?limit=100").to_return(
      status: 200,
      body: JSON.generate(recompgg_projects_p1),
      headers: { "Content-Type" => "application/json" },
    )
    stub_request(
      :get,
      "#{RecompIngest::Crawler::RECOMPGG_PROJECTS_URL}?limit=100&cursor=cursor_page_2",
    ).to_return(
      status: 200,
      body: JSON.generate(recompgg_projects_p2),
      headers: { "Content-Type" => "application/json" },
    )
  end

  it "fetches, normalizes, merges across all 3 sources, ranks, and generates SVG fallback covers" do
    result = described_class.new.crawl
    items = result[:items]
    stats = result[:stats]

    expect(stats[:merged_by_repo]).to be >= 2
    expect(stats[:merged_by_title]).to be >= 1
    expect(items.size).to eq(4)

    # Highest ranked item should be the 3-source merged Zelda64Recomp entry with hero artwork
    zelda = items.first
    expect(zelda[:repo]).to eq("github:zelda64recomp/zelda64recomp")
    expect(zelda[:title]).to eq("Zelda 64: Recompiled — The Legend of Zelda: Majora's Mask")
    expect(zelda[:original_system]).to eq("n64")
    expect(zelda[:stars]).to eq(5400)
    expect(zelda[:downloads]).to eq(85_000)
    expect(zelda[:cover_image_url]).to eq("https://recomplauncher.com/art/zelda-hero.webp")
    expect(zelda[:cover_svg]).to be_nil
    expect(zelda[:sources]).to contain_exactly(
      "Awesome Decomp Games",
      "RecompLauncher",
      "recomp.gg",
    )
    expect(zelda[:external_ids]).to include(
      "adg:zelda64recomp",
      "rl:zelda64recomp",
      "rgg-p:zelda64recomp",
    )
    expect(zelda[:method_tags]).to include("recomp", "playable", "ai-rewrite")
    expect(zelda[:target_platforms]).to include("Windows", "Linux", "macOS")
    expect(zelda[:ai_notes]).to include("lifting, tooling")

    # Chrono Trigger merged across ADG + recomp.gg by (title, system)
    chrono = items.find { |i| i[:repo] == "github:example/chrono-decomp" }
    expect(chrono).to be_present
    expect(chrono[:original_system]).to eq("snes")
    expect(chrono[:play_url]).to eq("https://play.recomp.gg/chrono")
    expect(chrono[:sources]).to contain_exactly("Awesome Decomp Games", "recomp.gg")
    expect(chrono[:cover_image_url]).to be_nil
    expect(chrono[:cover_svg]).to include("<svg")
    expect(chrono[:cover_svg]).to include("SNES")

    # Tool entry gets ai-tooling category and XML-escaped SVG cover
    tool = items.find { |i| i[:repo] == "github:n64recomp/n64recomp" }
    expect(tool).to be_present
    expect(tool[:category]).to eq("ai-tooling")
    expect(tool[:method_tags]).to eq(["tooling"])
    expect(tool[:cover_svg]).to include("N64: Recompiled &amp; Tools")
  end

  describe ".normalize_system" do
    it "normalizes platform aliases without substring collisions" do
      expect(described_class.normalize_system("Nintendo 64")).to eq("n64")
      expect(described_class.normalize_system("Sony PlayStation 2")).to eq("ps2")
      expect(described_class.normalize_system("PlayStation")).to eq("ps1")
      expect(described_class.normalize_system("Game Boy Advance")).to eq("gba")
      expect(described_class.normalize_system("Game Boy Color")).to eq("gbc")
      expect(described_class.normalize_system("Xbox 360")).to eq("xbox360")
      expect(described_class.normalize_system("Wii U")).to eq("wiiu")
      expect(described_class.normalize_system(nil)).to eq("pc")
    end
  end
end
