defmodule AMQPLib.Consumer do
  @moduledoc """
  Consumer process assigns a worker to each request.
  """
  use GenServer
  use AMQP
  alias :ddmon, as: GenServer

  require Logger

  @doc """
  Consumer declares a queue, binds it to the `exchange` with provided `routing_key`.
  When message is received, it replies with the PID of the worker that is supposed to handle the main request.

  If the `exchange` parameter is an empty string the direct exchange will be used (equivalent to `"amqp.direct"`).
  If the `queue` parameter is an empty string an auto-generated queue name will be used.
  """
  @spec start_link(
          {AMQPLib.connection_params(), String.t(), String.t(), String.t(),
           (binary(), map() -> {:reply, binary()})}
        ) :: GenServer.on_start()
  def start_link({connection_params, exchange, routing_key, queue, handler_fun}) do
    GenServer.start_link(__MODULE__, [
      {connection_params, exchange, routing_key, queue, handler_fun}
    ])
  end

  @impl GenServer
  def init([{connection_params, exchange, routing_key, queue, handler_fun}]) do
    {:ok, connection} = Connection.open(connection_params)
    {:ok, channel} = AMQP.Channel.open(connection)
    {:ok, _} = AMQP.Queue.declare(channel, queue)
    :ok = AMQP.Queue.bind(channel, queue, exchange, routing_key: routing_key)
    :ok = AMQP.Basic.qos(channel, prefetch_count: 0)
    {:ok, tag} = AMQP.Basic.consume(channel, queue, nil, no_ack: true)

    Process.flag(:trap_exit, true)
    {:ok, worker} = AMQPLib.Worker.start_link(handler_fun)

    {:ok,
     %{channel: channel,
       consumer_tag: tag,
       connection: connection,
       worker: worker,
     }}
  end

  @impl GenServer
  def handle_info({:basic_consume_ok, _}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:basic_deliver, "get_worker", meta}, state) do
    worker_bin = :erlang.term_to_binary({:here_i_am, state.worker})
    :ok = worker_bin |> reply(meta, state.channel)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, who, e}, state) do
    case who == state.worker do
      true -> {:stop, :shutdown, state}
      _ -> {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    AMQP.Basic.cancel(state.channel, state.consumer_tag)
    AMQP.Channel.close(state.channel)
    AMQP.Connection.close(state.connection)
    Logger.info("Consumer #{inspect({__MODULE__, self()})} terminating")
    :ok
  end

  defp reply(
         resp_payload,
         %{reply_to: reply_to, correlation_id: correlation_id} = meta,
         chan
       ) do

    case AMQP.Basic.publish(chan, "", reply_to, resp_payload,
           correlation_id: correlation_id
         ) do
      :ok ->
        Logger.info("Sending reply #{inspect({resp_payload, meta})}")
        :ok

      error ->
        Logger.warn(
          "Bad publish result  #{inspect(error)} on reply #{inspect(resp_payload)}, #{meta}"
        )

        error
    end
  end
end
