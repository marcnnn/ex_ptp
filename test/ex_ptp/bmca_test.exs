defmodule ExPtp.BMCATest do
  use ExUnit.Case, async: true

  alias ExPtp.{BMCA, DataSets.Default, ForeignMasters, Message, PortState, Timestamp}

  doctest ExPtp.BMCA
  doctest ExPtp.ForeignMasters
  doctest ExPtp.PortState
  doctest ExPtp.Profile
  doctest ExPtp.DataSets

  defp id(n), do: <<n::64>>

  defp ds(over \\ []) do
    base = %{
      priority1: 128,
      clock_class: 248,
      clock_accuracy: 0xFE,
      offset_scaled_log_variance: 0xFFFF,
      priority2: 128,
      grandmaster_identity: id(10),
      steps_removed: 1,
      sender: {id(10), 1},
      receiver: {id(1), 1}
    }

    Map.merge(base, Map.new(over))
  end

  describe "dataset comparison part 1" do
    test "each field decides in order, lower wins" do
      worse = ds(grandmaster_identity: id(11), sender: {id(11), 1})

      for {field, better} <- [
            priority1: 100,
            clock_class: 6,
            clock_accuracy: 0x20,
            offset_scaled_log_variance: 0x4000,
            priority2: 100
          ] do
        a = Map.put(ds(), field, better)
        assert BMCA.compare(a, worse) == {:a, :dataset}, "#{field}"
        assert BMCA.compare(worse, a) == {:b, :dataset}, "#{field}"
      end
    end

    test "earlier fields dominate later ones" do
      a = ds(priority1: 100, clock_class: 255, grandmaster_identity: id(12))
      b = ds(priority1: 101, clock_class: 6, grandmaster_identity: id(11))
      assert BMCA.compare(a, b) == {:a, :dataset}
    end

    test "grandmaster identity breaks the tie" do
      a = ds(grandmaster_identity: id(9))
      b = ds(grandmaster_identity: id(10))
      assert BMCA.compare(a, b) == {:a, :dataset}
      assert BMCA.compare(b, a) == {:b, :dataset}
    end
  end

  describe "topology (part 2)" do
    test "fewer steps removed wins by more than one" do
      a = ds(steps_removed: 1)
      b = ds(steps_removed: 3, sender: {id(20), 1})
      assert BMCA.compare(a, b) == {:a, :dataset}
      assert BMCA.compare(b, a) == {:b, :dataset}
    end

    test "one step difference compares the longer path's receiver and sender" do
      a = ds(steps_removed: 3, sender: {id(20), 1}, receiver: {id(1), 1})
      b = ds(steps_removed: 2, sender: {id(21), 1}, receiver: {id(1), 2})
      # receiver < sender of the longer path (a): b is better
      assert BMCA.compare(a, b) == {:b, :dataset}
      assert BMCA.compare(b, a) == {:a, :dataset}
      # receiver > sender: better by topology
      a2 = %{a | receiver: {id(30), 1}}
      assert BMCA.compare(a2, b) == {:b, :topology}
      # receiver equal to sender: the message came from the port itself
      assert BMCA.compare(%{a | receiver: a.sender}, b) == :equal
    end

    test "equal steps: lower sender identity, then lower receiver port" do
      a = ds(sender: {id(20), 1}, receiver: {id(1), 1})
      b = ds(sender: {id(21), 1}, receiver: {id(1), 1})
      assert BMCA.compare(a, b) == {:a, :topology}
      assert BMCA.compare(b, a) == {:b, :topology}

      c = ds(sender: {id(20), 1}, receiver: {id(1), 2})
      assert BMCA.compare(a, c) == {:a, :topology}
      assert BMCA.compare(a, a) == :equal
    end

    test "same sender, different port number of the sender" do
      a = ds(sender: {id(20), 1})
      b = ds(sender: {id(20), 2})
      assert BMCA.compare(a, b) == {:a, :topology}
    end
  end

  describe "state decision" do
    defp own(opts), do: Default.new(id(1), opts) |> BMCA.from_default(1)

    test "no foreign master: stay listening, otherwise master" do
      assert BMCA.state_decision(own([]), nil, :listening, false) == :listening
      assert BMCA.state_decision(own([]), nil, :slave, false) == :m2
      assert BMCA.state_decision(own(clock_class: 6), nil, :uncalibrated, false) == :m1
    end

    test "grandmaster-capable clock (class <= 127): M1 if best, else passive" do
      foreign = ds(clock_class: 13)
      assert BMCA.state_decision(own(clock_class: 6), foreign, :listening, false) == :m1
      assert BMCA.state_decision(own(clock_class: 52), foreign, :listening, false) == :p1
    end

    test "class > 127: M2 if best, else slave" do
      assert BMCA.state_decision(own([]), ds(clock_class: 6), :listening, false) == :s1
      assert BMCA.state_decision(own([]), ds(clock_class: 255), :listening, false) == :m2
      assert BMCA.state_decision(own(priority1: 1), ds(clock_class: 6), :master, false) == :m2
    end

    test "priority1 overrides clock class" do
      assert BMCA.state_decision(own(priority1: 200, clock_class: 6), ds(), :listening, false) ==
               :p1
    end

    test "best/1 picks the best data set" do
      a = ds(grandmaster_identity: id(5), clock_class: 6)
      b = ds(grandmaster_identity: id(4), clock_class: 7)
      assert BMCA.best([b, a]) == a
      assert BMCA.best([]) == nil
    end
  end

  describe "foreign master qualification" do
    defp announce(cid, seq, over \\ %{}) do
      body =
        Map.merge(
          %{
            origin_timestamp: %Timestamp{},
            current_utc_offset: 37,
            priority1: 128,
            clock_class: 6,
            clock_accuracy: 0x21,
            offset_scaled_log_variance: 0x4E5D,
            priority2: 128,
            grandmaster_identity: cid,
            steps_removed: 0,
            time_source: 0x20
          },
          over
        )

      Message.new(:announce, {cid, 1}, seq, body)
    end

    @s 1_000_000_000

    setup do
      %{fm: ForeignMasters.new(id(1), {id(1), 1}, 4 * @s)}
    end

    test "needs two announces within the window", %{fm: fm} do
      fm = ForeignMasters.add(fm, announce(id(9), 1), 0)
      assert ForeignMasters.qualified(fm, 0) == []
      fm = ForeignMasters.add(fm, announce(id(9), 2), 3 * @s)
      assert [_] = ForeignMasters.qualified(fm, 3 * @s)
      # first one ages out of the window
      assert ForeignMasters.qualified(fm, 5 * @s) == []
    end

    test "two announces further apart than the window do not qualify", %{fm: fm} do
      fm =
        fm
        |> ForeignMasters.add(announce(id(9), 1), 0)
        |> ForeignMasters.add(announce(id(9), 2), 5 * @s)

      assert ForeignMasters.qualified(fm, 5 * @s) == []
    end

    test "own, steps >= 255 and alternate master announces are discarded", %{fm: fm} do
      fm =
        Enum.reduce(1..3, fm, fn i, fm ->
          fm
          |> ForeignMasters.add(announce(id(1), i), i)
          |> ForeignMasters.add(announce(id(8), i, %{steps_removed: 255}), i)
          |> ForeignMasters.add(
            %{announce(id(7), i) | flags: Message.flags([:alternate_master])},
            i
          )
        end)

      assert ForeignMasters.qualified(fm, 3) == []
    end

    test "best picks among qualified masters", %{fm: fm} do
      fm =
        for cid <- [id(9), id(8)], i <- 1..2, reduce: fm do
          fm ->
            class = if cid == id(8), do: 6, else: 13
            ForeignMasters.add(fm, announce(cid, i, %{clock_class: class}), i * @s)
        end

      assert %{grandmaster_identity: gm} = ForeignMasters.best(fm, 2 * @s)
      assert gm == id(8)
      assert ForeignMasters.clear(fm) |> ForeignMasters.best(2 * @s) == nil
    end
  end

  describe "port state machine" do
    alias PortState, as: S

    test "startup and slave path" do
      assert :initializing |> S.next(:initialized) == :listening
      assert S.next(:listening, :rs_slave) == :uncalibrated
      assert S.next(:uncalibrated, :master_clock_selected) == :slave
      assert S.next(:slave, :synchronization_fault) == :uncalibrated
    end

    test "master path with qualification" do
      assert S.next(:listening, :rs_master) == :pre_master
      assert S.next(:pre_master, :qualification_timeout) == :master
      assert S.next(:master, :rs_slave) == :uncalibrated
      assert S.next(:master, :rs_master) == :master
    end

    test "announce receipt timeout" do
      for st <- [:listening, :passive, :uncalibrated, :slave],
          do: assert(S.next(st, :announce_receipt_timeout) == :master)

      assert S.next(:master, :announce_receipt_timeout) == :master
      assert S.next(:pre_master, :announce_receipt_timeout) == :pre_master
    end

    test "passive and new master" do
      assert S.next(:master, :rs_passive) == :passive
      assert S.next(:passive, :rs_master) == :pre_master
      assert S.next(:slave, :rs_slave_new_master) == :uncalibrated
      assert S.next(:slave, :rs_slave) == :slave
    end

    test "fault and disable from any state" do
      for st <- [:listening, :master, :slave, :passive, :uncalibrated, :pre_master] do
        assert S.next(st, :fault_detected) == :faulty
        assert S.next(st, :designated_disabled) == :disabled
        assert S.next(st, :initialize) == :initializing
      end

      assert S.next(:faulty, :fault_cleared) == :initializing
      assert S.next(:disabled, :designated_enabled) == :initializing
      assert S.next(:faulty, :rs_master) == :faulty
    end

    test "slave-only clocks never become master" do
      assert S.next(:listening, :announce_receipt_timeout, true) == :listening
      assert S.next(:slave, :rs_master, true) == :listening
      assert S.next(:disabled, :rs_master, true) == :disabled
      assert S.next(:listening, :rs_slave, true) == :uncalibrated
    end
  end

  describe "profiles" do
    test "AES67 and SMPTE ranges" do
      p = ExPtp.Profile.get(:aes67)
      assert p.domain == 0 and p.log_announce_interval == 0 and p.log_sync_interval == -3
      assert ExPtp.Profile.in_range?(p, :sync, -4)
      refute ExPtp.Profile.in_range?(p, :sync, -5)
      assert ExPtp.Profile.interval_ns(-3) == 125_000_000
      assert ExPtp.Profile.interval_ns(1) == 2_000_000_000
      s = ExPtp.Profile.get(:smpte_2059_2)
      assert s.domain == 127 and s.log_announce_interval == -2
      assert Enum.sort(ExPtp.Profile.names()) == [:aes67, :default, :smpte_2059_2]
    end

    test "slave-only default data set forces class 255" do
      assert Default.new(id(1), slave_only: true, clock_class: 6).clock_quality.clock_class == 255
    end
  end
end
