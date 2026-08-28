require 'cgi'
require 'digest'
require 'fileutils'

module Cosmosys
  module DiagramCacheSupport
    private

    def fetch_cached_diagram(scope_attrs:, kind:, empty:, signature: nil, revision_state: nil, render_variant: '', layout_mode: '')
      lookup = scope_attrs.merge(
        kind: kind,
        render_variant: render_variant.to_s,
        layout_mode: layout_mode.to_s
      )
      diagram = Cosmosys::Diagram.find_or_initialize_by(lookup)
      trace_attributes = scope_attrs.merge(kind: kind, render_variant: render_variant.to_s, layout_mode: layout_mode.to_s)
      if diagram_cache_valid?(diagram, empty: empty, signature: signature, revision_state: revision_state)
        Cosmosys::PerformanceTrace.emit('diagram.cache_hit', trace_attributes.merge(cache: 'warm'), Process.clock_gettime(Process::CLOCK_MONOTONIC))
        return diagram
      end

      with_diagram_generation_lock(lookup) do
        diagram = Cosmosys::Diagram.find_or_initialize_by(lookup)
        if diagram_cache_valid?(diagram, empty: empty, signature: signature, revision_state: revision_state)
          Cosmosys::PerformanceTrace.emit('diagram.cache_hit', trace_attributes.merge(cache: 'waited'), Process.clock_gettime(Process::CLOCK_MONOTONIC))
          next diagram
        end

        generated_at = Time.current
        metadata = diagram_metadata(
          scope_attrs: scope_attrs,
          kind: kind,
          signature: signature,
          revision_state: revision_state,
          generated_at: generated_at,
          render_variant: render_variant,
          layout_mode: layout_mode
        )

        dot_source = empty ? nil : Cosmosys::PerformanceTrace.measure('diagram.gv', trace_attributes.merge(cache: 'cold')) { yield }
        dot_body = dot_source.present? ? embed_dot_metadata(dot_source, metadata) : nil
        svg_source = dot_body.present? ? Cosmosys::PerformanceTrace.measure('diagram.svg', trace_attributes.merge(cache: 'cold')) { renderer.render_svg(dot_body) } : nil
        svg_body = svg_source.present? ? embed_svg_metadata(svg_source, metadata) : nil

        Cosmosys::PerformanceTrace.measure('diagram.persist', trace_attributes.merge(cache: 'cold')) do
          persist_cached_diagram!(
            diagram,
            dot_body: dot_body,
            svg_body: svg_body,
            signature: signature,
            revision_state: revision_state,
            generated_at: generated_at,
            render_variant: render_variant,
            layout_mode: layout_mode
          )
        end
      end
    end

    def with_diagram_generation_lock(lookup)
      lock_root = Rails.root.join('files', 'cosmosys', 'diagram_locks')
      FileUtils.mkdir_p(lock_root)
      lock_key = Digest::SHA256.hexdigest(lookup.sort_by { |key, _value| key.to_s }.flatten.join("\0"))
      File.open(lock_root.join("#{lock_key}.lock"), File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def diagram_cache_valid?(diagram, empty:, signature:, revision_state:)
      return false unless diagram.state == 'ready'
      return false if empty && (diagram.svg_body.present? || diagram.dot_body.present?)
      return false if !empty && diagram.svg_body.blank?

      if revision_state.present?
        revision_matches = diagram.root_generation.to_i == revision_state[:root_generation] &&
                           diagram.tree_revision.to_i == revision_state[:revision]
        signature_matches = signature.nil? || diagram.signature == signature
        revision_matches && signature_matches
      else
        diagram.signature == signature
      end
    end

    def persist_cached_diagram!(diagram, dot_body:, svg_body:, signature: nil, revision_state: nil, generated_at:, render_variant:, layout_mode:)
      diagram.update!(
        render_variant: render_variant.to_s,
        layout_mode: layout_mode.to_s,
        state: 'ready',
        root_generation: revision_state&.fetch(:root_generation, 0) || 0,
        tree_revision: revision_state&.fetch(:revision, 0) || 0,
        signature: signature,
        dot_body: dot_body,
        svg_body: svg_body,
        generated_at: generated_at
      )

      diagram
    end

    def diagram_metadata(scope_attrs:, kind:, signature:, revision_state:, generated_at:, render_variant:, layout_mode:)
      metadata = {
        'kind' => kind,
        'generated_at' => generated_at.utc.iso8601
      }

      if scope_attrs[:issue_id].present?
        metadata['issue_id'] = scope_attrs[:issue_id].to_s
      elsif scope_attrs[:project_id].present?
        metadata['project_id'] = scope_attrs[:project_id].to_s
      end

      metadata['render_variant'] = render_variant.to_s if render_variant.present?
      metadata['layout_mode'] = layout_mode.to_s if layout_mode.present?
      metadata['signature'] = signature.to_s if signature.present?

      if revision_state.present?
        metadata['root_issue_id'] = revision_state[:root_issue]&.id.to_s if revision_state[:root_issue]
        metadata['root_generation'] = revision_state[:root_generation].to_s
        metadata['tree_revision'] = revision_state[:revision].to_s
      end

      metadata
    end

    def embed_dot_metadata(dot_body, metadata)
      comment_lines = metadata.map { |key, value| %(// cosmosys:#{key}=#{value}) }
      (comment_lines + [dot_body]).join("\n")
    end

    def embed_svg_metadata(svg_body, metadata)
      metadata_xml = +"<metadata id=\"cosmosys-diagram-metadata\" xmlns:cosmosys=\"https://cosmobots.eu/ns/cosmosys/diagram/1\">\n"
      metadata.each do |key, value|
        metadata_xml << "  <cosmosys:#{CGI.escapeHTML(key.to_s)}>#{CGI.escapeHTML(value.to_s)}</cosmosys:#{CGI.escapeHTML(key.to_s)}>\n"
      end
      metadata_xml << "</metadata>\n"

      desc_xml = "<desc>#{CGI.escapeHTML(metadata.map { |key, value| "#{key}=#{value}" }.join(' | '))}</desc>\n"

      svg_body.sub(/<svg\b([^>]*)>/, '<svg\1>' + "\n" + metadata_xml + desc_xml)
    end
  end
end
