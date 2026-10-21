Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)

{:ok, _} = Task.Supervisor.start_link(name: WardrikCore.TaskSupervisor)

ExUnit.start()
