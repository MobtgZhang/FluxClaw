defmodule FluxClawWeb.Router do
  use FluxClawWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FluxClawWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FluxClawWeb do
    pipe_through :browser

    get "/agents", RedirectController, :to_chat
    get "/agents/:id", RedirectController, :agents_to_chat

    live "/", ChatLive, :chat
    live "/chat", ChatLive, :chat
    live "/chat/:id", ChatLive, :chat
    live "/p/:project_id", ChatLive, :chat
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxClawWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:flux_claw, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FluxClawWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
