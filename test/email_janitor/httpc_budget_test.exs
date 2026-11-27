defmodule EmailJanitor.HttpcBudgetTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures, only: [inbox: 0]
  alias EmailJanitor.Gmail.Config

  test "the synchronous mutation timeout includes time queued behind a slow HTTP read" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    observer = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        read_headers(socket, "")
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        read_headers(socket, "")
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nx")
        send(observer, :read_waiting_for_body)

        receive do
          :inspect_queue ->
            # A queued keep-alive request has not been written to the busy socket
            # and has not opened another connection to our synthetic endpoint.
            assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 20)
            assert {:error, :timeout} = :gen_tcp.accept(listener, 20)
            send(observer, :request_was_queued)
        end

        receive do
          :finish ->
            :ok = :gen_tcp.send(socket, String.duplicate("x", 999))
            assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)
            send(observer, :cancelled_request_was_not_sent_later)
            :gen_tcp.close(socket)
        end
      end)

    {:ok, config} = Config.new(inbox(), fn -> {:ok, "unused-synthetic-token"} end)

    assert {:ok, %{status: 200}} =
             Tesla.get(
               Tesla.client([], Config.transport(config)),
               "http://127.0.0.1:#{port}/warmup"
             )

    reader =
      Task.async(fn ->
        Tesla.get(Tesla.client([], Config.transport(config)), "http://127.0.0.1:#{port}/read")
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
      if Process.alive?(reader.pid), do: Process.exit(reader.pid, :kill)
    end)

    assert_receive :read_waiting_for_body, 1000

    {adapter, options} = Config.mutation_transport(config)
    # Keep the production synchronous adapter/pool behavior; shorten only the
    # request deadline so this real local-network regression finishes promptly.
    client = Tesla.client([], {adapter, Keyword.put(options, :timeout, 300)})
    started = System.monotonic_time(:millisecond)

    mutation =
      Task.async(fn -> Tesla.post(client, "http://127.0.0.1:#{port}/mutation", "synthetic") end)

    send(server, :inspect_queue)
    assert_receive :request_was_queued, 1000
    assert {:error, :timeout} = Task.await(mutation, 1500)
    assert System.monotonic_time(:millisecond) - started < 1500
    assert Task.yield(reader, 0) == nil
    send(server, :finish)
    assert {:ok, %{status: 200}} = Task.await(reader, 1000)
    assert_receive :cancelled_request_was_not_sent_later, 1000
  end

  defp read_headers(socket, data) do
    if String.contains?(data, "\r\n\r\n") do
      :ok
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1000)
      read_headers(socket, data <> chunk)
    end
  end
end
