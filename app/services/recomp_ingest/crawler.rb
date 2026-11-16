# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"

module RecompIngest
  class Crawler
    class CrawlError < StandardError
    end

    ADG_URL =
      "https://raw.githubusercontent.com/SubmitGame/awesome-decomp-games/main/data/games.json"
    RECOMPLAUNCHER_URL = "https://recomplauncher.com/pc-catalog.json"
    RECOMPGG_GAMES_URL = "https://recomp.gg/api/games"
    RECOMPGG_PROJECTS_URL = "https://recomp.gg/api/v1/projects"
    USER_AGENT = "Mozilla/5.0 RecompDB-Crawler/2.0"
    MAX_REDIRECTS = 5

    SOURCE_ALIASES = {
      "awesome_decomp_games" => "awesome_decomp_games",
      "awesome-decomp-games" => "awesome_decomp_games",
      "adg" => "awesome_decomp_games",
      "recomplauncher" => "recomplauncher",
      "recomplauncher.com" => "recomplauncher",
      "recomp_gg" => "recomp_gg",
      "recompgg" => "recomp_gg",
      "recomp.gg" => "recomp_gg",
    }.freeze

    SYSTEM_MAP = {
      "n64" => "n64",
      "nintendo 64" => "n64",
      "ps1" => "ps1",
      "psx" => "ps1",
      "playstation" => "ps1",
      "ps2" => "ps2",
      "playstation 2" => "ps2",
      "ps3" => "ps3",
      "psp" => "psp",
      "snes" => "snes",
      "super nintendo" => "snes",
      "nes" => "nes",
      "gba" => "gba",
      "game boy advance" => "gba",
      "gb" => "gb",
      "game boy" => "gb",
      "gbc" => "gbc",
      "game boy color" => "gbc",
      "gamecube" => "gamecube",
      "gc" => "gamecube",
      "wii" => "wii",
      "wii u" => "wiiu",
      "wiiu" => "wiiu",
      "switch" => "switch",
      "ds" => "ds",
      "nintendo ds" => "ds",
      "3ds" => "3ds",
      "dreamcast" => "dreamcast",
      "dc" => "dreamcast",
      "saturn" => "saturn",
      "sega saturn" => "saturn",
      "genesis" => "genesis",
      "mega drive" => "genesis",
      "xbox" => "xbox",
      "og xbox" => "xbox",
      "xbox 360" => "xbox360",
      "xbox360" => "xbox360",
      "x360" => "xbox360",
      "dos" => "dos",
      "pc" => "pc",
      "arcade" => "arcade",
      "amiga" => "amiga",
    }.freeze

    SORTED_SYSTEM_PAIRS = SYSTEM_MAP.sort_by { |k, _| -k.length }.freeze

    SYSTEM_COLORS = {
      "n64" => %w[#22c55e #052e16 #14532d],
      "ps1" => %w[#94a3b8 #0f172a #334155],
      "ps2" => %w[#3b82f6 #0f172a #1e3a8a],
      "gamecube" => %w[#a855f7 #1e1b4b #4c1d95],
      "xbox360" => %w[#84cc16 #1a2e05 #365314],
      "xbox" => %w[#22c55e #052e16 #166534],
      "snes" => %w[#eab308 #27272a #713f12],
      "gba" => %w[#6366f1 #1e1b4b #312e81],
      "dreamcast" => %w[#f97316 #1c1917 #7c2d12],
      "saturn" => %w[#14b8a6 #042f2e #115e59],
      "dos" => %w[#facc15 #18181b #3f3f46],
      "pc" => %w[#38bdf8 #082f49 #0c4a6e],
    }.freeze

    DEFAULT_COLORS = %w[#38bdf8 #0f172a #1e293b].freeze

    def self.normalize_system(raw)
      return "pc" if raw.blank?

      key = raw.to_s.strip.downcase
      return SYSTEM_MAP[key] if SYSTEM_MAP.key?(key)

      SORTED_SYSTEM_PAIRS.each do |pattern, normalized|
        return normalized if key.include?(pattern)
      end

      "pc"
    end

    def self.normalize_url(url)
      RecompIngest::Ingestor.normalize_url(url)
    end

    def self.extract_repo_key(url_or_slug, host_hint: nil)
      return nil if url_or_slug.blank?

      s = url_or_slug.to_s.strip
      if s.match?(%r{\Ahttps?://}i)
        if (m = s.match(%r{\Ahttps?://(?:www\.)?github\.com/([^/]+/[^/?#]+)}i))
          return "github:#{m[1].sub(/\.git\z/i, "").downcase}"
        elsif (m = s.match(%r{\Ahttps?://(?:www\.)?gitlab\.com/([^/]+/[^/?#]+)}i))
          return "gitlab:#{m[1].sub(/\.git\z/i, "").downcase}"
        elsif (m = s.match(%r{\Ahttps?://(?:www\.)?codeberg\.org/([^/]+/[^/?#]+)}i))
          return "codeberg:#{m[1].sub(/\.git\z/i, "").downcase}"
        elsif (m = s.match(%r{\Ahttps?://git\.sr\.ht/(~[^/]+/[^/?#]+)}i))
          return "srht:#{m[1].sub(/\.git\z/i, "").downcase}"
        end
        return nil
      end

      if s.include?("/") && !s.include?(" ")
        cleaned = s.sub(%r{\A/+|/+\z}, "").sub(/\.git\z/i, "").downcase
        return cleaned if cleaned.include?(":")

        host = (host_hint.presence || "github").to_s.downcase
        return "#{host}:#{cleaned}"
      end

      nil
    end

    def self.slugify(text, max_len: 20)
      s = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      s[0, max_len].to_s.gsub(/\A-+|-+\z/, "")
    end

    def self.normalize_title_key(text)
      without_parens = text.to_s.gsub(/\([^)]*\)/, "")
      without_parens.downcase.gsub(/[^a-z0-9]+/, "")
    end

    def self.make_svg(title, system, method, subtitle_text)
      accent, bg1, bg2 = SYSTEM_COLORS[system.to_s.downcase] || DEFAULT_COLORS
      raw_title = title.to_s.split("—").first.to_s.strip[0, 36]
      raw_sub = subtitle_text.to_s.strip[0, 64]
      safe_title = CGI.escapeHTML(raw_title)
      safe_sub = CGI.escapeHTML(raw_sub)
      safe_sys = CGI.escapeHTML(system.to_s.upcase)
      safe_method = CGI.escapeHTML(method.to_s.upcase)

      <<~SVG.chomp
        <svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stop-color="#{bg1}"/>
              <stop offset="100%" stop-color="#{bg2}"/>
            </linearGradient>
            <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
              <path d="M 48 0 L 0 0 0 48" fill="none" stroke="#{accent}" stroke-opacity="0.14" stroke-width="1"/>
            </pattern>
          </defs>
          <rect width="1280" height="720" fill="url(#g)"/>
          <rect width="1280" height="720" fill="url(#grid)"/>
          <circle cx="1080" cy="140" r="240" fill="#{accent}" fill-opacity="0.14"/>
          <circle cx="180" cy="620" r="210" fill="#{accent}" fill-opacity="0.10"/>
          <rect x="72" y="72" width="1136" height="576" rx="28" fill="#09090b" fill-opacity="0.42" stroke="#{accent}" stroke-opacity="0.45" stroke-width="2"/>
          <rect x="116" y="132" width="180" height="44" rx="22" fill="#{accent}" fill-opacity="0.22" stroke="#{accent}" stroke-width="2"/>
          <text x="206" y="161" font-family="system-ui, sans-serif" font-size="20" font-weight="800" fill="#{accent}" text-anchor="middle">#{safe_sys}</text>
          <rect x="312" y="132" width="210" height="44" rx="22" fill="#ffffff" fill-opacity="0.10" stroke="#ffffff" stroke-opacity="0.25" stroke-width="1.5"/>
          <text x="417" y="161" font-family="system-ui, sans-serif" font-size="19" font-weight="700" fill="#f8fafc" text-anchor="middle">#{safe_method}</text>
          <text x="116" y="340" font-family="system-ui, sans-serif" font-size="54" font-weight="900" fill="#ffffff">#{safe_title}</text>
          <text x="116" y="405" font-family="system-ui, sans-serif" font-size="25" font-weight="500" fill="#cbd5e1">#{safe_sub}</text>
          <rect x="116" y="545" width="220" height="8" rx="4" fill="#{accent}"/>
          <text x="1160" y="595" font-family="monospace" font-size="20" font-weight="700" fill="#94a3b8" text-anchor="end">RecompDB</text>
        </svg>
      SVG
    end

    def self.deduplicate_and_merge(records)
      merged = []
      by_repo = {}
      by_url = {}
      by_title_sys = {}
      stats = {
        total_raw: records.size,
        merged_by_repo: 0,
        merged_by_url: 0,
        merged_by_title: 0,
      }

      records.each do |raw_rec|
        rec = raw_rec.symbolize_keys
        idx = nil

        if rec[:repo_key].present? && by_repo.key?(rec[:repo_key])
          idx = by_repo[rec[:repo_key]]
          stats[:merged_by_repo] += 1
        else
          all_urls = ([rec[:source_url]] + Array(rec[:alt_urls])).reject(&:blank?)
          all_urls.each do |u|
            ukey = u.downcase
            if by_url.key?(ukey)
              idx = by_url[ukey]
              stats[:merged_by_url] += 1
              break
            end
          end
        end

        if idx.nil?
          tkey = [normalize_title_key(rec[:title].to_s.split("—").first), rec[:system]]
          if tkey[0].length >= 4 && by_title_sys.key?(tkey)
            idx = by_title_sys[tkey]
            stats[:merged_by_title] += 1
          end
        end

        if idx.nil?
          alt_dedup = []
          seen_urls = { rec[:source_url].to_s.downcase => true }
          Array(rec[:alt_urls]).each do |u|
            next if u.blank? || seen_urls[u.downcase]

            seen_urls[u.downcase] = true
            alt_dedup << u
          end

          entry = {
            title: rec[:title].to_s,
            game_name: rec[:game_name].to_s,
            system: rec[:system].to_s,
            category: rec[:category].to_s,
            method_tags: Array(rec[:method_tags]).uniq,
            source_url: rec[:source_url].to_s,
            homepage_url: rec[:homepage_url],
            alt_urls: alt_dedup,
            repo_key: rec[:repo_key],
            external_ids: [rec[:external_id]].compact_blank,
            sources: [rec[:source_name]].compact_blank,
            stars: rec[:stars].to_i,
            downloads: rec[:downloads].to_i,
            release_version: rec[:release_version],
            description: rec[:description].to_s,
            target_platforms: Array(rec[:target_platforms]).uniq,
            cover_candidates: Array(rec[:cover_candidates]).dup,
            archived: ActiveModel::Type::Boolean.new.cast(rec[:archived]),
            ai_notes: rec[:ai_notes],
            play_url: rec[:play_url],
          }
          idx = merged.size
          merged << entry
        else
          entry = merged[idx]
          entry[:sources] << rec[:source_name] if rec[:source_name].present? && !entry[:sources].include?(rec[:source_name])
          entry[:external_ids] << rec[:external_id] if rec[:external_id].present? && !entry[:external_ids].include?(rec[:external_id])

          existing_url_keys =
            ([entry[:source_url]] + entry[:alt_urls]).map { |u| u.to_s.downcase }.to_set
          ([rec[:source_url]] + Array(rec[:alt_urls])).each do |u|
            next if u.blank? || existing_url_keys.include?(u.downcase)

            existing_url_keys.add(u.downcase)
            entry[:alt_urls] << u
          end

          entry[:stars] = [entry[:stars], rec[:stars].to_i].max
          entry[:downloads] = [entry[:downloads], rec[:downloads].to_i].max
          if rec[:description].to_s.length > entry[:description].to_s.length
            entry[:description] = rec[:description].to_s
          end
          if rec[:title].to_s.length > entry[:title].to_s.length && rec[:title].to_s.include?("—")
            entry[:title] = rec[:title].to_s
          end
          entry[:system] = rec[:system] if rec[:system] != "pc" && entry[:system] == "pc"
          entry[:repo_key] = rec[:repo_key] if entry[:repo_key].blank? && rec[:repo_key].present?
          entry[:homepage_url] = rec[:homepage_url] if entry[:homepage_url].blank? && rec[:homepage_url].present?
          entry[:release_version] = rec[:release_version] if entry[:release_version].blank? && rec[:release_version].present?
          entry[:play_url] = rec[:play_url] if entry[:play_url].blank? && rec[:play_url].present?
          entry[:ai_notes] = rec[:ai_notes] if entry[:ai_notes].blank? && rec[:ai_notes].present?

          Array(rec[:method_tags]).each do |m|
            entry[:method_tags] << m unless entry[:method_tags].include?(m)
          end
          Array(rec[:target_platforms]).each do |p|
            entry[:target_platforms] << p unless entry[:target_platforms].include?(p)
          end
          entry[:cover_candidates].concat(Array(rec[:cover_candidates]))
          entry[:archived] = entry[:archived] && ActiveModel::Type::Boolean.new.cast(rec[:archived])
        end

        by_repo[entry[:repo_key]] = idx if entry[:repo_key].present?
        ([entry[:source_url]] + entry[:alt_urls]).each do |u|
          by_url[u.downcase] = idx if u.present?
        end
        tkey = [normalize_title_key(entry[:title].to_s.split("—").first), entry[:system]]
        by_title_sys[tkey] = idx if tkey[0].length >= 4
      end

      stats[:unique_merged] = merged.size
      [merged, stats]
    end

    def self.score_entry(entry)
      s = Math.log10(entry[:stars].to_i + 1) * 25.0
      s += Math.log10(entry[:downloads].to_i + 1) * 15.0
      s += 30.0 if entry[:cover_candidates].present?
      s += 20.0 * (entry[:sources].size - 1) if entry[:sources].size >= 2
      if entry[:method_tags].include?("recomp") || entry[:method_tags].include?("ai-rewrite")
        s += 15.0
      end
      s += 10.0 if entry[:play_url].present?
      s -= 50.0 if entry[:archived]
      s.round(2)
    end

    def initialize(
      sources: nil,
      min_stars: nil,
      include_archived: false,
      max_recompgg_pages: 5,
      open_timeout: 15,
      read_timeout: 30
    )
      raw_sources = sources.nil? ? SiteSetting.recomp_ingest_sources : sources
      @enabled_sources = parse_sources(raw_sources)
      @min_stars = (min_stars.nil? ? SiteSetting.recomp_ingest_min_stars : min_stars).to_i
      @include_archived = include_archived
      @max_recompgg_pages = max_recompgg_pages
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def crawl(limit: nil, system: nil, method: nil)
      raw_records = []
      source_counts = {}
      source_errors = {}

      @enabled_sources.each do |src|
        begin
          loaded =
            case src
            when "awesome_decomp_games"
              load_awesome_decomp_games
            when "recomplauncher"
              load_recomplauncher
            when "recomp_gg"
              load_recomp_gg
            else
              []
            end
          source_counts[src] = loaded.size
          raw_records.concat(loaded)
        rescue StandardError => e
          Rails.logger.warn("[RecompIngest] Source #{src} failed: #{e.message}")
          source_errors[src] = e.message
        end
      end

      if @enabled_sources.any? && raw_records.empty? && source_errors.any?
        raise CrawlError, "All enabled sources failed: #{source_errors.inspect}"
      end

      merged, dedup_stats = self.class.deduplicate_and_merge(raw_records)

      filtered = []
      merged.each do |entry|
        next if !@include_archived && entry[:archived]
        next if entry[:stars] < @min_stars && entry[:play_url].blank? && entry[:downloads] < 500
        next if system.present? && entry[:system] != system.to_s.downcase
        next if method.present? && !entry[:method_tags].include?(method.to_s.downcase)

        entry[:score] = self.class.score_entry(entry)
        filtered << entry
      end

      filtered.sort_by! { |e| [-e[:score], -e[:stars].to_i, e[:title].to_s] }
      selected = limit.present? && limit.to_i > 0 ? filtered.first(limit.to_i) : filtered
      items = selected.map { |entry| build_ingest_item(entry) }

      {
        items: items,
        stats:
          dedup_stats.merge(
            sources: source_counts,
            source_errors: source_errors,
            matched_count: filtered.size,
            selected_count: items.size,
          ),
      }
    end

    def load_awesome_decomp_games
      data = fetch_json(ADG_URL)
      Array(data["games"]).filter_map do |g|
        source_url = self.class.normalize_url(g["url"])
        next if source_url.blank?

        repo_key = self.class.extract_repo_key(g["repo"].presence || source_url)
        system = self.class.normalize_system(g["platform"])
        gtype = g["type"].to_s.downcase

        methods = []
        category = "releases"
        case gtype
        when "static-recomp"
          methods.concat(%w[recomp playable])
        when "decompilation", "source-port", "engine-remake", "browser-port"
          methods.concat(%w[decomp playable])
        when "disassembly"
          methods << "decomp"
        when "tool"
          methods << "tooling"
          category = "ai-tooling"
        else
          methods << "decomp"
        end

        archived = ActiveModel::Type::Boolean.new.cast(g["archived"])
        methods.reject! { |m| m == "playable" } if archived

        cover_candidates = []
        cover_candidates << [2, g["og_image"]] if g["og_image"].present?
        cover_candidates << [1, g["thumb_src"]] if g["thumb_src"].present?

        homepage = self.class.normalize_url(g["homepage"])
        title = g["title"].to_s.strip

        {
          source_name: "Awesome Decomp Games",
          external_id: "adg:#{g["id"]}",
          title: title,
          game_name: title.split("(").first.to_s.strip,
          system: system,
          category: category,
          method_tags: methods,
          source_url: source_url,
          homepage_url: homepage.presence,
          alt_urls: homepage.present? ? [homepage] : [],
          repo_key: repo_key,
          stars: g["stars"].to_i,
          downloads: 0,
          release_version: g["release"],
          description: g["description"].to_s.strip,
          target_platforms: %w[Windows Linux],
          cover_candidates: cover_candidates,
          archived: archived,
          ai_notes: nil,
          play_url: nil,
        }
      end
    end

    def load_recomplauncher
      data = fetch_json(RECOMPLAUNCHER_URL)
      sys_map = { "windows" => "Windows", "linux" => "Linux", "macos" => "macOS" }

      Array(data["apps"]).map do |a|
        host = a["host"].presence || "github"
        repo_key = self.class.extract_repo_key(a["repo"], host_hint: host)
        source_url =
          if repo_key&.start_with?("github:")
            "https://github.com/#{repo_key.split(":", 2).last}"
          elsif repo_key&.start_with?("gitlab:")
            "https://gitlab.com/#{repo_key.split(":", 2).last}"
          elsif repo_key&.start_with?("codeberg:")
            "https://codeberg.org/#{repo_key.split(":", 2).last}"
          else
            "https://recomplauncher.com/game/#{a["id"]}"
          end

        system = self.class.normalize_system(a["origin"])
        name = a["name"].to_s.strip
        game = a["game"].to_s.strip
        title =
          if game.present? && !name.downcase.include?(game.downcase)
            "#{name} — #{game}"
          else
            name
          end

        methods = %w[recomp playable]
        ai_notes = nil
        if a["ai"].present? || a["aiUse"].present?
          methods << "ai-rewrite"
          uses = a["ai"].is_a?(Hash) ? Array(a["ai"]["uses"]).join(", ") : ""
          suffix = uses.present? ? " (#{uses})" : ""
          ai_notes = "Flagged as AI-assisted on RecompLauncher#{suffix}."
        end

        cover_candidates = []
        cover_candidates << [4, a["hero"]] if a["hero"].present?
        cover_candidates << [3, a["cover"]] if a["cover"].present?

        targets =
          Array(a["systems"]).map { |s| sys_map[s.to_s.downcase] || s.to_s }.presence ||
            %w[Windows Linux]
        rl_page = "https://recomplauncher.com/game/#{a["id"]}"

        {
          source_name: "RecompLauncher",
          external_id: "rl:#{a["id"]}",
          title: title,
          game_name: game.presence || name,
          system: system,
          category: "releases",
          method_tags: methods,
          source_url: self.class.normalize_url(source_url),
          homepage_url: rl_page,
          alt_urls: [rl_page],
          repo_key: repo_key,
          stars: a["stars"].to_i,
          downloads: a["downloads"].to_i,
          release_version: a["version"],
          description: (a["blurb"].presence || a["description"]).to_s.strip,
          target_platforms: targets,
          cover_candidates: cover_candidates,
          archived: false,
          ai_notes: ai_notes,
          play_url: nil,
        }
      end
    end

    def load_recomp_gg
      records = []

      games_data = fetch_json(RECOMPGG_GAMES_URL)
      Array(games_data["games"]).each do |g|
        proj = g["project"] || {}
        port = g["port"] || {}
        src = self.class.normalize_url(proj["source"].presence || port["url"].presence || g["page"])
        next if src.blank?

        repo_key = self.class.extract_repo_key(src)
        kind = proj["kind"].to_s.downcase
        methods = [kind.include?("recomp") ? "recomp" : "decomp", "playable"]
        play_url = (g["play"] || {})["url"]
        title = g["title"].to_s.strip
        if proj["name"].present? && !title.downcase.include?(proj["name"].to_s.downcase)
          title = "#{proj["name"]} — #{title}"
        end

        alt_urls =
          [g["page"], port["url"]].map { |u| self.class.normalize_url(u) }.reject(&:blank?)

        records << {
          source_name: "recomp.gg",
          external_id: "rgg-g:#{g["slug"]}",
          title: title,
          game_name: g["title"].to_s.strip,
          system: self.class.normalize_system(g["platform"]),
          category: "releases",
          method_tags: methods,
          source_url: src,
          homepage_url: self.class.normalize_url(g["page"]).presence,
          alt_urls: alt_urls,
          repo_key: repo_key,
          stars: 0,
          downloads: 0,
          release_version: nil,
          description:
            "#{g["title"]} (#{g["year"].presence || "Retro"}) — #{proj["kindLabel"].presence || "Native Port"} playable in browser on recomp.gg.",
          target_platforms: %w[Web/Browser Windows Linux],
          cover_candidates: [],
          archived: false,
          ai_notes: nil,
          play_url: play_url,
        }
      end

      cursor = nil
      @max_recompgg_pages.times do
        url = +"#{RECOMPGG_PROJECTS_URL}?limit=100"
        url << "&cursor=#{CGI.escape(cursor.to_s)}" if cursor.present?
        pdata = fetch_json(url)

        Array(pdata["items"]).each do |p|
          next unless [nil, "game", "tool"].include?(p["nature"])

          src = self.class.normalize_url(p["repoUrl"].presence || p["homeUrl"].presence || p["url"])
          next if src.blank?

          repo_key = self.class.extract_repo_key(src)
          method_raw = p["method"].to_s.downcase
          methods = []
          if method_raw.include?("recomp")
            methods << "recomp"
          elsif method_raw.include?("decomp") || method_raw.include?("reimpl")
            methods << "decomp"
          end
          methods << "ai-rewrite" if p["ai"]
          methods << "decomp" if methods.empty?

          alt_urls =
            [p["homeUrl"], p["url"]].map { |u| self.class.normalize_url(u) }.reject(&:blank?)

          records << {
            source_name: "recomp.gg",
            external_id: "rgg-p:#{p["slug"]}",
            title: p["name"].to_s.strip,
            game_name: p["name"].to_s.strip,
            system: "pc",
            category: p["nature"] == "tool" ? "ai-tooling" : "releases",
            method_tags: methods,
            source_url: src,
            homepage_url: self.class.normalize_url(p["homeUrl"].presence || p["url"]).presence,
            alt_urls: alt_urls,
            repo_key: repo_key,
            stars: p["stars"].to_i,
            downloads: 0,
            release_version: nil,
            description: "",
            target_platforms: %w[Windows Linux],
            cover_candidates: [],
            archived: false,
            ai_notes: p["ai"] ? "Flagged as AI-assisted on recomp.gg." : nil,
            play_url: nil,
          }
        end

        page_info = pdata["page"] || {}
        break if !page_info["hasMore"] || page_info["nextCursor"].blank?

        cursor = page_info["nextCursor"]
      end

      records
    end

    def build_ingest_item(entry)
      cover_url = nil
      if entry[:cover_candidates].present?
        best = entry[:cover_candidates].max_by { |pair| pair[0].to_i }
        cover_url = best && best[1]
      end

      cover_svg = nil
      if cover_url.blank?
        sources_str = Array(entry[:sources]).join(" / ")
        sub =
          if entry[:stars].to_i > 0
            "★ #{format_number(entry[:stars].to_i)} stars · #{sources_str}"
          else
            sources_str
          end
        primary_method = Array(entry[:method_tags]).first.presence || "recomp"
        cover_svg = self.class.make_svg(entry[:title], entry[:system], primary_method, sub)
      end

      game_tag = self.class.slugify(entry[:game_name].presence || entry[:title], max_len: 20)
      title_norm =
        self.class.normalize_title_key(
          entry[:game_name].presence || entry[:title].to_s.split("—").first,
        )
      dedup_key =
        entry[:repo_key].presence ||
          (title_norm.present? ? "title:#{title_norm}|#{entry[:system]}" : nil)

      {
        source_url: entry[:source_url],
        alt_urls: entry[:alt_urls],
        repo: entry[:repo_key],
        dedup_key: dedup_key,
        external_ids: entry[:external_ids],
        title: entry[:title],
        category: entry[:category],
        original_system: entry[:system],
        game_tag: game_tag,
        method_tags: entry[:method_tags],
        target_platforms: entry[:target_platforms],
        cover_image_url: cover_url,
        cover_svg: cover_svg,
        homepage_url: entry[:homepage_url],
        play_url: entry[:play_url],
        release_version: entry[:release_version],
        stars: entry[:stars],
        downloads: entry[:downloads],
        sources: entry[:sources],
        summary: entry[:description].presence || "#{entry[:title]} (#{entry[:system].to_s.upcase})",
        ai_notes: entry[:ai_notes],
        score: entry[:score],
      }
    end

    private

    def parse_sources(raw)
      list = raw.is_a?(Array) ? raw : raw.to_s.split(/[|,]/)
      list
        .filter_map { |s| SOURCE_ALIASES[s.to_s.strip.downcase] }
        .uniq
    end

    def format_number(num)
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def fetch_json(url, redirects_remaining: MAX_REDIRECTS)
      raise CrawlError, "Too many redirects fetching #{url}" if redirects_remaining < 0

      uri = URI.parse(url)
      response =
        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @open_timeout,
          read_timeout: @read_timeout,
        ) do |http|
          request = Net::HTTP::Get.new(uri.request_uri)
          request["User-Agent"] = USER_AGENT
          request["Accept"] = "application/json"
          http.request(request)
        end

      if response.is_a?(Net::HTTPRedirection) && response["Location"].present?
        next_url = URI.join(uri, response["Location"]).to_s
        return fetch_json(next_url, redirects_remaining: redirects_remaining - 1)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise CrawlError, "HTTP #{response.code} fetching #{url}"
      end

      JSON.parse(response.body)
    end
  end
end
