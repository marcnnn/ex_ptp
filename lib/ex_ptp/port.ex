defmodule ExPtp.Port do
  @moduledoc """
  An ordinary clock with one port (IEEE 1588-2019, delay request-response
  mechanism) as a GenServer over a pluggable `ExPtp.Transport`.

  The port runs the state machine (`ExPtp.PortState`) with announce receipt
  timeout and qualification timeout, qualifies foreign masters
  (`ExPtp.ForeignMasters`), runs the BMCA (`ExPtp.BMCA`) on every Announce and
  every announce interval, and acts as
  master (Announce, Sync/Follow_Up, Delay_Resp) or slave (offset and mean
  path delay from `ExPtp.Delay`, PI servo from `ExPtp.Servo` steering the
  transport's clock, lock detection).

  With `delay_mechanism: :p2p` in the port data set (`port_ds: [delay_mechanism: :p2p]`)
  the port runs the peer delay mechanism instead (clause 11.4, two-step responder): it
  sends Pdelay_Req every `log_min_pdelay_req_interval` in every active state, answers
  Pdelay_Req with Pdelay_Resp (`t2`) and Pdelay_Resp_Follow_Up (`t3`), and a slave uses
  the measured peer delay as its mean path delay and sends no Delay_Req. There is no
  transparent clock, so peer and end to end delay are the same on a direct link.

  The slave goes UNCALIBRATED -> SLAVE when the servo reports lock, and back
  to UNCALIBRATED when it loses it.

  Options: `:transport` (`{module, handle}`), `:clock_identity` (8 bytes),
  `:port_number` (1), `:profile` (`ExPtp.Profile`, default `:default`),
  `:priority1`, `:priority2`, `:clock_class`, `:clock_accuracy`,
  `:domain_number`, `:slave_only`, `:two_step` (true), `:servo` (`:float` or
  `:fixed`), `:step_threshold_ns` (offsets above it step the clock, default
  100_000), `:lock_threshold_ns` (500), `:lock_count` (5), `:mpd_shift`
  (mean path delay filter 2^-n, default 2), `:time_properties`
  (`ExPtp.DataSets.TimeProperties`), `:port_ds` (overrides, e.g.
  `log_sync_interval: -3`), `:name`.

  Subscribers (`subscribe/1`) get `{:ex_ptp, pid, {:state, new, old}}`,
  `{:ex_ptp, pid, {:offset, offset_ns, mean_path_delay_ns}}` and
  `{:ex_ptp, pid, {:servo, ppb}}`.

      {:ok, port} =
        ExPtp.Port.start_link(
          transport: transport,
          clock_identity: <<0, 1, 2, 255, 254, 3, 4, 5>>,
          profile: :aes67,
          clock_class: 248
        )

      ExPtp.Port.info(port).state
  """
  use GenServer

  alias ExPtp.{
    BMCA,
    Correction,
    Delay,
    ForeignMasters,
    Message,
    PortState,
    Profile,
    Servo,
    Timestamp,
    Transport
  }

  alias ExPtp.DataSets.{Current, Default, Parent, TimeProperties}
  alias ExPtp.DataSets.Port, as: PortDS
  alias ExPtp.Servo.{FixedPI, Lock, PI}

  @undefined_interval 0x7F

  defstruct [
    :transport,
    :default_ds,
    :port_ds,
    :current_ds,
    :parent_ds,
    :time_properties,
    :foreign,
    :servo,
    :servo_kind,
    :lock,
    :opts,
    :last_sync,
    :pending_sync,
    :pending_dreq,
    :pending_pdelay,
    :mpd,
    :offset,
    :freq_ppb,
    timers: %{},
    next_gen: 0,
    seq: %{},
    subscribers: [],
    stats: %{rx: %{}, tx: %{}, dropped: 0}
  ]

  # -- API ------------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Current port state."
  def state(port), do: GenServer.call(port, :state)

  @doc """
  Snapshot: `:state`, `:offset_ns`, `:mean_path_delay_ns`, `:locked`,
  `:freq_ppb`, `:parent`, `:grandmaster`, `:steps_removed`, `:stats` and the
  data sets.
  """
  def info(port), do: GenServer.call(port, :info)

  @doc "Subscribes the caller to events."
  def subscribe(port), do: GenServer.call(port, {:subscribe, self()})

  @doc "Injects a state machine event, e.g. `:fault_detected`, `:fault_cleared`, `:designated_disabled`."
  def event(port, event), do: GenServer.call(port, {:event, event})

  # -- GenServer ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {mod, handle} = Keyword.fetch!(opts, :transport)
    profile = Keyword.get(opts, :profile, :default)
    cid = Keyword.fetch!(opts, :clock_identity)

    default_ds =
      Default.new(
        cid,
        [profile: profile] ++
          Keyword.take(opts, [
            :priority1,
            :priority2,
            :clock_class,
            :clock_accuracy,
            :domain_number,
            :slave_only,
            :two_step
          ])
      )

    port_ds =
      PortDS.new(
        cid,
        Keyword.get(opts, :port_number, 1),
        profile,
        Keyword.get(opts, :port_ds, [])
      )

    s = %__MODULE__{
      transport: {mod, handle},
      default_ds: default_ds,
      port_ds: port_ds,
      current_ds: %Current{},
      parent_ds: Parent.from_default(default_ds),
      time_properties: Keyword.get(opts, :time_properties, %TimeProperties{}),
      opts: opts,
      servo_kind: Keyword.get(opts, :servo, :float)
    }

    mod.attach(handle, self())
    {:ok, reset_foreign(s), {:continue, :initialized}}
  end

  @impl true
  def handle_continue(:initialized, s), do: {:noreply, fire(s, :initialized)}

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.port_ds.port_state, s}

  def handle_call({:subscribe, pid}, _from, s),
    do: {:reply, :ok, %{s | subscribers: [pid | s.subscribers]}}

  def handle_call({:event, ev}, _from, s), do: {:reply, :ok, fire(s, ev)}
  def handle_call(:info, _from, s), do: {:reply, info_map(s), s}

  @impl true
  def handle_info({:ptp_rx, _channel, bin, rx}, s) do
    case Message.decode(bin) do
      {:ok, msg} -> {:noreply, receive_msg(count(s, :rx, msg.type), msg, rx)}
      {:error, _} -> {:noreply, drop(s)}
    end
  end

  def handle_info({:ptp_timer, {name, gen}}, s) do
    if s.timers[name] == gen,
      do: {:noreply, timer(%{s | timers: Map.delete(s.timers, name)}, name)},
      else: {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp info_map(s) do
    %{
      state: s.port_ds.port_state,
      offset_ns: s.offset && Correction.to_ns(s.offset),
      mean_path_delay_ns: s.mpd && Correction.to_ns(s.mpd),
      locked: s.lock != nil and s.lock.locked,
      freq_ppb: s.freq_ppb,
      parent: s.parent_ds.parent_port_identity,
      grandmaster: s.parent_ds.grandmaster_identity,
      steps_removed: s.current_ds.steps_removed,
      stats: s.stats,
      default_ds: s.default_ds,
      port_ds: s.port_ds,
      current_ds: s.current_ds,
      parent_ds: s.parent_ds,
      time_properties: s.time_properties
    }
  end

  # -- state machine --------------------------------------------------------------------------

  defp fire(s, event) do
    old = s.port_ds.port_state
    new = PortState.next(old, event, s.default_ds.slave_only)
    if new == old, do: s, else: transition(s, old, new)
  end

  defp transition(s, old, new) do
    s = %{s | port_ds: %{s.port_ds | port_state: new}, timers: %{}}
    notify(s, {:state, new, old})
    s |> enter(old, new) |> arm_pdelay()
  end

  defp p2p?(s), do: s.port_ds.delay_mechanism == :p2p

  defp arm_pdelay(%{port_ds: %{port_state: st}} = s)
       when st in [:initializing, :faulty, :disabled],
       do: s

  defp arm_pdelay(s) do
    if p2p?(s) and not Map.has_key?(s.timers, :pdelay_tx),
      do: arm(s, :pdelay_tx, 1_000_000),
      else: s
  end

  defp enter(s, _old, :initializing), do: fire(reset_foreign(s), :initialized)

  defp enter(s, _old, :listening),
    do: s |> reset_slave() |> arm_announce_timeout() |> arm(:bmca, announce_ns(s))

  defp enter(s, _old, :pre_master),
    do:
      s
      |> arm(:qualification, (s.current_ds.steps_removed + 1) * announce_ns(s))
      |> arm(:bmca, announce_ns(s))

  defp enter(s, _old, :master) do
    s
    |> reset_slave()
    |> send_announce()
    |> arm(:announce_tx, announce_ns(s))
    |> arm(:sync_tx, sync_ns(s))
    |> arm(:bmca, announce_ns(s))
  end

  defp enter(s, _old, :passive),
    do: s |> reset_slave() |> arm_announce_timeout() |> arm(:bmca, announce_ns(s))

  defp enter(s, old, new) when new in [:uncalibrated, :slave] do
    s = if old in [:uncalibrated, :slave], do: s, else: reset_slave(s)
    s |> arm_announce_timeout() |> arm(:delay_req_tx, 1_000_000) |> arm(:bmca, announce_ns(s))
  end

  defp enter(s, _old, _), do: s

  defp reset_slave(s) do
    %{
      s
      | last_sync: nil,
        pending_sync: nil,
        pending_dreq: nil,
        offset: nil,
        servo: nil,
        lock: nil
    }
  end

  defp reset_foreign(s) do
    window = 4 * announce_ns(s)
    fid = s.default_ds.clock_identity
    %{s | foreign: ForeignMasters.new(fid, s.port_ds.port_identity, window)}
  end

  defp announce_ns(s), do: Profile.interval_ns(s.port_ds.log_announce_interval)
  defp sync_ns(s), do: Profile.interval_ns(s.port_ds.log_sync_interval)
  defp pdelay_ns(s), do: Profile.interval_ns(s.port_ds.log_min_pdelay_req_interval)
  defp dreq_ns(s), do: Profile.interval_ns(s.port_ds.log_min_delay_req_interval)

  defp arm_announce_timeout(s),
    do: arm(s, :announce_timeout, s.port_ds.announce_receipt_timeout * announce_ns(s))

  defp arm(s, name, delay_ns) do
    {mod, handle} = s.transport
    gen = s.next_gen
    mod.schedule(handle, delay_ns, {name, gen})
    %{s | timers: Map.put(s.timers, name, gen), next_gen: gen + 1}
  end

  defp timer(s, :announce_tx), do: s |> send_announce() |> arm(:announce_tx, announce_ns(s))
  defp timer(s, :sync_tx), do: s |> send_sync() |> arm(:sync_tx, sync_ns(s))
  defp timer(s, :delay_req_tx), do: s |> send_delay_req() |> arm(:delay_req_tx, dreq_ns(s))
  defp timer(s, :pdelay_tx), do: s |> send_pdelay_req() |> arm(:pdelay_tx, pdelay_ns(s))
  defp timer(s, :qualification), do: fire(s, :qualification_timeout)

  defp timer(s, :announce_timeout) do
    s = %{s | foreign: ForeignMasters.clear(s.foreign)}
    new = PortState.next(s.port_ds.port_state, :announce_receipt_timeout, s.default_ds.slave_only)
    s = if new == :master, do: set_master_datasets(s), else: s
    fire(s, :announce_receipt_timeout)
  end

  defp timer(s, :bmca), do: s |> run_bmca() |> arm_bmca()

  defp arm_bmca(%{port_ds: %{port_state: st}} = s) when st in [:initializing, :faulty, :disabled],
    do: s

  defp arm_bmca(s), do: arm(s, :bmca, announce_ns(s))

  # -- BMCA -----------------------------------------------------------------------------------

  defp run_bmca(s) do
    state = s.port_ds.port_state

    if state in [:initializing, :faulty, :disabled] do
      s
    else
      now = Timestamp.to_ns(local_now(s))
      foreign = ForeignMasters.expire(s.foreign, now)
      erbest = ForeignMasters.best(foreign, now)
      d0 = BMCA.from_default(s.default_ds, elem(s.port_ds.port_identity, 1))
      decision = BMCA.state_decision(d0, erbest, state, s.default_ds.slave_only)
      apply_decision(%{s | foreign: foreign}, decision, erbest)
    end
  end

  defp apply_decision(s, :listening, _), do: s

  defp apply_decision(s, d, _) when d in [:m1, :m2],
    do: s |> set_master_datasets() |> fire(:rs_master)

  defp apply_decision(s, d, _) when d in [:p1, :p2], do: fire(s, :rs_passive)

  defp apply_decision(s, :s1, erbest) do
    new_master = s.parent_ds.parent_port_identity != erbest.sender
    state = s.port_ds.port_state
    s = set_slave_datasets(s, erbest)

    cond do
      state in [:uncalibrated, :slave] and new_master ->
        s |> reset_slave() |> fire(:rs_slave_new_master)

      true ->
        fire(s, :rs_slave)
    end
  end

  defp set_master_datasets(s) do
    %{
      s
      | parent_ds: Parent.from_default(s.default_ds),
        current_ds: %Current{},
        time_properties: Keyword.get(s.opts, :time_properties, %TimeProperties{})
    }
  end

  defp set_slave_datasets(s, %{announce: %{body: b} = msg, sender: sender} = d) do
    %{
      s
      | parent_ds: %{
          s.parent_ds
          | parent_port_identity: sender,
            grandmaster_identity: d.grandmaster_identity,
            grandmaster_clock_quality: %{
              clock_class: d.clock_class,
              clock_accuracy: d.clock_accuracy,
              offset_scaled_log_variance: d.offset_scaled_log_variance
            },
            grandmaster_priority1: d.priority1,
            grandmaster_priority2: d.priority2
        },
        current_ds: %{s.current_ds | steps_removed: b.steps_removed + 1},
        time_properties: TimeProperties.from_announce(msg)
    }
  end

  # -- receive ----------------------------------------------------------------------------------

  defp receive_msg(s, %Message{domain: d}, _) when d != s.default_ds.domain_number, do: drop(s)

  defp receive_msg(s, %Message{source: {cid, _}}, _) when cid == s.default_ds.clock_identity,
    do: drop(s)

  defp receive_msg(%{port_ds: %{port_state: st}} = s, _, _)
       when st in [:initializing, :faulty, :disabled],
       do: s

  defp receive_msg(s, %Message{type: :announce} = m, rx) do
    now = Timestamp.to_ns(rx || local_now(s))
    s = %{s | foreign: ForeignMasters.add(s.foreign, m, now)}
    state = s.port_ds.port_state

    s =
      cond do
        state == :listening ->
          arm_announce_timeout(s)

        state in [:uncalibrated, :slave] and m.source == s.parent_ds.parent_port_identity ->
          arm_announce_timeout(s)

        state == :passive ->
          arm_announce_timeout(s)

        true ->
          s
      end

    run_bmca(s)
  end

  defp receive_msg(s, %Message{type: :pdelay_req} = m, rx), do: send_pdelay_resp(s, m, rx)
  defp receive_msg(s, %Message{type: :pdelay_resp} = m, rx), do: on_pdelay_resp(s, m, rx)

  defp receive_msg(s, %Message{type: :pdelay_resp_follow_up} = m, _),
    do: on_pdelay_follow_up(s, m)

  defp receive_msg(%{port_ds: %{port_state: :master}} = s, %Message{type: :delay_req} = m, rx),
    do: send_delay_resp(s, m, rx)

  defp receive_msg(%{port_ds: %{port_state: st}} = s, %Message{type: :sync} = m, rx)
       when st in [:uncalibrated, :slave] do
    if m.source == s.parent_ds.parent_port_identity, do: on_sync(s, m, rx), else: s
  end

  defp receive_msg(%{port_ds: %{port_state: st}} = s, %Message{type: :follow_up} = m, _)
       when st in [:uncalibrated, :slave] do
    case s.pending_sync do
      {seq, t2, c} when seq == m.sequence_id and m.source == s.parent_ds.parent_port_identity ->
        measure(%{s | pending_sync: nil}, m.body.precise_origin_timestamp, t2, c + m.correction)

      _ ->
        s
    end
  end

  defp receive_msg(%{port_ds: %{port_state: st}} = s, %Message{type: :delay_resp} = m, _)
       when st in [:uncalibrated, :slave],
       do: on_delay_resp(s, m)

  defp receive_msg(s, _, _), do: s

  defp on_sync(s, m, rx) do
    s = follow_sync_interval(s, m)

    if Message.flag?(m, :two_step),
      do: %{s | pending_sync: {m.sequence_id, rx, m.correction}},
      else: measure(s, m.body.origin_timestamp, rx, m.correction)
  end

  defp follow_sync_interval(s, %{log_interval: l}) when l == @undefined_interval, do: s

  defp follow_sync_interval(s, %{log_interval: l}) do
    if l == s.port_ds.log_sync_interval,
      do: s,
      else: %{s | port_ds: %{s.port_ds | log_sync_interval: l}, servo: nil}
  end

  # A complete Sync: remember the pair for the next delay measurement, and servo.
  defp measure(s, t1, t2, c) do
    s = %{s | last_sync: {t1, t2, c}}

    cond do
      s.mpd == nil and p2p?(s) -> s
      s.mpd == nil and s.pending_dreq == nil -> send_delay_req(s)
      s.mpd == nil -> s
      true -> servo(s, t1, t2, c)
    end
  end

  defp servo(s, t1, t2, c) do
    offset = Delay.offset_from_master(t1, t2, c, s.mpd)
    off_ns = Correction.to_ns(offset)

    s = %{
      s
      | offset: offset,
        current_ds: %{s.current_ds | offset_from_master: offset, mean_path_delay: s.mpd}
    }

    notify(s, {:offset, off_ns, Correction.to_ns(s.mpd)})

    if abs(off_ns) > Keyword.get(s.opts, :step_threshold_ns, 100_000) do
      {mod, handle} = s.transport
      mod.step_clock(handle, -round(off_ns))
      s = %{s | servo: nil, lock: nil, last_sync: nil}
      fire(s, :synchronization_fault)
    else
      s = ensure_servo(s)
      {ppb, kind} = servo_step(s.servo, offset)
      {mod, handle} = s.transport
      mod.adjust_frequency(handle, ppb)
      notify(s, {:servo, ppb})
      lock = Lock.update(s.lock, off_ns)
      s = %{s | servo: kind, freq_ppb: ppb, lock: lock}

      cond do
        lock.locked and s.port_ds.port_state == :uncalibrated -> fire(s, :master_clock_selected)
        not lock.locked and s.port_ds.port_state == :slave -> fire(s, :synchronization_fault)
        true -> s
      end
    end
  end

  defp ensure_servo(%{servo: nil} = s) do
    {kp, ki} = Servo.gains(s.port_ds.log_sync_interval)

    servo =
      case s.servo_kind do
        :fixed -> {:fixed, FixedPI.new(kp, ki)}
        :float -> {:float, PI.new(kp, ki)}
      end

    lock =
      s.lock ||
        Lock.new(
          Keyword.get(s.opts, :lock_threshold_ns, 500),
          Keyword.get(s.opts, :lock_count, 5)
        )

    %{s | servo: servo, lock: lock}
  end

  defp ensure_servo(%{lock: nil} = s), do: ensure_servo(%{s | servo: nil})
  defp ensure_servo(s), do: s

  defp servo_step({:float, pi}, offset) do
    {ppb, pi} = PI.step(pi, Correction.to_ns(offset))
    {ppb, {:float, pi}}
  end

  defp servo_step({:fixed, f}, offset) do
    {raw, f} = FixedPI.step(f, FixedPI.err_from_scaled(offset))
    {FixedPI.ppb(raw), {:fixed, f}}
  end

  defp on_delay_resp(s, %{body: b, sequence_id: seq} = m) do
    me = s.port_ds.port_identity

    case s.pending_dreq do
      {^seq, t3, {t1, t2, c}} when b.requesting_port == me ->
        sample = Delay.e2e_mean_path_delay(t1, t2, t3, b.receive_timestamp, c, m.correction)
        s = %{s | pending_dreq: nil}

        s =
          if m.log_interval != @undefined_interval,
            do: follow_dreq_interval(s, m.log_interval),
            else: s

        if sample < 0,
          do: s,
          else: %{
            s
            | mpd: filter_mpd(s, sample),
              port_ds: %{s.port_ds | peer_mean_path_delay: sample}
          }

      _ ->
        s
    end
  end

  defp on_pdelay_resp(s, %{body: b, sequence_id: seq} = m, t4) do
    case s.pending_pdelay do
      {^seq, t1} when b.requesting_port == s.port_ds.port_identity ->
        %{s | pending_pdelay: {seq, t1, b.request_receipt_timestamp, t4, m.correction, m.source}}

      _ ->
        s
    end
  end

  defp on_pdelay_follow_up(s, %{body: b, sequence_id: seq} = m) do
    case s.pending_pdelay do
      {^seq, t1, t2, t4, c, src}
      when src == m.source and b.requesting_port == s.port_ds.port_identity ->
        sample =
          Delay.p2p_mean_path_delay(t1, t2, b.response_origin_timestamp, t4, c, m.correction)

        s = %{s | pending_pdelay: nil}

        if sample < 0,
          do: s,
          else: %{
            s
            | mpd: filter_mpd(s, sample),
              port_ds: %{s.port_ds | peer_mean_path_delay: sample}
          }

      _ ->
        s
    end
  end

  defp follow_dreq_interval(s, l),
    do: %{s | port_ds: %{s.port_ds | log_min_delay_req_interval: l}}

  defp filter_mpd(%{mpd: nil}, sample), do: sample

  defp filter_mpd(s, sample),
    do: s.mpd + Bitwise.bsr(sample - s.mpd, Keyword.get(s.opts, :mpd_shift, 2))

  # -- transmit -------------------------------------------------------------------------------

  defp local_now(s) do
    {mod, handle} = s.transport
    mod.now(handle)
  end

  defp next_seq(s, type) do
    n = Map.get(s.seq, type, 0)
    {n, %{s | seq: Map.put(s.seq, type, Bitwise.band(n + 1, 0xFFFF))}}
  end

  defp base(s, type, seq, body, opts \\ []) do
    Message.new(
      type,
      s.port_ds.port_identity,
      seq,
      body,
      [domain: s.default_ds.domain_number] ++ opts
    )
  end

  defp transmit(s, %Message{type: type} = m, opts \\ []) do
    {mod, handle} = s.transport
    {:ok, ts} = mod.send_msg(handle, Transport.channel(type), Message.encode(m), opts)
    {ts, count(s, :tx, type)}
  end

  defp send_announce(s) do
    {seq, s} = next_seq(s, :announce)
    p = s.parent_ds
    tp = s.time_properties
    q = p.grandmaster_clock_quality

    body = %{
      origin_timestamp: %Timestamp{},
      current_utc_offset: tp.current_utc_offset,
      priority1: p.grandmaster_priority1,
      clock_class: q.clock_class,
      clock_accuracy: q.clock_accuracy,
      offset_scaled_log_variance: q.offset_scaled_log_variance,
      priority2: p.grandmaster_priority2,
      grandmaster_identity: p.grandmaster_identity,
      steps_removed: s.current_ds.steps_removed,
      time_source: tp.time_source
    }

    m =
      base(s, :announce, seq, body,
        flags: Message.flags(TimeProperties.flag_names(tp)),
        log_interval: s.port_ds.log_announce_interval
      )

    {_, s} = transmit(s, m)
    s
  end

  defp send_sync(s) do
    {seq, s} = next_seq(s, :sync)
    two_step = s.default_ds.two_step
    flags = if two_step, do: Message.flags([:two_step]), else: 0

    m =
      base(s, :sync, seq, %{origin_timestamp: %Timestamp{}},
        flags: flags,
        log_interval: s.port_ds.log_sync_interval
      )

    if two_step do
      {t, s} = transmit(s, m)

      fu =
        base(s, :follow_up, seq, %{precise_origin_timestamp: t},
          log_interval: s.port_ds.log_sync_interval
        )

      {_, s} = transmit(s, fu)
      s
    else
      {_, s} = transmit(s, m, one_step: true)
      s
    end
  end

  defp send_delay_req(s) do
    if s.last_sync == nil or p2p?(s) do
      s
    else
      {seq, s} = next_seq(s, :delay_req)
      m = base(s, :delay_req, seq, %{origin_timestamp: %Timestamp{}})
      {t3, s} = transmit(s, m)
      %{s | pending_dreq: {seq, t3, s.last_sync}}
    end
  end

  defp send_delay_resp(s, req, rx) do
    m =
      base(s, :delay_resp, req.sequence_id, %{receive_timestamp: rx, requesting_port: req.source},
        correction: req.correction,
        log_interval: s.port_ds.log_min_delay_req_interval
      )

    {_, s} = transmit(s, m)
    s
  end

  defp send_pdelay_req(s) do
    {seq, s} = next_seq(s, :pdelay_req)

    m =
      base(s, :pdelay_req, seq, %{origin_timestamp: %Timestamp{}},
        log_interval: s.port_ds.log_min_pdelay_req_interval
      )

    {t1, s} = transmit(s, m)
    %{s | pending_pdelay: {seq, t1}}
  end

  # Two-step responder: t2 in the Pdelay_Resp, t3 in the follow up.
  defp send_pdelay_resp(s, req, t2) do
    resp =
      base(
        s,
        :pdelay_resp,
        req.sequence_id,
        %{request_receipt_timestamp: t2, requesting_port: req.source},
        flags: Message.flags([:two_step]),
        log_interval: @undefined_interval
      )

    {t3, s} = transmit(s, resp)

    fu =
      base(
        s,
        :pdelay_resp_follow_up,
        req.sequence_id,
        %{response_origin_timestamp: t3, requesting_port: req.source},
        correction: req.correction,
        log_interval: @undefined_interval
      )

    {_, s} = transmit(s, fu)
    s
  end

  # -- bookkeeping --------------------------------------------------------------------------------

  defp count(s, dir, type),
    do: %{s | stats: Map.update!(s.stats, dir, &Map.update(&1, type, 1, fn n -> n + 1 end))}

  defp drop(s), do: %{s | stats: %{s.stats | dropped: s.stats.dropped + 1}}

  defp notify(s, event), do: Enum.each(s.subscribers, &send(&1, {:ex_ptp, self(), event}))
end
