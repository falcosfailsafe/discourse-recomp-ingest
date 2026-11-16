# frozen_string_literal: true

require "digest"
require "tempfile"
require "uri"

module RecompIngest
  class Ingestor
    SOURCE_URL_FIELD = "recomp_source_url"
    REPO_FIELD = "recomp_repo"
    DEDUP_KEY_FIELD = "recomp_dedup_key"
    EXTERNAL_IDS_FIELD = "recomp_external_ids"
    ALT_URLS_FIELD = "recomp_alt_urls"

    def self.normalize_url(url)
      return "" if url.blank?

      raw = url.to_s.strip
      uri = URI.parse(raw)
      uri.scheme = uri.scheme.downcase if uri.scheme
      uri.host = uri.host.downcase.sub(/\Awww\./, "") if uri.host
      uri.fragment = nil
      normalized = uri.to_s.sub(%r{/+\z}, "")
      normalized.sub(/\.git\z/i, "")
    rescue URI::InvalidURIError
      url.to_s.strip.sub(%r{/+\z}, "")
    end

    def self.extract_cover_source_url(raw_item)
      item = raw_item.deep_symbolize_keys
      if item[:cover_image_url].present?
        item[:cover_image_url].to_s.strip
      elsif item[:cover_svg].present?
        "svg:sha256:#{Digest::SHA256.hexdigest(item[:cover_svg].to_s)}"
      end
    end

    def self.compute_content_hash(raw_item)
      item = raw_item.deep_symbolize_keys
      title = item[:title].to_s.strip
      source_url = normalize_url(item[:source_url])
      category_slug =
        (
          item[:category_slug].presence || item[:category].presence ||
            SiteSetting.recomp_ingest_default_category
        ).to_s.strip.downcase
      system_label =
        item[:original_system_label].presence || item[:original_system]&.upcase || "Unknown"
      targets = Array(item[:target_platforms]).map(&:to_s).join(", ").presence || "PC (Windows / Linux)"
      method = Array(item[:method_tags]).map(&:to_s).join(", ").presence || "recomp"
      raw_tags = [
        item[:original_system],
        item[:game_tag],
        *Array(item[:method_tags]),
        *Array(item[:tags]),
      ].map { |t| t.to_s.strip.downcase }.reject(&:blank?).uniq

      canonical_payload = {
        title: title,
        source_url: source_url,
        category: category_slug,
        tags: raw_tags,
        cover_source_url: extract_cover_source_url(item).to_s,
        system_label: system_label.to_s,
        targets: targets,
        method: method,
        homepage_url: item[:homepage_url].to_s.strip,
        play_url: item[:play_url].to_s.strip,
        release_version: item[:release_version].to_s.strip,
        stars: item[:stars].to_i > 0 ? item[:stars].to_i : 0,
        sources: Array(item[:sources]).map(&:to_s),
        summary: item[:summary].to_s.strip,
        ai_notes: item[:ai_notes].to_s.strip,
      }

      Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
    end

    def initialize(user: nil)
      @user = user || resolve_ingest_user
    end

    def ingest_many(items, update_existing: false)
      Array(items).map { |item| ingest_one(item, update_existing: update_existing) }
    end

    def find_existing_entry(raw_item)
      item = raw_item.deep_symbolize_keys
      source_url = normalize_url(item[:source_url])
      alt_urls = Array(item[:alt_urls]).map { |u| normalize_url(u) }.reject(&:blank?).uniq
      repo_keys = extract_repo_keys(source_url, item[:repo], alt_urls)
      dedup_key = item[:dedup_key].to_s.strip.downcase.presence
      external_ids = Array(item[:external_ids]).map { |e| e.to_s.strip.downcase }.reject(&:blank?).uniq

      entry, _matched_by =
        find_entry_in_db(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

      entry if entry&.topic.present?
    end

    def ingest_one(raw_item, update_existing: false)
      item = raw_item.deep_symbolize_keys
      title = item[:title].to_s.strip
      source_url = normalize_url(item[:source_url])
      alt_urls = Array(item[:alt_urls]).map { |u| normalize_url(u) }.reject(&:blank?).uniq
      repo_keys = extract_repo_keys(source_url, item[:repo], alt_urls)
      dedup_key = item[:dedup_key].to_s.strip.downcase.presence
      external_ids = Array(item[:external_ids]).map { |e| e.to_s.strip.downcase }.reject(&:blank?).uniq
      default_source_name = Array(item[:sources]).first.presence || item[:source_name].presence

      if title.blank? || source_url.blank?
        return { status: "skipped", reason: "missing title or source_url", source_url: source_url }
      end

      existing_topic, existing_entry, matched_by, matched_legacy =
        find_existing_topic_and_entry(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

      if matched_legacy && existing_topic && existing_entry.nil?
        existing_entry =
          backfill_legacy_entry!(
            existing_topic,
            item: item,
            source_url: source_url,
            alt_urls: alt_urls,
            repo_keys: repo_keys,
            dedup_key: dedup_key,
            external_ids: external_ids,
            default_source_name: default_source_name,
          )
      end

      should_update = update_existing || ActiveModel::Type::Boolean.new.cast(item[:update_existing])
      if existing_topic && !should_update
        if existing_entry
          touch_entry_seen_and_aliases!(
            existing_entry,
            source_url: source_url,
            alt_urls: alt_urls,
            repo_keys: repo_keys,
            dedup_key: dedup_key,
            external_ids: external_ids,
            default_source_name: default_source_name,
          )
        end

        return {
          status: "duplicate",
          topic_id: existing_topic.id,
          matched_by: matched_by,
          source_url: source_url,
        }
      end

      cover_source_url = self.class.extract_cover_source_url(item)
      content_hash = self.class.compute_content_hash(item)

      if existing_topic && existing_entry&.content_hash.present? &&
           existing_entry.content_hash == content_hash
        touch_entry_seen_and_aliases!(
          existing_entry,
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
          default_source_name: default_source_name,
        )
        save_dedup_fields!(
          existing_topic,
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

        return {
          status: "skipped",
          reason: "unchanged",
          topic_id: existing_topic.id,
          matched_by: matched_by,
          source_url: source_url,
        }
      end

      category = resolve_category(item[:category_slug] || item[:category])
      tags = build_tags(item)
      cover_markdown =
        resolve_cover_markdown(
          item,
          title: title,
          existing_topic: existing_topic,
          existing_entry: existing_entry,
          cover_source_url: cover_source_url,
        )
      raw_body = build_post_body(item, cover_markdown, source_url)

      if existing_topic
        first_post = existing_topic.first_post
        if first_post
          revisor = PostRevisor.new(first_post, existing_topic)
          revisor.revise!(
            @user,
            { raw: raw_body, title: title, tags: tags },
            skip_validations: true,
          )
        end

        save_dedup_fields!(
          existing_topic,
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )
        upsert_entry_and_aliases!(
          existing_entry,
          topic: existing_topic,
          item: item,
          title: title,
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
          cover_source_url: cover_source_url,
          content_hash: content_hash,
          default_source_name: default_source_name,
        )

        return {
          status: "updated",
          topic_id: existing_topic.id,
          matched_by: matched_by,
          source_url: source_url,
        }
      end

      creator =
        PostCreator.new(
          @user,
          title: title,
          raw: raw_body,
          category: category&.id,
          tags: tags,
          visible: SiteSetting.recomp_ingest_auto_publish,
          skip_validations: true,
        )

      post = creator.create
      if creator.errors.present? || post.blank?
        return {
          status: "error",
          errors: creator.errors.full_messages,
          source_url: source_url,
        }
      end

      topic = post.topic
      save_dedup_fields!(
        topic,
        source_url: source_url,
        alt_urls: alt_urls,
        repo_keys: repo_keys,
        dedup_key: dedup_key,
        external_ids: external_ids,
      )
      upsert_entry_and_aliases!(
        existing_entry,
        topic: topic,
        item: item,
        title: title,
        source_url: source_url,
        alt_urls: alt_urls,
        repo_keys: repo_keys,
        dedup_key: dedup_key,
        external_ids: external_ids,
        cover_source_url: cover_source_url,
        content_hash: content_hash,
        default_source_name: default_source_name,
      )

      { status: "created", topic_id: topic.id, slug: topic.slug, source_url: source_url }
    end

    private

    def resolve_ingest_user
      username = SiteSetting.recomp_ingest_username.presence || "system"
      User.find_by(username_lower: username.downcase) || Discourse.system_user
    end

    def normalize_url(url)
      self.class.normalize_url(url)
    end

    def extract_repo_keys(source_url, explicit_repo, alt_urls)
      keys = []
      candidates = [source_url, *alt_urls]

      if explicit_repo.present?
        r = explicit_repo.to_s.strip.downcase.sub(/\.git\z/, "").sub(%r{\A/+|/+\z}, "")
        if r.include?(":")
          keys << r
          keys << r.split(":", 2).last if r.start_with?("github:")
        elsif r.include?("/")
          keys << r
          keys << "github:#{r}"
        end
      end

      candidates.each do |u|
        next if u.blank?

        if (m = u.match(%r{github\.com/([^/]+/[^/?#]+)}i))
          slug = m[1].sub(/\.git\z/i, "").downcase
          keys << slug
          keys << "github:#{slug}"
        elsif (m = u.match(%r{gitlab\.com/([^/]+/[^/?#]+)}i))
          slug = m[1].sub(/\.git\z/i, "").downcase
          keys << "gitlab:#{slug}"
        elsif (m = u.match(%r{codeberg\.org/([^/]+/[^/?#]+)}i))
          slug = m[1].sub(/\.git\z/i, "").downcase
          keys << "codeberg:#{slug}"
        elsif (m = u.match(%r{git\.sr\.ht/(~[^/]+/[^/?#]+)}i))
          slug = m[1].sub(/\.git\z/i, "").downcase
          keys << "srht:#{slug}"
        end
      end

      keys.uniq
    end

    def preferred_canonical_repo(repo_keys)
      return nil if repo_keys.blank?

      repo_keys.find { |k| k.include?(":") } || "github:#{repo_keys.first}"
    end

    def find_entry_in_db(source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      if repo_keys.present?
        entry = RecompIngest::Entry.where(canonical_repo: repo_keys).first
        return [entry, "repo"] if entry

        alias_rec =
          RecompIngest::Alias.includes(:entry).where(kind: "repo", value: repo_keys).first
        return [alias_rec.entry, "repo"] if alias_rec&.entry
      end

      all_urls = ([source_url] + alt_urls).reject(&:blank?).uniq
      if all_urls.present?
        url_keys = all_urls.map(&:downcase).uniq
        source_url_key = source_url.to_s.downcase

        entry =
          RecompIngest::Entry.where("LOWER(canonical_url) IN (?)", url_keys).first
        return [entry, "source_url"] if entry

        if source_url_key.present?
          src_alias =
            RecompIngest::Alias.includes(:entry).find_by(kind: "url", value: source_url_key)
          return [src_alias.entry, "source_url"] if src_alias&.entry
        end

        alt_alias =
          RecompIngest::Alias.includes(:entry).where(kind: "url", value: url_keys).first
        return [alt_alias.entry, "alt_url"] if alt_alias&.entry
      end

      if external_ids.present?
        ext_alias =
          RecompIngest::Alias
            .includes(:entry)
            .where(kind: "external_id", value: external_ids)
            .first
        return [ext_alias.entry, "external_id"] if ext_alias&.entry
      end

      if dedup_key.present?
        entry = RecompIngest::Entry.find_by(dedup_key: dedup_key)
        return [entry, "dedup_key"] if entry

        dedup_alias =
          RecompIngest::Alias.includes(:entry).find_by(kind: "dedup_key", value: dedup_key)
        return [dedup_alias.entry, "dedup_key"] if dedup_alias&.entry
      end

      [nil, nil]
    end

    def find_existing_topic_and_entry(source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      db_entry, db_matched_by =
        find_entry_in_db(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

      if db_entry
        active_topic = db_entry.topic
        return [active_topic, db_entry, db_matched_by, false] if active_topic.present?
      end

      legacy_topic, legacy_matched_by =
        find_legacy_topic(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

      if legacy_topic
        existing_for_topic = db_entry || RecompIngest::Entry.find_by(topic_id: legacy_topic.id)
        return [legacy_topic, existing_for_topic, legacy_matched_by, existing_for_topic.nil?]
      end

      [nil, db_entry, nil, false]
    end

    def find_legacy_topic(source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      if repo_keys.present?
        field =
          TopicCustomField
            .joins(:topic)
            .where(name: REPO_FIELD, value: repo_keys)
            .where(topics: { deleted_at: nil })
            .first
        return [field.topic, "repo"] if field&.topic
      end

      all_urls = ([source_url] + alt_urls).reject(&:blank?).uniq
      if all_urls.present?
        url_keys = all_urls.map(&:downcase).uniq
        field =
          TopicCustomField
            .joins(:topic)
            .where(name: SOURCE_URL_FIELD)
            .where("LOWER(topic_custom_fields.value) IN (?)", url_keys)
            .where(topics: { deleted_at: nil })
            .first
        return [field.topic, "source_url"] if field&.topic
      end

      if dedup_key.present?
        field =
          TopicCustomField
            .joins(:topic)
            .where(name: DEDUP_KEY_FIELD, value: dedup_key)
            .where(topics: { deleted_at: nil })
            .first
        return [field.topic, "dedup_key"] if field&.topic
      end

      if external_ids.present?
        TopicCustomField
          .joins(:topic)
          .where(name: EXTERNAL_IDS_FIELD)
          .where(topics: { deleted_at: nil })
          .find_each do |f|
            stored = f.value.to_s.split(",").map { |v| v.strip.downcase }
            return [f.topic, "external_id"] if (stored & external_ids).any?
          end
      end

      if all_urls.present?
        url_keys = all_urls.map(&:downcase).uniq
        TopicCustomField
          .joins(:topic)
          .where(name: ALT_URLS_FIELD)
          .where(topics: { deleted_at: nil })
          .find_each do |f|
            stored = f.value.to_s.split("|").map { |u| normalize_url(u).downcase }.reject(&:blank?)
            return [f.topic, "alt_url"] if (stored & url_keys).any?
          end
      end

      [nil, nil]
    end

    def backfill_legacy_entry!(
      topic,
      item:,
      source_url:,
      alt_urls:,
      repo_keys:,
      dedup_key:,
      external_ids:,
      default_source_name:
    )
      legacy_source_url = normalize_url(topic.custom_fields[SOURCE_URL_FIELD])
      legacy_repo = topic.custom_fields[REPO_FIELD].to_s.strip.downcase.presence
      legacy_dedup_key = topic.custom_fields[DEDUP_KEY_FIELD].to_s.strip.downcase.presence
      legacy_ext_ids =
        topic
          .custom_fields[EXTERNAL_IDS_FIELD]
          .to_s
          .split(",")
          .map { |s| s.strip.downcase }
          .reject(&:blank?)
      legacy_alt_urls =
        topic
          .custom_fields[ALT_URLS_FIELD]
          .to_s
          .split("|")
          .map { |u| normalize_url(u) }
          .reject(&:blank?)

      merged_repo_keys =
        (repo_keys | extract_repo_keys(legacy_source_url, legacy_repo, legacy_alt_urls))
      merged_alt_urls = ([legacy_source_url, *legacy_alt_urls, *alt_urls] - [source_url]).reject(&:blank?).uniq
      merged_external_ids = (legacy_ext_ids | external_ids)
      effective_dedup_key = dedup_key.presence || legacy_dedup_key
      canonical_url = legacy_source_url.presence || source_url
      canonical_repo = preferred_canonical_repo(merged_repo_keys)

      entry = RecompIngest::Entry.new(topic_id: topic.id)
      assign_unique_entry_keys!(entry, canonical_repo: canonical_repo, dedup_key: effective_dedup_key)
      entry.canonical_url = canonical_url
      entry.title = topic.title.presence || item[:title].to_s.strip
      entry.original_system = item[:original_system].to_s.strip.downcase.presence
      entry.stars = item[:stars].to_i
      entry.downloads = item[:downloads].to_i
      entry.last_seen_at = Time.zone.now
      entry.save!

      entry.register_aliases!(
        build_alias_tuples(
          source_url: canonical_url,
          alt_urls: ([source_url] + merged_alt_urls).uniq,
          repo_keys: merged_repo_keys,
          dedup_key: effective_dedup_key,
          external_ids: merged_external_ids,
        ),
        default_source_name: default_source_name,
      )

      entry
    end

    def upsert_entry_and_aliases!(
      existing_entry,
      topic:,
      item:,
      title:,
      source_url:,
      alt_urls:,
      repo_keys:,
      dedup_key:,
      external_ids:,
      cover_source_url:,
      content_hash:,
      default_source_name:
    )
      now = Time.zone.now
      entry = existing_entry || RecompIngest::Entry.find_by(topic_id: topic.id) || RecompIngest::Entry.new
      entry.topic_id = topic.id
      assign_unique_entry_keys!(
        entry,
        canonical_repo: preferred_canonical_repo(repo_keys),
        dedup_key: dedup_key,
      )
      entry.canonical_url = source_url if entry.canonical_url.blank? || existing_entry.nil?
      entry.title = title
      entry.original_system = item[:original_system].to_s.strip.downcase.presence || entry.original_system
      entry.stars = [entry.stars.to_i, item[:stars].to_i].max
      entry.downloads = [entry.downloads.to_i, item[:downloads].to_i].max
      entry.cover_source_url = cover_source_url
      entry.content_hash = content_hash
      entry.last_seen_at = now
      entry.last_synced_at = now
      entry.save!

      entry.register_aliases!(
        build_alias_tuples(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        ),
        default_source_name: default_source_name,
      )

      entry
    end

    def touch_entry_seen_and_aliases!(
      entry,
      source_url:,
      alt_urls:,
      repo_keys:,
      dedup_key:,
      external_ids:,
      default_source_name:
    )
      now = Time.zone.now
      entry.update_columns(last_seen_at: now, updated_at: now)
      entry.register_aliases!(
        build_alias_tuples(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        ),
        default_source_name: default_source_name,
      )
    end

    def assign_unique_entry_keys!(entry, canonical_repo:, dedup_key:)
      if canonical_repo.present?
        scope = RecompIngest::Entry.where(canonical_repo: canonical_repo)
        scope = scope.where.not(id: entry.id) if entry.persisted?
        entry.canonical_repo = canonical_repo unless scope.exists?
      end

      if dedup_key.present?
        scope = RecompIngest::Entry.where(dedup_key: dedup_key)
        scope = scope.where.not(id: entry.id) if entry.persisted?
        entry.dedup_key = dedup_key unless scope.exists?
      end
    end

    def build_alias_tuples(source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      tuples = []
      repo_keys.each { |rk| tuples << { kind: "repo", value: rk } }
      ([source_url] + alt_urls)
        .reject(&:blank?)
        .map(&:downcase)
        .uniq
        .each { |u| tuples << { kind: "url", value: u } }
      external_ids.each { |eid| tuples << { kind: "external_id", value: eid } }
      tuples << { kind: "dedup_key", value: dedup_key } if dedup_key.present?
      tuples
    end

    def save_dedup_fields!(topic, source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      topic.custom_fields[SOURCE_URL_FIELD] = source_url if topic.custom_fields[SOURCE_URL_FIELD].blank?

      if repo_keys.present?
        preferred_repo = preferred_canonical_repo(repo_keys)
        topic.custom_fields[REPO_FIELD] = preferred_repo
      end

      topic.custom_fields[DEDUP_KEY_FIELD] = dedup_key if dedup_key.present?

      if external_ids.present?
        existing_ext = topic.custom_fields[EXTERNAL_IDS_FIELD].to_s.split(",").reject(&:blank?)
        topic.custom_fields[EXTERNAL_IDS_FIELD] = (existing_ext | external_ids).join(",")
      end

      if alt_urls.present?
        existing_alt = topic.custom_fields[ALT_URLS_FIELD].to_s.split("|").reject(&:blank?)
        topic.custom_fields[ALT_URLS_FIELD] = (existing_alt | alt_urls).join("|")
      end

      topic.save_custom_fields(true)
    end

    def resolve_category(slug_override)
      slug = slug_override.presence || SiteSetting.recomp_ingest_default_category.presence
      if slug.present?
        cat = Category.find_by(slug: slug.to_s.downcase)
        return cat if cat
      end

      Category.find_by(id: SiteSetting.uncategorized_category_id)
    end

    def build_tags(item)
      max_len = [SiteSetting.max_tag_length.to_i, 20].max
      raw_tags = []
      raw_tags << item[:original_system] if item[:original_system].present?
      raw_tags << item[:game_tag] if item[:game_tag].present?
      raw_tags.concat(Array(item[:method_tags]))
      raw_tags.concat(Array(item[:tags]))

      raw_tags
        .map { |t| DiscourseTagging.clean_tag(t.to_s)[0, max_len] }
        .reject(&:blank?)
        .uniq
        .first(SiteSetting.max_tags_per_topic)
    end

    def existing_cover_url_from_post(topic)
      raw = topic&.first_post&.raw.to_s
      return nil if raw.blank?

      match = raw.match(/\A!\[[^\]]*\]\(([^)\s]+)\)/)
      match && match[1]
    end

    def resolve_cover_markdown(item, title:, existing_topic:, existing_entry:, cover_source_url:)
      return "" if cover_source_url.blank?

      if existing_topic && existing_entry&.cover_source_url.present? &&
           existing_entry.cover_source_url == cover_source_url
        existing_url = existing_cover_url_from_post(existing_topic)
        return "![#{title}](#{existing_url})\n\n" if existing_url.present?
      end

      if item[:cover_image_url].present?
        build_cover_markdown(item[:cover_image_url].to_s.strip, title)
      elsif item[:cover_svg].present?
        build_svg_cover_markdown(item[:cover_svg].to_s, title)
      else
        ""
      end
    end

    def build_cover_markdown(cover_url, title)
      return "" if cover_url.blank?

      if cover_url.start_with?("upload://")
        return "![#{title}](#{cover_url})\n\n"
      end

      begin
        file =
          FileHelper.download(
            cover_url,
            max_file_size: 10.megabytes,
            tmp_file_name: "recomp-cover",
            follow_redirect: true,
          )
        if file
          ext = File.extname(URI.parse(cover_url).path).presence || ".png"
          upload = UploadCreator.new(file, "cover#{ext}").create_for(@user.id)
          if upload&.persisted?
            return "![#{title}](#{upload.short_url})\n\n"
          end
        end
      rescue StandardError => e
        Rails.logger.warn("[RecompIngest] Cover download failed for #{cover_url}: #{e.message}")
      ensure
        file&.close! if defined?(file) && file.respond_to?(:close!)
      end

      "![#{title}](#{cover_url})\n\n"
    end

    def build_svg_cover_markdown(svg_text, title)
      return "" if svg_text.blank?

      tempfile = Tempfile.new(["recomp-cover", ".svg"])
      tempfile.write(svg_text)
      tempfile.rewind
      upload = UploadCreator.new(tempfile, "cover.svg").create_for(@user.id)
      return "![#{title}](#{upload.short_url})\n\n" if upload&.persisted?

      ""
    rescue StandardError => e
      Rails.logger.warn("[RecompIngest] SVG cover upload failed for #{title}: #{e.message}")
      ""
    ensure
      tempfile&.close! if defined?(tempfile) && tempfile.respond_to?(:close!)
    end

    def build_post_body(item, cover_markdown, source_url)
      system_label = item[:original_system_label].presence || item[:original_system]&.upcase || "Unknown"
      targets = Array(item[:target_platforms]).join(", ").presence || "PC (Windows / Linux)"
      method = Array(item[:method_tags]).join(", ").presence || "recomp"

      lines = []
      lines << cover_markdown if cover_markdown.present?
      lines << "| Field | Details |"
      lines << "| --- | --- |"
      lines << "| **Original System** | #{system_label} |"
      lines << "| **Target Platforms** | #{targets} |"
      lines << "| **Method / Status** | #{method} |"
      lines << "| **Source / Repo** | #{source_url} |"
      lines << "| **Homepage** | #{item[:homepage_url]} |" if item[:homepage_url].present?
      lines << "| **Play Online** | #{item[:play_url]} |" if item[:play_url].present?
      lines << "| **Latest Release** | #{item[:release_version]} |" if item[:release_version].present?
      lines << "| **Stars** | #{item[:stars]} |" if item[:stars].to_i > 0
      if Array(item[:sources]).present?
        lines << "| **Discovered Via** | #{Array(item[:sources]).join(", ")} |"
      end
      lines << ""
      lines << item[:summary].to_s.strip if item[:summary].present?

      if item[:ai_notes].present?
        lines << ""
        lines << "### AI Rewrite / Lifting Notes"
        lines << item[:ai_notes].to_s.strip
      end

      lines.join("\n")
    end
  end
end
