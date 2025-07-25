defmodule Immortal.Ghost do
  @moduledoc """
  A process that persists temporarily after an original process dies.

  ## Rationale

  Suppose you need to track users' online status. You have one process
  per user per connection, and automatically kill the process if the user
  disconnects.

  This strategy is good as far as it goes, but it assumes that the user is
  offline the instant that they drop their connection. This may not be
  accurate. Users can drop their connection for many reasons, such as by
  driving through an area with poor cell reception or opening another app on
  their mobile device, causing the app to go to the background and drop
  connections.

  In these cases, it is often better to assume a user is offline if they
  drop their connection _and_ do not reconnect after a period of time.
  This is what Ghost processes are for.

  Instead of tying a user's status to a process that dies immediately on
  disconnects, you should instead tie the status to a ghost: a process that
  will remain alive for a period of time after the connection process dies.
  This way, the user will be considered offline only after all their
  connections _and_ their ghosts are dead.

  ## Example

  Create a ghost when your connection process starts and use it to interface
  with whatever presence tracking system you are using. This example uses
  `Phoenix.Presence`, and the ghost will stay alive for 60 seconds after the
  connection process dies.

      # self() refers to the calling process here
      {:ok, ghost} = Ghost.start(self(), 60_000, fn ->
        # self() refers to the ghost here
        Presence.track(self(), topic, user_id, %{status: "online"})
      end)

  Since the presence tracker will be watching the ghost, not the connection,
  it will only consider the user offline 60 seconds after the connection
  drops. If the user reconnects during this time, a new connection and new
  ghost will start, causing the user to continue to appear online.

  Save the ghost's `pid` in the connection process so that you can update
  statuses later when users change it manually:

      Ghost.update(ghost, fn _state ->
        Presence.update(self(), topic, user_id, %{status: "busy"})
      end)
  """

  use GenServer

  @typedoc """
  A pid referencing an active Ghost.
  """
  @type t :: pid

  @typedoc """
  A pid referencing the process the ghost should watch before dying.
  """
  @type target_pid :: pid

  @typedoc """
  The number of milliseconds a Ghost should remain active after its
  target process dies.
  """
  @type milliseconds :: integer

  @doc """
  Starts a Ghost process, monitoring the given `pid`.

  The timeout determines how long the Ghost will remain alive after the
  `pid` process dies, in milliseconds.

  The optional function determines the internal state that the Ghost process
  will hold. You can use and modify this state using `update/2`.

  ## Examples

  Ghosts remain alive after the target process dies.

      iex> {:ok, target} = Agent.start(fn -> nil end)
      ...> {:ok, ghost} = Ghost.start(target, 1000)
      ...> Process.exit(target, :kill)
      ...> Process.alive?(ghost)
      true

  But they fade after the given timeout:

      iex> {:ok, target} = Agent.start(fn -> nil end)
      ...> {:ok, ghost} = Ghost.start(target, 100)
      ...> Process.exit(target, :kill)
      ...> :timer.sleep(200)
      ...> Process.alive?(ghost)
      false
  """
  @spec start(target_pid, milliseconds, fun, Keyword.t()) :: {:ok, t}
  def start(pid, timeout, fun \\ fn -> nil end)
      when is_pid(pid) and is_integer(timeout) and is_function(fun) do
    GenServer.start(__MODULE__, [pid, timeout, fun])
  end

  def start(pid, timeout, fun, opts)
      when is_pid(pid) and is_integer(timeout) and is_function(fun) do
    GenServer.start(__MODULE__, [pid, timeout, fun], opts)
  end

  @doc """
  Updates the internal state of the ghost using a function.
  The return value of the function becomes the new state.

  ## Example

      iex> {:ok, ghost} = Ghost.start(self(), 100, fn -> "hello" end)
      ...> Ghost.update(ghost, fn word -> word <> " world" end)
      {:ok, "hello world"}
  """
  @spec update(t, fun) :: {:ok, any}
  def update(ghost, fun) when is_pid(ghost) and is_function(fun) do
    GenServer.call(ghost, {:update, fun})
  end

  @doc """
  Change ghost's target process

  ## Example
      iex> {:ok, target} = Agent.start(fn -> nil end)
      ...> {:ok, ghost} = Ghost.start(target, 100)
      ...> Process.exit(target, :kill)
      ...> {:ok, new_target} = Agent.start(fn -> nil end)
      ...> {:ok, _} = ghost |> Ghost.change_target(new_target)
      ...> :timer.sleep(200)
      ...> Process.alive?(ghost)
      true
      ...> Process.exit(new_target, :kill)
      ...> :timer.sleep(200)
      ...> Process.alive?(ghost)
      false
  """
  @spec change_target(t, pid()) :: {:ok, any}
  def change_target(ghost, pid, fun \\ fn -> nil end)
      when is_pid(ghost) and is_pid(pid) and is_function(fun) do
    GenServer.call(ghost, {:change_target, pid, fun})
  end

  @doc """
  Handle down
  """
  def handle_down(ghost, mfa) do
    GenServer.call(ghost, {:handle_down, mfa})
  end

  @doc """
  Handle stop
  """
  def handle_stop(ghost, mfa) do
    GenServer.call(ghost, {:handle_stop, mfa})
  end

  @doc false
  def init([source, timeout, fun]) do
    monitor_ref = Process.monitor(source)

    {:ok,
     %{
       timeout: timeout,
       source: source,
       value: fun.(),
       monitor_ref: monitor_ref,
       kill_after_ref: nil,
       handle_down: nil,
       handle_stop: nil
     }}
  end

  @doc false
  def handle_call({:change_target, pid, fun}, _from, state) do
    state.monitor_ref
    |> Process.demonitor()

    if state.kill_after_ref !== nil do
      state.kill_after_ref
      |> Process.cancel_timer()
    end

    monitor_ref =
      pid
      |> Process.monitor()

    value = fun.()

    {:reply, {:ok, value}, %{state | kill_after_ref: nil, monitor_ref: monitor_ref, value: value, source: pid}}
  end

  @doc false
  def handle_call({:update, fun}, _from, state) do
    value = fun.(state.value)
    {:reply, {:ok, value}, %{state | value: value}}
  end

  @doc false
  def handle_call({:handle_down, mfa}, _from, state) do
    {:reply, :ok, %{state | handle_down: mfa}}
  end

  @doc false
  def handle_call({:handle_stop, mfa}, _from, state) do
    {:reply, :ok, %{state | handle_stop: mfa}}
  end

  @doc false
  def handle_info(:stop, state) do
    if state.handle_stop !== nil do
      {m, f, a} = state.handle_stop
      apply(m, f, a)
    end

    {:stop, :normal, state}
  end

  @doc false
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    kill_after_ref = Process.send_after(self(), :stop, state.timeout)

    if state.handle_down !== nil do
      {m, f, a} = state.handle_down
      apply(m, f, a)
    end

    {:noreply, %{state | kill_after_ref: kill_after_ref}}
  end

  @doc false
  def handle_info(_, state) do
    {:noreply, state}
  end
end
