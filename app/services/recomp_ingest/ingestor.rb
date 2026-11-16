# frozen_string_literal: true

require "uri"

module RecompIngest
  class Ingestor
    SOURCE_URL_FIELD = "recomp_source_url"
    REPO_FIELD = "recomp_repo"
    DEDUP_KEY_FIELD = "recomp_dedup_key"
    EXTERNAL_IDS_FIELD = "recomp_external_ids"
    ALT_URLS_FIELD = "recomp_alt_urls"

    def initialize(user: nil)
      @user = user || resolve_ingest_user
    end

    def ingest_many(items, update_existing: false)
      Array(items).map { |item| ingest_one(item, update_existing: update_existing) }
    end

    def ingest_one(raw_item, update_existing: false)
      item = raw_item.deep_symbolize_keys
      title = item[:title].to_s.strip
      source_url = normalize_url(item[:source_url])
      alt_urls = Array(item[:alt_urls]).map { |u| normalize_url(u) }.reject(&:blank?).uniq
      repo_keys = extract_repo_keys(source_url, item[:repo], alt_urls)
      dedup_key = item[:dedup_key].to_s.strip.downcase.presence
      external_ids = Array(item[:external_ids]).map { |e| e.to_s.strip.downcase }.reject(&:blank?).uniq

      if title.blank? || source_url.blank?
        return { status: "skipped", reason: "missing title or source_url", source_url: source_url }
      end

      existing, matched_by =
        find_existing_topic(
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )

      should_update = update_existing || ActiveModel::Type::Boolean.new.cast(item[:update_existing])
      if existing && !should_update
        return {
          status: "duplicate",
          topic_id: existing.id,
          matched_by: matched_by,
          source_url: source_url,
        }
      end

      category = resolve_category(item[:category_slug] || item[:category])
      tags = build_tags(item)
      cover_markdown = build_cover_markdown(item[:cover_image_url], title)
      raw_body = build_post_body(item, cover_markdown, source_url)

      if existing
        first_post = existing.first_post
        if first_post
          revisor = PostRevisor.new(first_post, existing)
          revisor.revise!(
            @user,
            { raw: raw_body, title: title, tags: tags },
            skip_validations: true,
          )
        end
        save_dedup_fields!(
          existing,
          source_url: source_url,
          alt_urls: alt_urls,
          repo_keys: repo_keys,
          dedup_key: dedup_key,
          external_ids: external_ids,
        )
        return {
          status: "updated",
          topic_id: existing.id,
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

      { status: "created", topic_id: topic.id, slug: topic.slug, source_url: source_url }
    end

    private

    def resolve_ingest_user
      username = SiteSetting.recomp_ingest_username.presence || "system"
      User.find_by(username_lower: username.downcase) || Discourse.system_user
    end

    def normalize_url(url)
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

    def find_existing_topic(source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
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
        field =
          TopicCustomField
            .joins(:topic)
            .where(name: SOURCE_URL_FIELD, value: all_urls)
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
            stored = f.value.to_s.split(",")
            return [f.topic, "external_id"] if (stored & external_ids).any?
          end
      end

      if all_urls.present?
        TopicCustomField
          .joins(:topic)
          .where(name: ALT_URLS_FIELD)
          .where(topics: { deleted_at: nil })
          .find_each do |f|
            stored = f.value.to_s.split("|")
            return [f.topic, "alt_url"] if (stored & all_urls).any?
          end
      end

      [nil, nil]
    end

    def save_dedup_fields!(topic, source_url:, alt_urls:, repo_keys:, dedup_key:, external_ids:)
      topic.custom_fields[SOURCE_URL_FIELD] = source_url if topic.custom_fields[SOURCE_URL_FIELD].blank?

      if repo_keys.present?
        preferred_repo = repo_keys.find { |k| k.include?(":") } || repo_keys.first
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
