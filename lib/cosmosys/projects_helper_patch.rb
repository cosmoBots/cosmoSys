module Cosmosys
  module ProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      return tabs unless User.current.allowed_to?(:edit_project, @project)

      tabs << {
        name: 'cosmosys',
        action: :edit_project,
        partial: 'projects/settings/cosmosys',
        label: :label_cosmosys_settings
      }
      tabs
    end
  end
end
