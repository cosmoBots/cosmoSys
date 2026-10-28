module Cosmosys
  # Request-local numbering. Catalog identity/order is never mutated by rendering.
  class EditorialDocumentContext
    EMBED_PATTERN = /(?<!!)\{\{document_embed\(\s*di([1-9]\d*)\s*\)\}\}/
    CITATION_PATTERN = /(?<![A-Za-z0-9_:\-])document:di([1-9]\d*)\b/

    def initialize(report, user:)
      @report, @user = report, user
      @references, @numbers, @included = {}, {}, {}
      @counters = Hash.new(0)
      report.toc_entries.each { |section| scan_section(section) }
      report.orphaned_sections.each { |section| scan_tree(section) }
    end

    def reference(id)
      @references[id.to_i] ||= CatalogRef.includes(:issue, document_catalog_entry: :document).find_by(id: id)
    end

    def allowed?(ref)
      ref && ref.project_id == @report.project.id && ref.visible?(@user)
    end

    def label(entry)
      number = @numbers[entry.id]
      return entry.catalog_label unless number

      "#{I18n.t(DocumentCatalogEntry::FAMILY_LABELS.fetch(entry.family), locale: @report.project.cosmosys_locale)}.#{number}"
    end

    def entries(family)
      result = @included.values.select { |entry| entry.family == family }
      @report.options["appearance_#{family}"] ? result : result.sort_by { |entry| [entry.position, entry.id] }
    end

    private

    def scan_tree(section)
      scan_section(section)
      section.children.each { |child| scan_tree(child) }
    end

    def scan_section(section)
      if @report.options['description'] || (!section.numbered && !section.orphaned)
        scan(section.issue.description, [])
      end
      if section.numbered && !section.report_placeholder && section.issue.cosmosys_item_kind_key != 'negative'
        section.body_fields.select(&:rich_text).each { |field| scan(field.value.to_s, []) }
      end
    end

    def scan(text, ancestors)
      # Literal examples do not count as editorial appearances. Keep macros
      # other than document_embed opaque (their bodies are another language).
      source = text.to_s.gsub(/(^```[^\n]*\n.*?^```[^\n]*$|^~~~[^\n]*\n.*?^~~~[^\n]*$|`+[^`\n]+`+|<pre\b.*?<\/pre>|<!--.*?-->)/mi, '')
      source = source.gsub(MainReportTextNormalizer::MACRO_RE) { |macro| macro.match?(EMBED_PATTERN) ? macro : '' }
      pattern = /#{EMBED_PATTERN.source}|#{CITATION_PATTERN.source}/
      source.scan(pattern) do |embed_id, citation_id|
        ref = reference(embed_id || citation_id)
        next unless allowed?(ref)
        entry = ref.document_catalog_entry
        if embed_id
          next unless entry.editorial? && !ancestors.include?(entry.document_id) && ancestors.length < 32
          register(entry)
          scan(entry.document.description, ancestors + [entry.document_id])
        elsif !entry.editorial?
          register(entry)
        end
      end
    end

    def register(entry)
      @included[entry.id] ||= entry
      return if @numbers.key?(entry.id) || !@report.options["appearance_#{entry.family}"]

      @numbers[entry.id] = (@counters[entry.family] += 1)
    end
  end
end
