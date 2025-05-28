defmodule AMQPLib.Producer do
  @moduledoc """
  Process for producing messages over AMQP..

  Note that only one `AMQP.Producer` should be started per erlang node.
  """
  use GenServer
  use AMQP

  require Logger

  @doc """
  Synchronous producer call.
  Blocks the caller until a reply is received on the reply queue (or until the call times out).
  """
  @spec call(String.t(), String.t(), binary()) ::
          {:ok, payload :: binary(), meta :: map()} | {:error, term()}
  def call(exchange, routing_key, payload) do
    {:ok, worker_bin, meta} =
              GenServer.call(
                __MODULE__,
                {:amqp_call, exchange, routing_key, :get_worker}
              )
    {:here_i_am, worker} = :erlang.binary_to_term(worker_bin)
    case :ddmon.call(worker, {payload, meta}) do
      {:'$ddmon_deadlock_spread', l} -> throw({:deadlock, l})
      res ->
        res = :erlang.term_to_binary(res)
        {:ok, res, meta}
    end
  end

  @spec start_link(AMQPLib.connection_params()) :: GenServer.on_start()
  def start_link(connection_params) do
    GenServer.start_link(__MODULE__, [connection_params], name: __MODULE__)
  end

  @impl GenServer
  def init(connection_params) do
    {:ok, connection} = Connection.open(connection_params)
    {:ok, channel} = Channel.open(connection)

    {:ok, %{queue: reply_queue_name}} =
      AMQP.Queue.declare(channel, _queue_name = "", auto_delete: true)

    {:ok, consumer_tag} = AMQP.Basic.consume(channel, reply_queue_name, nil, no_ack: true)

    AMQP.Basic.return(channel, self())

    {:ok,
     %{
       channel: channel,
       consumer_tag: consumer_tag,
       reply_queue: reply_queue_name,
       awaiting_replies: %{}
     }}
  end

  @impl GenServer
  def handle_call(
    {:amqp_call, exchange, routing_key, :get_worker},
    from,
    state
  ) do
    correlation_id = "#{System.unique_integer([:positive])}"

    :ok =
      AMQP.Basic.publish(
        state.channel,
        exchange,
        routing_key,
        "get_worker",
        correlation_id: correlation_id,
        reply_to: state.reply_queue,
        expiration: 1_000
      )

    {:noreply, %{state | awaiting_replies: Map.put(state.awaiting_replies, correlation_id, from)}}
  end

  @impl GenServer
  def handle_info({:basic_consume_ok, _}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(
        {:basic_deliver, data, %{correlation_id: correlation_id} = meta},
        state
      ) do
    Logger.info("Received a worker - #{inspect(meta)}")

    new_awaiting_replies =
      case Map.pop(state.awaiting_replies, correlation_id) do
        {nil, ^state} ->
          Logger.error("Unexpected reply received, correlation id: #{inspect(correlation_id)}")
          state

        {from, new_awaiting_replies} ->
          GenServer.reply(from, {:ok, data, meta})
          new_awaiting_replies
      end

    {:noreply, %{state | awaiting_replies: new_awaiting_replies}}
  end
end
