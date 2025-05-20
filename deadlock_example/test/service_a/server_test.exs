defmodule ServiceA.ServerTest do
  use ExUnit.Case

  setup_all do
    {logKnown, logFresh} = :logging.mk_ets()
    log_opts = [{:logging_ets_known, logKnown},
                {:logging_ets_fresh, logFresh},
                {:live_log, :true},
                {:trace_int, :true},
                {:trace_proc, :true},
                {:trace_mon, :true},
                {:indent, 0},
               ]
    :logging.conf(log_opts)
    :tracer.start_link([], log_opts)
    :ok
  end

  setup do
    username = Application.fetch_env!(:amqp_lib, :username)
    password = Application.fetch_env!(:amqp_lib, :password)
    host = Application.fetch_env!(:amqp_lib, :host)
    connection_params = [username: username, password: password, host: host]

    {:ok, %{connection_params: connection_params}}
  end

  describe "RPC request to compute" do
    test "id 1 works fine", %{connection_params: connection_params} do
      id = 1
      p0 = start_supervised!({AMQPLib.Producer, connection_params})

      sa = start_supervised!({ServiceA.Server, id: id})
      ca = start_supervised!({ServiceA.Consumer, connection_params})
      sb = start_supervised!({ServiceB.Server, id: id})
      cb = start_supervised!({ServiceB.Consumer, connection_params})

      assert {:ok, 1_000_000 + id} == ServiceA.Server.compute(id)
    end

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


      ppid_server_a =   :gen_statem.call(pid_server_a, :'$get_child')
      ppid_server_b =   :gen_statem.call(pid_server_b,    :'$get_child')
      ppid_consumer_a = :gen_statem.call(pid_consumer_a,  :'$get_child')
      ppid_consumer_b = :gen_statem.call(pid_consumer_b,  :'$get_child')

      :tracer.add_tracee_glob({pid_server_a, :M, 10})
      :tracer.add_tracee_glob({pid_server_b, :M, 11})
      :tracer.add_tracee_glob({pid_producer, :I, 0})
      :tracer.add_tracee_glob({pid_consumer_a, :M, 20})
      :tracer.add_tracee_glob({pid_consumer_b, :M, 21})

      :tracer.add_tracee_glob({ppid_server_a, :P, 10})
      :tracer.add_tracee_glob({ppid_server_b, :P, 11})
      # :tracer.add_tracee_glob({ppid_producer, :P, 0})
      :tracer.add_tracee_glob({ppid_consumer_a, :P, 20})
      :tracer.add_tracee_glob({ppid_consumer_b, :P, 21})

      bin_req = Proto.encode(42)

      try do
        {:ok, _res} = ServiceA.Api.compute(id)
        assert false, "ServiceA.Api.compute(#{id}) call should have deadlocked"
      catch
        :throw, {:deadlock, _} -> :ok
      end

      assert_receive(
        {:DOWN, ^ref_server_a, :process, ^pid_server_a,
         {:timeout,
          {:gen_statem, :call,
           [^pid_server_a,
            {{^bin_req, _}, _},
            5000]}}},
        10000
      )

      refute Process.alive?(pid_server_a)
      assert Process.alive?(pid_consumer_a)

      assert_receive(
        {:DOWN, ^ref_server_b, :process, ^pid_server_b,
         {:timeout,
          {:gen_statem, :call,
           [^pid_server_b,
            {{^bin_req, _}, _},
            5000]}}},
        100
      )

      refute Process.alive?(pid_server_b)
      assert Process.alive?(pid_consumer_b)

      assert Process.alive?(pid_producer)
    end
  end
end
