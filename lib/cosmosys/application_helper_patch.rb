module Cosmosys
  module ApplicationHelperPatch
    CSID_REFERENCE_PATTERN = /(?<![#A-Za-z0-9])#([A-Za-z0-9]+-[0-9]+)\b/
    CATALOG_REF_PATTERN = /(?<![A-Za-z0-9_:\-])document:di([0-9]+)\b/
    CROSS_PROJECT_CATALOG_REF_PATTERN = /(?<![A-Za-z0-9_:\-])(?:[A-Za-z0-9_-]+:document:di[0-9]+|document:[A-Za-z0-9_-]+:di[0-9]+)\b/

    def url_for(options = nil)
      if options.is_a?(Hash) && (options[:controller] || options['controller']).to_s == 'wiki'
        key = options.key?(:controller) ? :controller : 'controller'
        options = options.merge(key => '/wiki')
      end
      super(options)
    end

    def parse_redmine_links(text, default_project, obj, attr, only_path, options)
      text.gsub!(CROSS_PROJECT_CATALOG_REF_PATTERN) do
        content_tag(:span, l(:label_cosmosys_broken_reference), class: 'cosmosys-broken-reference').to_s
      end

      text.gsub!(CATALOG_REF_PATTERN) do |reference|
        catalog_ref = Cosmosys::CatalogRef.includes(:issue, document_catalog_entry: :document).find_by(id: Regexp.last_match(1))
        next content_tag(:span, l(:label_cosmosys_broken_reference), class: 'cosmosys-broken-reference').to_s unless catalog_ref
        next reference unless default_project.present? && catalog_ref.project_id == default_project.id

        if catalog_ref.visible?(User.current)
          title = [catalog_ref.document.title, catalog_ref.sense, catalog_ref.location].compact_blank.join(' — ')
          url = Rails.application.routes.url_helpers.cosmosys_catalog_ref_path(catalog_ref)
          link_to(catalog_ref.catalog_label, url, class: 'cosmosys-catalog-ref-link', title: title).to_s
        elsif catalog_ref.restricted_document?(User.current)
          content_tag(:span, l(:label_cosmosys_restricted_document), class: 'cosmosys-restricted-document').to_s
        else
          content_tag(:span, l(:label_cosmosys_broken_reference), class: 'cosmosys-broken-reference').to_s
        end
      end

      if default_project.present?
        resolver = Cosmosys::ItemResolver.new(project: default_project, user: User.current)
        text.gsub!(CSID_REFERENCE_PATTERN) do |reference|
          issue = resolver.resolve(Regexp.last_match(1))
          next reference unless issue

          url =
            if only_path
              Rails.application.routes.url_helpers.issue_path(issue)
            else
              issue_url(issue, only_path: false)
            end

          link_to(
            "##{issue.csid}",
            url,
            class: issue.css_classes,
            title: "#{issue.tracker.name}: #{issue.subject.truncate(100)} (#{issue.status.name})"
          )
        end
      end

      super
    end

    def cosmosys_tree_issue_link(issue, chapter_map: nil, boundary: false)
      chapter =
        if issue.respond_to?(:cosmosys_chapter)
          if chapter_map.present? && chapter_map.key?(issue.id)
            chapter_map[issue.id]
          else
            issue.cosmosys_chapter
          end
        end
      reference_mode = issue.respond_to?(:cosmosys_preferred_reference_mode) ? issue.cosmosys_preferred_reference_mode : 'csid'
      reference = reference_mode == 'chapter' ? chapter : (issue.respond_to?(:cosmosys_display_ref) ? issue.cosmosys_display_ref : issue.id.to_s)
      show_tracker = !issue.respond_to?(:cosmosys_item_kind) || issue.cosmosys_item_kind.value(:reference_tracker, issue) != false
      link_options = {
        class: [issue.css_classes, (boundary ? 'cosmosys-tree-boundary-link' : nil)].compact.join(' '),
        title: issue.subject
      }
      issue_href = Rails.application.routes.url_helpers.issue_path(issue)
      issue_link = if show_tracker
                     text = reference_mode == 'chapter' ? "#{issue.tracker}:" : [issue.tracker, reference].compact_blank.join(':')
                     link_to(text, issue_href, link_options)
                   end
      subject_element = if issue_link
                          content_tag(:span, issue.subject, class: ['cosmosys-tree-subject', (boundary ? 'cosmosys-tree-subject-boundary' : nil)].compact.join(' '))
                        else
                          link_to(issue.subject, issue_href, link_options.merge(class: [link_options[:class], 'cosmosys-tree-subject'].join(' ')))
                        end

      safe_join(
        [
          (boundary ? content_tag(:span, '+', class: 'cosmosys-tree-boundary-prefix') : nil),
          (reference_mode == 'chapter' && reference.present? ? content_tag(:span, reference, class: ['cosmosys-tree-ref', (boundary ? 'cosmosys-tree-ref-boundary' : nil)].compact.join(' ')) : nil),
          issue_link,
          subject_element
        ].compact,
        ' '
      )
    end

    def link_to_issue(issue, options = {})
      return super unless issue.respond_to?(:cosmosys_display_ref)

      title = nil
      subject = nil
      ref = issue.cosmosys_display_ref
      text = options[:tracker] == false ? "##{ref}" : "#{issue.tracker} ##{ref}"
      issue_subject = issue.subject

      if options[:subject] == false
        title = issue_subject.truncate(60)
      else
        subject = issue_subject
        if (truncate_length = options[:truncate])
          subject = subject.truncate(truncate_length)
        end
      end

      only_path = options[:only_path].nil? ? true : options[:only_path]
      result = link_to(
        text,
        issue_url(issue, only_path: only_path),
        class: issue.css_classes,
        title: title
      )
      result << h(": #{subject}") if subject
      result = h("#{issue.project} - ") + result if options[:project]
      result
    end
  end
end
