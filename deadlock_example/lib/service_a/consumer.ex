defmodule ServiceA.Consumer do
  require Logger

  @spec child_spec(AMQPLib.connection_params()) :: Supervisor.child_spec()
  def child_spec(connection_params) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [connection_params]},
      type: :worker
    }
  end

  @spec start_link(AMQPLib.connection_params()) :: GenServer.on_start()
  def start_link(connection_params) do
    :ddmon.start_link(
      AMQPLib.Consumer,
      [
        {connection_params, "amq.direct", "service_a.compute", "service_a.compute",
         &handle_message/2}
      ],
      name: __MODULE__
    )
  end

  defp handle_message(payload, meta) do
    Logger.info(
      "#{node()}:#{inspect(self())}:#{__MODULE__} Received #{inspect(payload)} with meta #{inspect(meta)}"
    )

    id = Proto.decode(payload)

    Logger.info(
      "#{node()}:#{inspect(self())}:#{__MODULE__} Sending to #{ServiceA.Server} #{inspect(id)}"
    )

    {:ok, result} = ServiceA.Server.compute(id)

    {:reply, Proto.encode(result)}
  end
end
