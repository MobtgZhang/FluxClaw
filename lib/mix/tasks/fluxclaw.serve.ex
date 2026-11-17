defmodule Mix.Tasks.Fluxclaw.Serve do
  use Mix.Task

  @shortdoc "Starts the shared web/desktop development backend"
  @moduledoc """
  Starts the development backend after migrating the database.

  Uses PORT when specified, otherwise the first available loopback port in
  4000..4019. Electron supplies FLUXCLAW_DESKTOP_PORT to select its own port.
  """

  @impl true
  def run(_args) do
    if Mix.env() != :dev, do: Mix.raise("fluxclaw.serve requires MIX_ENV=dev")

    requested = System.get_env("FLUXCLAW_DESKTOP_PORT") || System.get_env("PORT")
    port = select_port!(requested)

    if requested == nil and port != 4000 do
      Mix.shell().info("Port 4000 is busy; using port #{port}.")
    end

    # Set before app.config so runtime configuration and endpoint URLs agree.
    System.put_env("PORT", to_string(port))
    Mix.Task.run("app.config")
    Mix.Task.run("ecto.migrate")
    Mix.shell().info("FluxClaw: http://127.0.0.1:#{port}")
    Mix.Task.run("phx.server")
  end

  @doc false
  def select_port!(requested, fallback_ports \\ 4000..4019)

  def select_port!(nil, fallback_ports) do
    Enum.find(fallback_ports, &available?/1) ||
      Mix.raise("No free development port. Choose another with PORT=4100 make serve.")
  end

  def select_port!(requested, _fallback_ports) do
    case Integer.parse(requested) do
      {port, ""} when port in 1..65535 ->
        if available?(port),
          do: port,
          else: Mix.raise("Port #{port} is busy. Choose another with PORT=4100 make serve.")

      _ ->
        Mix.raise("PORT must be an integer between 1 and 65535.")
    end
  end

  defp available?(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, active: false, reuseaddr: false) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false

      {:error, reason} ->
        Mix.raise("Cannot bind port #{port}: #{:inet.format_error(reason)}")
    end
  end
end
