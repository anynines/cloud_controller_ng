module VCAP::CloudController::Models
  class QuotaDefinitionAccess < BaseAccess
    def read?(quota_definition)
      super || logged_in?
    end
  end
end