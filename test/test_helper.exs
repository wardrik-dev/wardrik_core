Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

store = Path.join(System.tmp_dir!(), "wardrik_core_test_#{System.unique_integer([:positive])}")

{:ok, _} =
  Supervisor.start_link(
    [
      {EKV, name: :wardrik_core_test, data_dir: store, cluster_size: 1},
      {WardrikCore,
       prefix: "test/", backend: {DurableServer.Backends.EKVStore, name: :wardrik_core_test}}
    ],
    strategy: :rest_for_one
  )

ExUnit.after_suite(fn _results -> File.rm_rf(store) end)
ExUnit.start()
