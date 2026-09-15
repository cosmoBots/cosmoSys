require 'base64'
require 'digest'
require 'fileutils'
require 'nokogiri'
require 'open3'
require 'tmpdir'
require 'date'
require 'uri'

module Cosmosys
  class ReportExportService
    Result = Struct.new(:data, :filename, :content_type, keyword_init: true)
    FORMATS = {
      'odt' => 'application/vnd.oasis.opendocument.text',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'pdf' => 'application/pdf'
    }.freeze
    # Writer's HTML importer ignores percentage table widths but consistently
    # honours legacy pixel widths. 541 CSS px represent about 14.3 cm at the
    # standard 96 CSS px/in, leaving a compact margin inside the 15.56 cm A4
    # text area. These values affect layout only, never image resolution.
    METADATA_TABLE_WIDTH_PX = 541
    METADATA_LABEL_WIDTH_PX = 189
    METADATA_VALUE_WIDTH_PX = METADATA_TABLE_WIDTH_PX - METADATA_LABEL_WIDTH_PX
    DOCUMENT_CATALOG_ID_WIDTH_PX = 68
    DOCUMENT_CATALOG_METADATA_WIDTH_PX = (METADATA_TABLE_WIDTH_PX - DOCUMENT_CATALOG_ID_WIDTH_PX) / 3
    PORTRAIT_CONTENT_WIDTH_PX = METADATA_TABLE_WIDTH_PX
    ORIENTATION_MARKERS = {
      'landscape' => ['COSMOSYS_REPORT_LANDSCAPE_START', 'COSMOSYS_REPORT_LANDSCAPE_END'],
      'portrait' => ['COSMOSYS_REPORT_PORTRAIT_START', 'COSMOSYS_REPORT_PORTRAIT_END']
    }.freeze
    CACHE_SCHEMA = 'cosmosys-report-artifact-v4'.freeze
    MAX_CACHED_REPORTS_PER_PROJECT = 5

    class ExportError < StandardError; end

    def initialize(project, html:, format: 'docx', user: User.current)
      @project = project
      @html = html.to_s
      @format = format.to_s
      @user = user
      @input_blank = @html.blank?
      unless @input_blank
        document = Nokogiri::HTML5(@html)
        secure_embedded_resources!(document)
        @html = document.to_html
      end
      @template_resolution = project.cosmosys_effective_report_template
    end

    def call
      raise ExportError, 'Unsupported report format' unless FORMATS.key?(@format)
      raise ExportError, 'The report is empty' if @input_blank

      artifact_path = cached_artifact_path(@format)
      cache_state = valid_artifact?(artifact_path) ? 'warm' : 'cold'
      Cosmosys::PerformanceTrace.measure('report.export', project_id: @project.id, format: @format, cache: cache_state) do
        with_artifact_lock do
          build_cached_odt unless valid_artifact?(cached_artifact_path('odt'))
          build_cached_conversion(@format) if @format != 'odt' && !valid_artifact?(artifact_path)
        end
      end

      raise ExportError, 'LibreOffice did not create the report' unless valid_artifact?(artifact_path)

      FileUtils.touch(cache_root)
      prune_old_artifacts

      Result.new(
        data: File.binread(artifact_path),
        filename: "#{safe_filename(@project.name)}.#{@format}",
        content_type: FORMATS.fetch(@format)
      )
    end

    private

    def assets_root
      @assets_root ||= Rails.root.join('plugins', 'cosmosys', 'assets', 'report_export')
    end

    def artifact_key
      @artifact_key ||= Digest::SHA256.hexdigest([
        CACHE_SCHEMA,
        @project.id,
        @project.name,
        @project.identifier,
        @project.cscode,
        @project.csys_report_code,
        @project.default_version&.name,
        report_application_version,
        @project.cosmosys_report_landscape_scale_threshold,
        Digest::SHA256.hexdigest(@html),
        file_digest(template_path),
        tree_digest(profile_source)
      ].join("\0"))
    end

    def cache_root
      @cache_root ||= Rails.root.join('files', 'cosmosys', 'report_artifacts', @project.id.to_s, artifact_key)
    end

    def cached_artifact_path(format)
      cache_root.join("report.#{format}")
    end

    def project_cache_root
      cache_root.parent
    end

    def prune_old_artifacts
      candidates = project_cache_root.children
        .select(&:directory?)
        .select { |path| valid_artifact?(path.join('report.odt')) }
        .sort_by { |path| path.mtime }
        .reverse
        .drop(MAX_CACHED_REPORTS_PER_PROJECT)

      candidates.each { |path| remove_idle_cache(path) }
    rescue Errno::ENOENT
      nil
    end

    def remove_idle_cache(path)
      File.open(path.join('build.lock'), File::RDWR | File::CREAT, 0o640) do |lock|
        return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        FileUtils.rm_rf(path)
      end
    rescue Errno::ENOENT
      nil
    end

    def with_artifact_lock
      FileUtils.mkdir_p(cache_root)
      File.open(cache_root.join('build.lock'), File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def build_cached_odt
      Dir.mktmpdir('cosmosys-report-') do |dir|
        prepare_profile(dir)
        html_path = File.join(dir, 'report.html')
        odt_path = File.join(dir, 'report.odt')
        rendered_html = Cosmosys::PerformanceTrace.measure('report.html', project_id: @project.id, cache: 'cold') { export_html(dir) }
        File.binwrite(html_path, rendered_html)
        FileUtils.cp(template_path, odt_path)
        Cosmosys::PerformanceTrace.measure('report.libreoffice', project_id: @project.id, format: 'odt', cache: 'cold') do
          run_soffice(dir, macro_uri(odt_path, html_path))
        end
        persist_artifact(odt_path, cached_artifact_path('odt'))
      end
    end

    def build_cached_conversion(format)
      Dir.mktmpdir('cosmosys-report-convert-') do |dir|
        prepare_profile(dir)
        odt_path = File.join(dir, 'report.odt')
        FileUtils.cp(cached_artifact_path('odt'), odt_path)
        Cosmosys::PerformanceTrace.measure('report.libreoffice', project_id: @project.id, format: format, cache: 'cold') do
          run_soffice(dir, '--convert-to', format, '--outdir', dir, odt_path)
        end
        persist_artifact(File.join(dir, "report.#{format}"), cached_artifact_path(format))
      end
    end

    def prepare_profile(dir)
      FileUtils.cp_r(profile_source, File.join(dir, 'profile'))
    end

    def persist_artifact(source, destination)
      raise ExportError, 'LibreOffice did not create the report' unless File.file?(source) && File.size?(source)

      temporary = "#{destination}.tmp-#{Process.pid}"
      FileUtils.cp(source, temporary)
      File.rename(temporary, destination)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary)
    end

    def valid_artifact?(path)
      File.file?(path) && File.size?(path)
    end

    def file_digest(path)
      Digest::SHA256.file(path).hexdigest
    end

    def tree_digest(root)
      digest = Digest::SHA256.new
      Dir.glob(root.join('**', '*').to_s).select { |path| File.file?(path) }.sort.each do |path|
        digest << path.delete_prefix(root.to_s) << "\0" << Digest::SHA256.file(path).hexdigest << "\0"
      end
      digest.hexdigest
    end

    def export_html(work_dir)
      document = Nokogiri::HTML5(@html)
      secure_embedded_resources!(document)
      prepare_export_document(document)
      document.css('svg').each_with_index do |svg, index|
        dimensions = svg_dimensions_css_px(svg)
        unless dimensions
          # Redmine's toolbar/sprite icons are inline SVGs too, but they have no
          # intrinsic dimensions and are not report content. Passing one to
          # ImageMagick makes the whole export fail with "SVG has no dimensions".
          svg.remove
          next
        end
        svg_path = File.join(work_dir, "diagram-#{index}.svg")
        png_path = File.join(work_dir, "diagram-#{index}.png")
        export_svg = svg.dup
        export_svg.css('metadata').remove
        export_svg.css('*').each do |node|
          node.remove_attribute('href')
          node.remove_attribute('xlink:href')
        end
        standalone_svg = export_svg.to_xml
          .gsub(/(<\/?)(?:svg:)/, '\\1')
          .gsub(/\s+xmlns(?::[A-Za-z0-9_-]+)?="[^"]*"/, '')
          .sub('<svg', '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"')
        File.binwrite(svg_path, standalone_svg)
        output, status = Open3.capture2e('/usr/bin/magick', svg_path, png_path)
        unless status.success? && File.file?(png_path)
          Rails.logger.error("cosmoSys SVG rasterization failed: #{output}")
          raise ExportError, 'A report diagram could not be converted'
        end

        replacement = Nokogiri::XML::Node.new('img', document)
        replacement['src'] = "data:image/png;base64,#{Base64.strict_encode64(File.binread(png_path))}"
        replacement['alt'] = svg['aria-label'].presence || 'cosmoSys diagram'
        alternate_orientation = report_diagram?(svg) && alternate_orientation_for(dimensions)
        svg.replace(replacement)
        add_orientation_markers(replacement, document, alternate_orientation) if alternate_orientation
      end
      document.to_html
    end

    def secure_embedded_resources!(document)
      document.css('object, embed, iframe, video, audio, source, link[rel="stylesheet"]').remove
      document.css('*').each do |node|
        unless node.name == 'img'
          node.remove_attribute('src')
          node.remove_attribute('srcset')
          node.remove_attribute('poster')
          node.remove_attribute('background')
        end
        node.remove_attribute('style') if node['style'].to_s.match?(/url\s*\(/i)
      end
      document.css('style').each do |node|
        node.remove if node.text.match?(/url\s*\(|@import/i)
      end

      document.css('img').each do |image|
        image.remove_attribute('srcset')
        source = image['src'].to_s
        next if bounded_image_data_url?(source)

        attachment = authorized_attachment_for(source)
        unless attachment
          image.remove
          next
        end

        image['src'] = "data:#{attachment.content_type};base64,#{Base64.strict_encode64(File.binread(attachment.diskfile))}"
      end
    end

    def bounded_image_data_url?(source)
      match = source.match(%r{\Adata:(image/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=]+)\z}i)
      return false unless match

      match[2].bytesize <= 40.megabytes
    end

    def authorized_attachment_for(source)
      path = URI.parse(source).path
      match = path.match(%r{\A/attachments/(?:download/)?(\d+)(?:/|\z)})
      return unless match

      attachment = Attachment.find_by(id: match[1])
      return unless attachment&.visible?(@user)
      return unless attachment.content_type.to_s.match?(%r{\Aimage/(?:png|jpeg|gif|webp)\z}i)
      return unless File.file?(attachment.diskfile) && File.size(attachment.diskfile) <= 30.megabytes

      attachment
    rescue URI::InvalidURIError
      nil
    end

    def add_orientation_markers(image, document, orientation)
      start_text, end_text = ORIENTATION_MARKERS.fetch(orientation)
      start_marker = Nokogiri::XML::Node.new('p', document)
      start_marker.content = start_text
      end_marker = Nokogiri::XML::Node.new('p', document)
      end_marker.content = end_text
      container = image.ancestors.find { |ancestor| ancestor['class'].to_s.split.include?('cosmosys-report-diagram') } || image
      container.add_previous_sibling(start_marker)
      container.add_next_sibling(end_marker)
    end

    def report_diagram?(svg)
      svg.ancestors.any? { |ancestor| ancestor['class'].to_s.split.include?('cosmosys-report-diagram') }
    end

    def alternate_orientation_for(dimensions)
      threshold = @project.cosmosys_report_landscape_scale_threshold.to_i.clamp(0, 100)
      return if threshold.zero?

      current = report_template_dimensions.current_page
      alternate_orientation = current.landscape? ? 'portrait' : 'landscape'
      alternate = report_template_dimensions.donor_for(alternate_orientation)
      return unless alternate

      width_px = dimensions.fetch(:width).to_f
      height_px = dimensions.fetch(:height).to_f
      return unless width_px.positive? && height_px.positive?

      width_scale = current.content_width_px / width_px
      height_scale = current.content_height_px / height_px
      limiting_dimension_matches = current.landscape? ? height_scale < width_scale : width_scale < height_scale
      return unless limiting_dimension_matches

      current_scale = [1.0, width_scale, height_scale].min
      alternate_scale = [1.0, alternate.content_width_px / width_px, alternate.content_height_px / height_px].min
      return unless current_scale * 100.0 < threshold && alternate_scale > current_scale

      alternate_orientation
    end

    def svg_dimensions_css_px(svg)
      width = css_length_to_px(svg['width'])
      height = css_length_to_px(svg['height'])
      return { width: width, height: height } if width&.positive? && height&.positive?

      view_box = svg['viewBox'].to_s.split.map { |value| Float(value, exception: false) }
      if view_box.length == 4 && view_box.all? && view_box[2].positive? && view_box[3].positive?
        return { width: view_box[2], height: view_box[3] }
      end

      nil
    end

    def css_length_to_px(value)
      match = value.to_s.strip.match(/\A([0-9]+(?:\.[0-9]+)?)(px|pt|in|cm|mm)?\z/i)
      return unless match

      number = match[1].to_f
      case match[2].to_s.downcase
      when '', 'px' then number
      when 'pt' then number * 96.0 / 72.0
      when 'in' then number * 96.0
      when 'cm' then number * 96.0 / 2.54
      when 'mm' then number * 96.0 / 25.4
      end
    end

    def prepare_export_document(document)
      # `chapter` is useful in the browser report, but Writer already numbers the
      # imported heading styles. Keeping both produces headings such as
      # "1.1 1.1: ..." in the document and its generated table of contents.
      document.css('.cosmosys-report-heading-link-chapter').remove
      document.css('.cosmosys-report-heading-chapter').remove

      # Writer overrides the template's `space before` when importing HTML
      # headings, especially immediately after a table. Use one explicit body
      # paragraph between items; it remains independently removable in Writer.
      document.css('.cosmosys-report-heading').to_a.drop(1).each do |heading|
        spacer = Nokogiri::XML::Node.new('p', document)
        spacer['class'] = 'cosmosys-report-chapter-spacer'
        spacer.content = "\u00a0"
        heading.add_previous_sibling(spacer)
      end

      # Redmine appends a visible pilcrow link to every Markdown heading:
      # `<a class="wiki-anchor">¶</a>`. It is useful in the browser for deep
      # links, but becomes ordinary printable text when the heading is changed
      # into a bold paragraph for Writer.
      document.css('.cosmosys-report-description a.wiki-anchor').remove

      # Browser navigation is deliberately richer than the portable document.
      # Only links generated by the two explicit report options may survive
      # the LibreOffice pipeline; keep their visible text in every other case.
      # This must run after removing wiki anchors, otherwise their pilcrow is
      # unwrapped into printable text before the anchor can be identified.
      document.css('a').each do |link|
        if link['data-cosmosys-export-link'].present?
          link.remove_attribute('data-cosmosys-export-link')
          next
        end

        link.children.to_a.each { |child| link.add_previous_sibling(child) }
        link.remove
      end

      # Field labels and diagram captions describe content inside an item; they
      # are not levels in the item hierarchy. LibreOffice maps every h1..h6 to
      # an outline level, so an h6 caption used to create spurious 1.1.1.1.1.1
      # entries in the generated table of contents.
      document.css('.cosmosys-report-section h1, .cosmosys-report-section h2, .cosmosys-report-section h3, .cosmosys-report-section h4, .cosmosys-report-section h5, .cosmosys-report-section h6').each do |heading|
        next if heading['class'].to_s.split.include?('cosmosys-report-heading')

        level = heading.name.delete_prefix('h').to_i.clamp(1, 6)
        if heading.ancestors.any? { |ancestor| ancestor['class'].to_s.split.include?('cosmosys-report-description') }
          convert_description_heading(heading, document, level)
          next
        end

        heading.name = 'p'
        heading['class'] = [heading['class'], 'cosmosys-report-display-heading'].compact.join(' ')
        add_inline_declarations(
          heading,
          'font-weight' => 'bold',
          'font-size' => "#{16 - level}pt",
          'margin-top' => '0.8em',
          'margin-bottom' => '0.35em'
        )
      end

      # This is a fallback for HTML consumers. The authoritative page-width
      # constraint is applied by the LibreOffice macro from the template's page
      # width and margins, since CSS max-width is not consistently honoured by
      # Writer's HTML importer.
      document.css('img').each do |image|
        add_inline_declarations(image, 'max-width' => '100%', 'height' => 'auto')
      end

      # The browser report gets its table presentation from Redmine's external
      # stylesheets, which are deliberately not transported into the portable
      # document. Give every document table a self-contained baseline before
      # applying the more specific metadata/catalog dimensions below. This
      # makes Markdown tables and generated tables equivalent to Writer.
      document.css('table').each do |table|
        table['align'] = 'center'
        table['border'] = '1'
        table['cellspacing'] = '0'
        table['cellpadding'] = '0'
        add_inline_declarations(
          table,
          'border-collapse' => 'collapse',
          'margin-left' => 'auto',
          'margin-right' => 'auto'
        )
        table.css('th, td').each do |cell|
          add_inline_declarations(cell, 'border' => '1px solid #b7c3cf', 'padding' => '4pt', 'vertical-align' => 'top')
        end
        table.css('th').each do |header|
          add_inline_declarations(header, 'background-color' => '#f3f6f9', 'font-weight' => 'bold')
        end
      end

      document.css('table.cosmosys-report-metadata').each do |table|
        table['width'] = METADATA_TABLE_WIDTH_PX.to_s
        add_inline_declarations(table, 'width' => "#{METADATA_TABLE_WIDTH_PX}px")
        table.css('col').each_with_index do |column, index|
          width = index.zero? ? METADATA_LABEL_WIDTH_PX : METADATA_VALUE_WIDTH_PX
          column['width'] = width.to_s
          add_inline_declarations(column, 'width' => "#{width}px")
        end
        table.css('th, td').each do |cell|
          add_inline_declarations(cell, 'border' => '1px solid #b7c3cf', 'padding' => '4pt', 'vertical-align' => 'top')
        end
        table.css('th').each do |header|
          header['width'] = METADATA_LABEL_WIDTH_PX.to_s
          add_inline_declarations(header, 'background-color' => '#f3f6f9', 'font-weight' => 'bold', 'width' => "#{METADATA_LABEL_WIDTH_PX}px", 'white-space' => 'nowrap')
        end
        table.css('td').each do |value|
          value['width'] = METADATA_VALUE_WIDTH_PX.to_s
          add_inline_declarations(value, 'width' => "#{METADATA_VALUE_WIDTH_PX}px")
        end

      end

      document.css('table.cosmosys-report-document-catalog-table, table.cosmosys-report-document-references-table').each do |table|
        table['width'] = METADATA_TABLE_WIDTH_PX.to_s
        add_inline_declarations(table, 'width' => "#{METADATA_TABLE_WIDTH_PX}px")
      end

      document.css('table.cosmosys-report-document-catalog-table').each do |table|
        columns = table.css('col')
        columns.each_with_index do |column, index|
          width = index.zero? ? DOCUMENT_CATALOG_ID_WIDTH_PX : DOCUMENT_CATALOG_METADATA_WIDTH_PX
          column['width'] = width.to_s
          add_inline_declarations(column, 'width' => "#{width}px")
        end
        table.css('tr.cosmosys-report-document-catalog-metadata-row td').each do |cell|
          add_inline_declarations(cell, 'color' => '#5c6670', 'font-size' => '9pt')
        end
        table.css('tr.cosmosys-report-document-catalog-metadata-row td:first-child').each do |cell|
          add_inline_declarations(cell, 'background-color' => '#f3f6f9')
        end
      end
    end

    def convert_description_heading(heading, document, level)
      # Markdown renderers normally surround block headings with source
      # newlines. They are insignificant in HTML, but remove them explicitly
      # before handing the fragment to Writer so that only the paragraph
      # boundary created below can separate the heading from its body.
      heading.xpath('.//text()').each do |text_node|
        text_node.content = text_node.content.gsub(/[\r\n]+/, ' ').strip
      end
      heading.previous_sibling.remove while heading.previous_sibling&.text? && heading.previous_sibling.text.strip.empty?
      heading.next_sibling.remove while heading.next_sibling&.text? && heading.next_sibling.text.strip.empty?

      # Keep the visual hierarchy of the Markdown heading without retaining an
      # h1..h6 outline level. The browser-only wiki anchor has already been
      # removed, so this produces one styled paragraph and one paragraph mark.
      heading.name = 'p'
      heading['class'] = [heading['class'], 'cosmosys-report-display-heading'].compact.join(' ')
      add_inline_declarations(
        heading,
        'font-weight' => 'bold',
        'font-size' => "#{16 - level}pt",
        'text-align' => 'left',
        'margin-top' => '0.8em',
        'margin-bottom' => '0.35em'
      )
    end

    def add_inline_declarations(node, additions)
      replaced_properties = additions.keys.map { |property| Regexp.escape(property) }.join('|')
      declarations = node['style'].to_s.split(';').map(&:strip).reject(&:blank?)
      declarations.reject! { |declaration| declaration.match?(/\A(?:#{replaced_properties})\s*:/i) }
      declarations.concat(additions.map { |property, value| "#{property}: #{value}" })
      node['style'] = "#{declarations.join('; ')};"
    end

    def profile_source
      assets_root.join('libreoffice_profile')
    end

    def template_path
      Pathname(@template_resolution.path)
    end

    def report_template_dimensions
      @report_template_dimensions ||= Cosmosys::ReportTemplateInspector.call(template_path)
    end

    def run_soffice(work_dir, *arguments)
      profile_uri = "file://#{File.join(work_dir, 'profile')}"
      command = [
        '/usr/bin/soffice',
        "-env:UserInstallation=#{profile_uri}",
        '--headless', '--invisible', '--nofirststartwizard', '--norestore',
        *arguments
      ]
      output, status = Open3.capture2e(*command, chdir: work_dir)
      return if status.success?

      Rails.logger.error("cosmoSys report export failed: #{output}")
      raise ExportError, 'LibreOffice could not generate the report'
    end

    def macro_uri(odt_path, html_path)
      args = [
        odt_path,
        html_path,
        "#{@project.name} report",
        @project.csys_report_code.to_s,
        report_application_version,
        Date.current.iso8601,
        @project.cscode.to_s,
        @project.name,
        @project.identifier.to_s,
        @project.default_version&.name.to_s
      ].map { |value| macro_argument(value) }.join(',')
      "macro:///Standard.csys.Headless(#{args})"
    end

    def report_application_version
      provider = @project.cosmosys_project_profile_definition.provider
      plugin = Redmine::Plugin.find(provider)
      plugin&.version.to_s.presence || Redmine::Plugin.find(:cosmosys).version.to_s
    end

    def macro_argument(value)
      %Q{"#{value.to_s.tr('"', "'")}"}
    end

    def safe_filename(value)
      value.to_s.gsub(/[^0-9A-Za-z._-]+/, '_').presence || 'cosmosys-report'
    end
  end
end
