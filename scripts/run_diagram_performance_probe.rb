require 'benchmark'
require 'json'

identifier = ENV.fetch('PROJECT_IDENTIFIER', ARGV.first.presence || 'est-00cs')
project = Project.find_by!(identifier: identifier)
User.current = User.find_by!(login: ENV.fetch('USER_LOGIN', 'admin'))

services = {
  hierarchy: -> { Cosmosys::ProjectHierarchyDiagramService.fetch(project) },
  dependency: -> { Cosmosys::ProjectDependencyDiagramService.fetch(project) },
  combined: -> { Cosmosys::ProjectCombinedDiagramService.fetch(project) }
}

Cosmosys::Diagram.where(project_id: project.id).delete_all
results = %w[cold warm].to_h do |cache_state|
  timings = services.to_h do |name, operation|
    [name, (Benchmark.realtime { operation.call } * 1000).round(1)]
  end
  [cache_state, timings]
end

puts({ project: project.identifier, duration_ms: results }.to_json)
puts 'Component timings are emitted as cosmosys_performance JSON events in the Rails log.'
