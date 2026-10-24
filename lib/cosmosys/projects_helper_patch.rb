module Cosmosys
  module ProjectsHelperPatch
    def render_project_action_links
      links = super
      return links if @project || !User.current.admin?

      safe_join([links, link_to(sprite_icon('import', l(:button_cosmosys_import_project_snapshot)),
                               new_cosmosys_snapshot_import_path, class: 'icon icon-import')], ' ')
    end

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
