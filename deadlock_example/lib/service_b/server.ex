defmodule ServiceB.Server do
  alias :ddmon, as: GenServer

  require Logger

  @spec compute(non_neg_integer()) :: {:ok, non_neg_integer()}
  def compute(id) do
    GenServer.call({:global, {:server_b, id}}, :compute)
  end

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      type: :worker
    }
  end

  @spec start_link(non_neg_integer()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, [id], name: {:global, {:server_b, id}})
  end

  @impl GenServer
  def init([id]) do
    {:ok, %{id: id}}
  end

  @impl GenServer
  def handle_call(:compute, _from, state = %{id: id}) do
    Logger.info("#{node()}:#{inspect(self())}:#{__MODULE__} handling #{:compute} with id: #{id}")

    if id == 42 do
      {:ok, result} = ServiceA.Api.compute(id)
      {:reply, {:ok, result}, state}
    else
      {:reply, {:ok, id}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Logger.info("Process #{inspect({__MODULE__, self()})} terminating")
    :ok
  end
end
