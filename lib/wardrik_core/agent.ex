defmodule WardrikCore.Agent do
  @moduledoc """
  A Durable Agent Process.
  """
  require Logger
  use DurableServer, vsn: 1

  # alias WardrikCore.Agent.State

  def initial_state(state_opts) do
    state_opts
  end

  @impl DurableServer
  def dump_state(state) do
    Logger.info("Dumping state for agent #{state.agent_id}: #{inspect(state)}")
    state
  end

  @impl DurableServer
  def load_state(_vsn, state) do
    Logger.info("Loading state for agent #{state.agent_id}: #{inspect(state)}")
    state
  end

  @impl DurableServer
  def init(state) do
    Logger.info("Initializing agent #{state.agent_id} with state: #{inspect(state)}")
    {:ok, state}
  end

  # @impl true
  # def handle_cast({:ask, _message}, %{llm_client: client} = state) do
  #   with {:ok, streamed} <- client.stream_text(state.model, state.context),
  #        {:ok, processed} <-
  #          client.process_stream(streamed,
  #            on_result: fn -> nil end,
  #            on_thinking: fn -> nil end,
  #            on_tool_call: fn -> nil end
  #          ) do
  #     Logger.info("Streaming response: #{inspect(processed)}")
  #   else
  #     {:error, reason} ->
  #       Logger.error("Error streaming response: #{inspect(reason)}")
  #   end
  #
  #   {:noreply, state}
  # end
end
