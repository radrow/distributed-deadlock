defmodule AMQPLib.Worker do
  @moduledoc """
  Worker process bridges between consumer and service implementation.
  """
  alias :ddmon, as: GenServer
  use AMQP

  require Logger

  @impl GenServer
  def start_link(handler_fun) do
    GenServer.start_link(__MODULE__, [handler_fun])
  end

  @impl GenServer
  def init([handler_fun]) do
    {:ok, %{handler_fun: handler_fun}}
  end

  @impl GenServer
  def handle_call({payload, meta}, from, state) do
    {:reply, r} = state.handler_fun.(payload, meta)

    {:reply, r, state}
  end

  @impl GenServer
  def handle_cast(_, state) do
    {:noreply, state}
  end
end
