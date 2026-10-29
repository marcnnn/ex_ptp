defmodule ExPtp.ClockTest do
  use ExUnit.Case, async: true

  alias ExPtp.{Clock, Timestamp, Wallclock}
  alias ExPtp.Clock.Wallclock, as: WC

  doctest ExPtp.Clock
  doctest ExPtp.Clock.System
  doctest ExPtp.Clock.Wallclock

  test "the wallclock clock is the model: increment, step and set" do
    {_, pid} = clock = WC.start(hz: 125_000_000, time: Timestamp.new(10))
    nominal = Wallclock.nominal_increment(125_000_000)

    assert Clock.caps(clock) == [:adj_freq, :step, :set]
    assert WC.increment(pid) == nominal
    WC.advance(pid, 1_000_000_000)
    assert Clock.now(clock) == Timestamp.new(11)

    :ok = Clock.adj_freq(clock, -70_000)
    assert WC.increment(pid) == Wallclock.increment(nominal, -70_000)
    assert_in_delta Clock.freq(clock), -70_000, 0.1

    :ok = Clock.step(clock, -250)
    assert Clock.now(clock) == Timestamp.add_ns(Timestamp.new(11), -250)
    :ok = Clock.set(clock, Timestamp.new(500, 7))
    assert Clock.now(clock) == Timestamp.new(500, 7)
  end

  test "drift: ticks of the crystal, corrected by the adjustment" do
    {_, pid} = clock = WC.start(hz: 1_000_000, drift_ppb: 50_000)
    WC.advance(pid, 10_000_000_000)
    assert Timestamp.diff_ns(Clock.now(clock), Timestamp.new(10)) == 500_000

    # -50 ppm on top cancels the crystal up to the product of the two (2.5 ppb)
    {_, pid} = clock = WC.start(hz: 1_000_000, drift_ppb: 50_000, adj_ppb: -50_000)
    WC.advance(pid, 10_000_000_000)
    assert abs(Timestamp.diff_ns(Clock.now(clock), Timestamp.new(10))) <= 30
  end

  test "advance in pieces equals advance at once" do
    {_, a} = WC.start(hz: 7_000_000, drift_ppb: 33_333)
    {_, b} = WC.start(hz: 7_000_000, drift_ppb: 33_333)
    for _ <- 1..100, do: WC.advance(a, 12_345_679)
    WC.advance(b, 1_234_567_900)
    assert WC.state(a) == WC.state(b)
  end

  test "the system clock is read only" do
    clock = {Clock.System, []}
    assert Clock.caps(clock) == []
    refute Clock.steerable?(clock)
    assert Clock.adj_freq(clock, 10) == {:error, :read_only}
    assert Clock.set(clock, Timestamp.new(1)) == {:error, :read_only}
    a = Clock.now(clock)
    b = Clock.now(clock)
    assert Timestamp.diff_ns(b, a) >= 0
    assert abs(Timestamp.diff_ns(a, Timestamp.from_ns(System.os_time(:nanosecond)))) < 1_000_000_000
    assert Clock.now({Clock.System, tai_offset_s: 37}).seconds - a.seconds in 36..38
  end
end
