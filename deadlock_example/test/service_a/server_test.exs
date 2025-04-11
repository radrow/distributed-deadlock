defmodule ServiceA.ServerTest do
  use ExUnit.Case

  setup_all do
    :io.format(~c"INIT TEST\n")

    {logKnown, logFresh} = :logging.mk_ets()
    log_opts = [{:logging_ets_known, logKnown},
                {:logging_ets_fresh, logFresh},
                {:live_log, :true},
                {:trace_int, :false},
                {:trace_proc, :false},
                {:trace_mon, :true},
                {:indent, 0},
               ]
    :logging.conf(log_opts)
    :tracer.start_link([], log_opts)
    :ok

    # on_exit(fn ->
    #   :io.format(~c"EXITING TEST\n")
    #   log = :tracer.finish(:dls_tracer)
    #   :logging.delete()
    # end)
  end

  setup do
    username = Application.fetch_env!(:amqp_lib, :username)
    password = Application.fetch_env!(:amqp_lib, :password)
    host = Application.fetch_env!(:amqp_lib, :host)
    connection_params = [username: username, password: password, host: host]

    {:ok, %{connection_params: connection_params}}
  end

  describe "RPC request to compute" do
    # test "id 1 works fine", %{connection_params: connection_params} do
    #   id = 1
    #   p0 = start_supervised!({AMQPLib.Producer, connection_params})

    #   sa = start_supervised!({ServiceA.Server, id: id})
    #   ca = start_supervised!({ServiceA.Consumer, connection_params})
    #   sb = start_supervised!({ServiceB.Server, id: id})
    #   cb = start_supervised!({ServiceB.Consumer, connection_params})

    #   assert {:ok, 1_000_000 + id} == ServiceA.Server.compute(id)
    # end

    test "id 42 has a bug and deadlocks until timeouts are triggered", %{
      connection_params: connection_params
    } do
      :io.format(~c"########\n### TESTING PID: ~w\n########\n", [self()])

      id = 42
      pid_producer = start_supervised!({AMQPLib.Producer, connection_params})

      pid_server_a = start_supervised!({ServiceA.Server, id: id})
      ref_server_a = Process.monitor(pid_server_a)

      pid_consumer_a = start_supervised!({ServiceA.Consumer, connection_params})

      pid_server_b = start_supervised!({ServiceB.Server, id: id})
      ref_server_b = Process.monitor(pid_server_b)

      pid_consumer_b = start_supervised!({ServiceB.Consumer, connection_params})

      :tracer.add_tracee_glob({pid_server_a, :P, 0})
      :tracer.add_tracee_glob({pid_server_b, :P, 1})
      :tracer.add_tracee_glob({pid_producer, :I, 0})
      :tracer.add_tracee_glob({pid_consumer_a, :M, 0})
      :tracer.add_tracee_glob({pid_consumer_b, :M, 1})

      bin_req = Proto.encode(42)

      try do
        {:ok, _res} = ServiceA.Api.compute(id)
        assert false, "ServiceA.Api.compute(#{id}) call should have timed out"
      catch
        :exit,
        {:timeout,
         {:gen_server, :call,
          [_, {:amqp_call, "amq.direct", "service_a.compute", ^bin_req}, 5000]}} ->
          assert true
      end

      assert_receive(
        {:DOWN, ^ref_server_a, :process, ^pid_server_a,
         {:timeout,
          {:gen_statem, :call,
           [_,
            {{:amqp_call, "amq.direct", "service_b.compute", ^bin_req}, AMQPLib.Producer},
            5000]}}},
        100
      )

      refute Process.alive?(pid_server_a)
      assert Process.alive?(pid_consumer_a)

      assert_receive(
        {:DOWN, ^ref_server_b, :process, ^pid_server_b,
         {:timeout,
          {:gen_statem, :call,
           [_,
            {{:amqp_call, "amq.direct", "service_a.compute", ^bin_req}, AMQPLib.Producer},
            5000]}}},
        100
      )

      refute Process.alive?(pid_server_b)
      assert Process.alive?(pid_consumer_b)

      assert Process.alive?(pid_producer)
    end
  end
end
