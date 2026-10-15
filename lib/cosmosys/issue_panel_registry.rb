module Cosmosys
  class IssuePanelRegistry
    Panel = Struct.new(:key, :location, :title, :url, :available, :default, keyword_init: true)

    class << self
      def register(key:, location:, title:, url:, available: nil, default: false)
        panel = Panel.new(
          key: key.to_s,
          location: location.to_sym,
          title: title.to_sym,
          url: url,
          available: available || ->(_issue, _user) { true },
          default: default
        )
        panels[[panel.location, panel.key]] = panel
      end

      def for_issue(location:, issue:, user: User.current, view:)
        panels.values.select do |panel|
          panel.location == location.to_sym && panel.available.call(issue, user)
        end.map do |panel|
          panel.dup.tap do |copy|
            copy.url = panel.url.call(view, issue)
            copy.default = panel.default.respond_to?(:call) ? panel.default.call(issue, user) : panel.default
          end
        end
      end

      def reset!
        @panels = {}
      end

      private

      def panels
        @panels ||= {}
      end
    end
  end
end
