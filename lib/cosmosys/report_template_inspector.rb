require 'nokogiri'
require 'zip'

module Cosmosys
  class ReportTemplateInspector
    Page = Struct.new(:page_width_px, :page_height_px, :content_width_px, :content_height_px, :orientation, :style_name, keyword_init: true) do
      def landscape? = orientation == 'landscape'
    end
    Result = Struct.new(:current_page, :donor_pages, keyword_init: true) do
      delegate :page_width_px, :page_height_px, :content_width_px, :content_height_px, :orientation, :landscape?, to: :current_page
      def donor_for(orientation) = donor_pages[orientation.to_s]
    end

    ODF_NAMESPACES = {
      'style' => 'urn:oasis:names:tc:opendocument:xmlns:style:1.0',
      'text' => 'urn:oasis:names:tc:opendocument:xmlns:text:1.0',
      'fo' => 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0'
    }.freeze

    def self.call(path)
      styles_xml, content_xml = Zip::File.open(path.to_s) { |archive| [archive.read('styles.xml'), archive.read('content.xml')] }
      document = Nokogiri::XML(styles_xml)
      content = Nokogiri::XML(content_xml)
      master = document.at_xpath('//style:master-page[@style:name="Standard"]', ODF_NAMESPACES) ||
               document.at_xpath('//style:master-page[1]', ODF_NAMESPACES)
      raise ArgumentError, 'Report template has no page style' unless master

      current_page = page_for_master(document, master)
      donors = {
        'landscape' => donor_page(document, content, 'COSMOSYS LANDSCAPE TEMPLATE'),
        'portrait' => donor_page(document, content, 'COSMOSYS PORTRAIT TEMPLATE')
      }.compact
      Result.new(current_page: current_page, donor_pages: donors.freeze)
    rescue Zip::Error, Errno::ENOENT, KeyError => error
      raise ArgumentError, "Invalid report template: #{error.message}", cause: error
    end

    def self.donor_page(styles, content, marker)
      paragraph = content.xpath('//text:p', ODF_NAMESPACES).find { |node| node.text.include?(marker) }
      return unless paragraph

      style_name = paragraph['text:style-name']
      paragraph_style = content.at_xpath('//style:style[@style:name=$name]', ODF_NAMESPACES, name: style_name) ||
                        styles.at_xpath('//style:style[@style:name=$name]', ODF_NAMESPACES, name: style_name)
      master_name = paragraph_style&.[]('style:master-page-name')
      master = styles.at_xpath('//style:master-page[@style:name=$name]', ODF_NAMESPACES, name: master_name)
      raise ArgumentError, "Report template donor #{marker} has no page style" unless master

      page_for_master(styles, master)
    end
    private_class_method :donor_page

    def self.page_for_master(document, master)
      layout_name = master['style:page-layout-name']
      properties = document.at_xpath('//style:page-layout[@style:name=$layout]/style:page-layout-properties', ODF_NAMESPACES, layout: layout_name)
      raise ArgumentError, 'Report template page style has no layout properties' unless properties

      width = odf_length_to_px(properties['fo:page-width'])
      height = odf_length_to_px(properties['fo:page-height'])
      left = odf_length_to_px(properties['fo:margin-left']) || 0
      right = odf_length_to_px(properties['fo:margin-right']) || 0
      top = odf_length_to_px(properties['fo:margin-top']) || 0
      bottom = odf_length_to_px(properties['fo:margin-bottom']) || 0
      orientation = properties['style:print-orientation'].presence || (width.to_f > height.to_f ? 'landscape' : 'portrait')
      unless width&.positive? && height&.positive? && width > left + right && height > top + bottom
        raise ArgumentError, 'Report template page dimensions are invalid'
      end

      Page.new(
        page_width_px: width, page_height_px: height,
        content_width_px: width - left - right, content_height_px: height - top - bottom,
        orientation: orientation, style_name: master['style:name']
      )
    end
    private_class_method :page_for_master

    def self.odf_length_to_px(value)
      match = value.to_s.strip.match(/\A([0-9]+(?:\.[0-9]+)?)(cm|mm|in|pt)\z/i)
      return unless match

      number = match[1].to_f
      case match[2].downcase
      when 'cm' then number * 96.0 / 2.54
      when 'mm' then number * 96.0 / 25.4
      when 'in' then number * 96.0
      when 'pt' then number * 96.0 / 72.0
      end
    end
    private_class_method :odf_length_to_px
  end
end
