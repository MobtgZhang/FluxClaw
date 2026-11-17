defmodule Mix.Tasks.Fluxclaw.ServeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Fluxclaw.Serve

  test "default startup skips an occupied port without interrupting its listener" do
    occupied = listen!()
    available = listen!()
    {:ok, {_, occupied_port}} = :inet.sockname(occupied)
    {:ok, {_, available_port}} = :inet.sockname(available)
    :ok = :gen_tcp.close(available)

    assert Serve.select_port!(nil, [occupied_port, available_port]) == available_port
    assert {:ok, _} = :inet.sockname(occupied)
  end

  test "an explicitly requested occupied port gives actionable feedback" do
    occupied = listen!()
    {:ok, {_, port}} = :inet.sockname(occupied)

    assert_raise Mix.Error, ~r/PORT=.*make serve/, fn ->
      Serve.select_port!(to_string(port))
    end

    assert {:ok, _} = :inet.sockname(occupied)
  end

  test "explicit free ports are respected and the probe releases its socket" do
    socket = listen!()
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    assert Serve.select_port!(to_string(port)) == port
    assert {:ok, socket} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})
    :gen_tcp.close(socket)
  end

  test "invalid ports and exhausted fallback ports fail clearly" do
    for port <- ["0", "65536", "abc", "4000oops", ""] do
      assert_raise Mix.Error, ~r/1.*65535/, fn -> Serve.select_port!(port) end
    end

    occupied = listen!()
    {:ok, {_, port}} = :inet.sockname(occupied)

    assert_raise Mix.Error, ~r/PORT=.*make serve/, fn ->
      Serve.select_port!(nil, [port])
    end
  end

  defp listen! do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end
end
