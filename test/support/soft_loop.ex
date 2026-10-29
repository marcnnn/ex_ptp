defmodule ExPtp.Test.SoftLoop do
  @moduledoc false
  # A master and a slave `ExPtp.Clock.Wallclock` on two crystals with a frequency error each, a link with
  # delay and jitter and timestamp noise; `exchange/1` plays one Sync + Delay_Req round trip and returns
  # t1..t4 for a servo. Everything is deterministic (seeded) and in integer arithmetic except the noise draw.
  alias ExPtp.Clock
  alias ExPtp.Clock.Wallclock, as: WC
  alias ExPtp.Timestamp

  defstruct [:master, :slave, :opts, :rng, k: 0]

  @defaults [
    hz: 125_000_000,
    interval_ns: 125_000_000,
    delay_ns: 5_000,
    jitter_ns: 200,
    noise_ns: 0,
    master_ppb: -20_000,
    slave_ppb: 50_000,
    init_offset_ns: 3_000_000,
    seed: 7,
    start: 1_000
  ]

  def new(opts \\ []) do
    o = Keyword.merge(@defaults, opts)
    t0 = Timestamp.new(o[:start])

    master = WC.start(hz: o[:hz], time: t0, drift_ppb: o[:master_ppb])

    slave =
      WC.start(
        hz: o[:hz],
        time: Timestamp.add_ns(t0, o[:init_offset_ns]),
        drift_ppb: o[:slave_ppb],
        adj_ppb: Keyword.get(o, :slave_adj_ppb, 0)
      )

    %__MODULE__{master: master, slave: slave, opts: o, rng: :rand.seed_s(:exsss, o[:seed])}
  end

  @doc "The slave's clock (the one a servo steers)."
  def slave(%__MODULE__{slave: s}), do: s

  @doc "True offset: slave minus master at this instant, ns."
  def offset_ns(%__MODULE__{master: m, slave: s}),
    do: Timestamp.diff_ns(Clock.now(s), Clock.now(m))

  defp advance(b, ns) do
    WC.advance(elem(b.master, 1), ns)
    WC.advance(elem(b.slave, 1), ns)
  end

  defp draw(rng, n) when n <= 0, do: {0, rng}

  defp draw(rng, n) do
    {v, rng} = :rand.uniform_s(n + 1, rng)
    {v - 1, rng}
  end

  defp noisy(ts, rng, n) when n > 0 do
    {v, rng} = draw(rng, 2 * n)
    {Timestamp.add_ns(ts, v - n), rng}
  end

  defp noisy(ts, rng, _), do: {ts, rng}

  @doc """
  One exchange spread over a sync interval: Sync leaves the master (`t1`), arrives at the slave
  after delay + jitter (`t2`), the Delay_Req leaves the slave 1 ms later (`t3`), arrives at the master (`t4`);
  the rest of the interval passes. Returns `{{t1, t2, t3, t4}, bench}`.
  """
  def exchange(%__MODULE__{opts: o, rng: rng} = b) do
    t1 = Clock.now(b.master)
    {j1, rng} = draw(rng, o[:jitter_ns])
    advance(b, o[:delay_ns] + j1)
    {t2, rng} = noisy(Clock.now(b.slave), rng, o[:noise_ns])
    advance(b, 1_000_000)
    t3 = Clock.now(b.slave)
    {j2, rng} = draw(rng, o[:jitter_ns])
    advance(b, o[:delay_ns] + j2)
    {t4, rng} = noisy(Clock.now(b.master), rng, o[:noise_ns])
    advance(b, o[:interval_ns] - 1_000_000 - 2 * o[:delay_ns] - j1 - j2)
    {{t1, t2, t3, t4}, %{b | rng: rng, k: b.k + 1}}
  end

  @doc "Intervals until every later |offset| is below `bound` (nil if never)."
  def settled(trace, bound) do
    Enum.find(0..(length(trace) - 1)//1, fn i ->
      trace |> Enum.drop(i) |> Enum.all?(&(abs(&1) < bound))
    end)
  end
end
