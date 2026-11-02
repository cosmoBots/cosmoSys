require 'set'
require 'bigdecimal'
require_relative 'model_yaml_document'

module Cosmosys
  # Explicit export of a previously authorized selection. Preview never selects.
  class ModelYamlCapture
    def self.call(entries:, relations:, profile:, focus: nil)
      flatten = lambda { |rows| rows.flat_map { |row| [row] + flatten.call(Array(row[:children])) } }
      entries = flatten.call(entries)
      raise ModelYamlDocument::Invalid, 'Selection is too large for a YAML preview (500 items)' if entries.size > ModelYamlDocument::MAX_ITEMS
      dialect = ModelYamlDialects.fetch(profile)
      types = dialect.types.invert
      ids = entries.map { |entry| entry.fetch(:issue).id }.to_set
      data = {'format' => 'cosmosys-model', 'version' => 1, 'project_profile' => profile,
              'projects' => {}, 'items' => {}, 'relations' => []}
      entries.each_with_index do |entry, index|
        issue = entry.fetch(:issue)
        type = types[issue.cosmosys_item_kind_key]
        raise ModelYamlDocument::Invalid, "Unsupported item profile #{issue.cosmosys_item_kind_key}" unless type
        data['projects']["p#{issue.project_id}"] ||= {'name' => issue.project.name}
        row = {'type' => type, 'project' => "p#{issue.project_id}", 'subject' => issue.subject,
               'description' => issue.description.to_s, 'source_id' => issue.id, 'csid' => issue.csid,
               'position' => index + 1, 'boundary' => entry[:boundary] == true,
               'closed' => issue.status.is_closed?, 'done_ratio' => issue.done_ratio,
               'fields' => dialect.fields.invert.filter_map do |attr, key|
                 value = issue[attr]
                 [key, value.is_a?(BigDecimal) ? value.to_s('F') : value] unless value.nil?
               end.to_h}
        row['parent'] = "i#{issue.parent_id}" if ids.include?(issue.parent_id)
        if issue.cosmosys_item_kind.value(:reference_mode, issue, kind: 'combined').to_s == 'chapter'
          chapter = issue.cosmosys_chapter
          row['chapter'] = chapter if chapter
        end
        row['assigned_to_id'] = issue.assigned_to_id if issue.assigned_to_id
        row['due_date'] = issue.due_date.iso8601 if issue.due_date
        data['items']["i#{issue.id}"] = row
      end
      relations.each do |relation|
        next unless ids.include?(relation.issue_from_id) && ids.include?(relation.issue_to_id)
        row = {'from' => "i#{relation.issue_from_id}", 'to' => "i#{relation.issue_to_id}", 'type' => relation.relation_type}
        row['delay'] = relation.delay if relation.delay
        data['relations'] << row
      end
      data['diagram'] = {'focus' => "i#{focus.id}"} if focus && ids.include?(focus.id)
      text = YAML.dump(data)
      ModelYamlDocument.new(text, expected_profile: profile)
      text
    end
  end
end
