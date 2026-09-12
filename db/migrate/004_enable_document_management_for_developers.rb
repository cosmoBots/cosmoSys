class EnableDocumentManagementForDevelopers < ActiveRecord::Migration[6.1]
  def up
    developer = Role.where('LOWER(name) = ?', 'developer').first
    return unless developer

    permissions = Array(developer.permissions).map(&:to_sym)
    developer.update!(permissions: permissions | [:add_documents, :edit_documents])
  end

  # Role permissions are administrator-owned configuration after installation.
  # Rolling back plugin schema must not silently revoke permissions which an
  # administrator may also have selected explicitly.
  def down; end
end
