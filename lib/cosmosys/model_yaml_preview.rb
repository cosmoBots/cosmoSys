require 'set'
require_relative 'model_yaml_document'
require_relative 'combined_diagram_renderer'

module Cosmosys
  # Unsaved, readonly native records reuse the production presentation methods.
  # They never pass through persistence callbacks, selectors or diagram caches.
  class ModelYamlPreview
    attr_reader :document, :items, :relations, :roots

    def initialize(document)
      @document = document
      projects = document.projects.each_with_index.to_h do |(key, row), index|
        project = Project.new(id: index + 1, name: row.fetch('name'), cscode: row['cscode'],
          csys_project_profile: document.profile, csys_calculate_requirement_chain_validity: false)
        project.readonly!
        [key, project]
      end
      reserved = document.items.values.filter_map { |row| row['source_id'] }.to_set
      next_id = 0
      @items = document.items.each_with_index.to_h do |(key, row), index|
        next_id += 1 while reserved.include?(next_id) || next_id.zero?
        id = row['source_id'] || next_id
        reserved << id
        tracker = Tracker.new(id: index + 1, name: row.fetch('type'), csys_item_kind: document.dialect.types.fetch(row.fetch('type')))
        status = IssueStatus.new(id: index + 1, name: row['closed'] ? 'Closed' : 'Open', is_closed: row['closed'] == true)
        tracker.readonly!
        status.readonly!
        issue = Issue.new(id: id, subject: row.fetch('subject'), description: row['description'].to_s,
          csid: row['csid'] || key, csposition: row.fetch('position', index + 1),
          done_ratio: row.fetch('done_ratio', 0), due_date: row['due_date'], assigned_to_id: row['assigned_to_id'])
        {project: projects.fetch(row.fetch('project')), tracker: tracker, status: status}.each do |name, target|
          issue["#{name}_id"] = target.id
          issue.association(name).target = target
        end
        row.fetch('fields', {}).each { |field, value| issue[document.dialect.fields.fetch(field)] = value }
        chapter = row['chapter']
        issue.define_singleton_method(:cosmosys_chapter) { chapter }
        [key, issue]
      end
      document.items.each do |key, row|
        parent = row['parent'] && items.fetch(row['parent'])
        items.fetch(key)[:parent_id] = parent&.id
        items.fetch(key).association(:parent).target = parent
      end
      items.each_value(&:readonly!)
      @relations = document.relations.map do |row|
        relation = IssueRelation.new(relation_type: row.fetch('type'), delay: row['delay'])
        relation.issue_from = items.fetch(row.fetch('from'))
        relation.issue_to = items.fetch(row.fetch('to'))
        relation.readonly!
        relation
      end
      children = document.items.keys.group_by { |key| document.items.fetch(key)['parent'] }
      positions = document.items.keys.each_with_index.to_h
      children.each_value do |keys|
        keys.sort_by! { |key| [document.items.fetch(key).fetch('position', positions.fetch(key) + 1), positions.fetch(key)] }
      end
      build = lambda do |key|
        {issue: items.fetch(key), boundary: document.items.fetch(key)['boundary'] == true,
         children: Array(children[key]).map { |child| build.call(child) }}
      end
      @roots = Array(children[nil]).map { |key| build.call(key) }
    end

    def dot
      profile = ProjectProfileRegistry.fetch(document.profile)
      options = document.data.fetch('diagram', {})
      containers = document.items.filter_map { |key, _| items.fetch(key).id if document.items.values.any? { |row| row['parent'] == key } }.to_set
      endpoints = relations.flat_map { |relation| [relation.issue_from.id, relation.issue_to.id] }.to_set
      policy = options.fetch('container_policy', profile.combined_diagram_container_node_policy)
      titles = policy == 'related_only' ? containers & endpoints : containers
      renderer = CombinedDiagramRenderer.new(cluster_title_issue_ids: titles,
        current_issue: options['focus'] && items.fetch(options['focus']),
        cluster_anchor_issue_ids: (containers & endpoints) - titles,
        rankdir: options.fetch('rankdir', relations.any? { |relation| %w[blocks precedes].include?(relation.relation_type) } ? profile.combined_diagram_rankdir : 'TB'),
        issue_url_resolver: ->(_issue) { '' })
      renderer.build_graph(title: options['focus'] ? 'cosmosys_combined' : 'cosmosys_project_combined') do |lines|
        roots.each { |entry| lines.concat(renderer.build_tree(entry)) }
        relations.each { |relation| lines.concat(renderer.build_edge(relation)) }
      end
    end

    def svg
      output, errors, status = CancellableGraphviz.capture(dot, timeout: 10)
      raise ModelYamlDocument::Invalid, "Graphviz: #{errors.to_s.first(1000)}" unless status.success?

      output.sub(/\A.*?<svg/m, '<svg')
    end
  end
end
