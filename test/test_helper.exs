Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

{:ok, _} =
  Supervisor.start_link(
    [
      {WardrikCore.Backends.MemoryStore, name: :wardrik_core_test},
      {WardrikCore,
       prefix: "test/", backend: {WardrikCore.Backends.MemoryStore, name: :wardrik_core_test}}
    ],
    strategy: :rest_for_one
  )

ExUnit.start()
