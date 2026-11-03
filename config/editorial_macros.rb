require_relative '../lib/cosmosys/model_yaml_diagram'

Redmine::WikiFormatting::Macros.register do
  desc "Render an explicit, read-only cosmoSys YAML model: {{cosmosys_diagram\nformat: cosmosys-model\n...\n}}"
  macro :cosmosys_diagram do |_object, args, text|
    raise l(:text_cosmosys_yaml_macro_usage) unless args.empty? && text.present?

    @cosmosys_yaml_diagram_index = @cosmosys_yaml_diagram_index.to_i + 1
    svg = Cosmosys::ModelYamlDiagram.render(text, instance_id: @cosmosys_yaml_diagram_index)
    content_tag(:div, svg.html_safe, class: 'cosmosys-report-diagram cosmosys-yaml-diagram-container')
  end

  desc 'Transparent spacing between adjacent images: {{image_gap(0.5cm)}} or {{image_gap(24px)}}'
  macro :image_gap do |_object, args|
    begin
      raise ArgumentError unless args.one?

      width = Cosmosys::ImageGap.width_px(args.first)
    rescue ArgumentError
      raise l(:text_cosmosys_image_gap_usage)
    end
    image_tag(Cosmosys::ImageGap::DATA_URL, alt: '', role: 'presentation',
              class: 'cosmosys-image-gap', width: width, height: 1,
              style: "width:#{width}px; height:1px")
  end

  desc 'Embed the description of an editorial document: {{document_embed(di123)}}'
  macro :document_embed do |object, args|
    raise l(:text_cosmosys_document_embed_usage) unless args.one? && args.first.to_s.strip.match?(/\Adi[1-9]\d*\z/)

    cosmosys_embed_document(args.first.to_s.strip.delete_prefix('di').to_i, object)
  end
end
