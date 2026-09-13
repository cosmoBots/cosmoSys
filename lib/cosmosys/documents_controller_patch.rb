module Cosmosys
  module DocumentsControllerPatch
    def destroy
      if request.delete? && !@document.destroy
        flash[:error] = @document.errors.full_messages.join(', ')
      end
      redirect_to project_documents_path(@project)
    end
  end
end
