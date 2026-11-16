# frozen_string_literal: true

module RecompIngest
  class ItemsController < ::ApplicationController
    requires_plugin RecompIngest::PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_admin

    def create
      items = params[:items].presence || (params[:item].present? ? [params[:item]] : [params.permit!.to_h])
      update_existing = ActiveModel::Type::Boolean.new.cast(params[:update_existing])

      results = RecompIngest::Ingestor.new(user: current_user).ingest_many(
        items.map { |i| i.respond_to?(:to_unsafe_h) ? i.to_unsafe_h : i.to_h },
        update_existing: update_existing,
      )

      render json: { results: results }
    end
  end
end
