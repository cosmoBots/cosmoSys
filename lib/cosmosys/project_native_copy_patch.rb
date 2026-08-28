require_dependency 'project'

module Cosmosys
  module ProjectNativeCopyPatch
    private

    def copy_documents(project)
      context = Cosmosys::ProjectCopyContext.current
      return super unless context&.source_project == project

      project.documents.each do |source|
        copy = Document.new
        copy.attributes = source.attributes.dup.except('id', 'project_id')
        copy.project = self
        copy.attachments = source.attachments.map { |attachment| attachment.copy(container: copy) }
        documents << copy
        raise Cosmosys::ProjectCopyError, "Document #{source.id} could not be copied: #{copy.errors.full_messages.join(', ')}" if copy.new_record?

        context.register_document(source.id, copy)
      end
    end
  end
end
