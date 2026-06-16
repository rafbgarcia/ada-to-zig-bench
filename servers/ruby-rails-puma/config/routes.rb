Rails.application.routes.draw do
  get "/health", to: "bench#health"
  get "/runtime", to: "bench#runtime"
  post "/json", to: "bench#json"
  match "*path", to: "bench#not_found", via: :all
end
