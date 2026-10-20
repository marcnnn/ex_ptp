defmodule ExPtp.RTL.TsFifo do
  @moduledoc """
  Small first-word-fall-through FIFO on distributed RAM for timestamps and
  tags (`2^depth_log2` entries). A push into a full FIFO is dropped and
  reported on `overflow` (one cycle).

  Ports: `push`, `din`, `pop`, `dout` (head, valid when `empty` is low),
  `empty`, `overflow`, and `full`, `level` unless built with `status: false`
  (an unused instance output does not lint clean). Popping an empty FIFO does nothing.
  """
  use ExHdl.RTL

  def build(width, depth_log2 \\ 2, opts \\ []) do
    n = depth_log2
    status? = Keyword.get(opts, :status, true)

    module "ptp_fifo_w#{width}_d#{n}#{if status?, do: "", else: "_q"}" do
      push = input(:push, 1)
      din = input(:din, width)
      pop = input(:pop, 1)
      dout = output(:dout, width)
      empty = output(:empty, 1)
      overflow = output(:overflow, 1, reset: 0)

      mem = memory(:mem, width: width, depth: 1 <<< n, style: :distributed)
      wp = reg(:wp, n + 1)
      rp = reg(:rp, n + 1)
      count = wire(:count, sub_wrap(wp, rp))
      is_empty = wire(:is_empty, count == 0)
      is_full = wire(:is_full, count == 1 <<< n)
      head = read_port(mem, kind: :async, addr: rp[0..(n - 1)])
      write_port(mem, addr: wp[0..(n - 1)], data: din, en: push and not is_full)

      dout <~ head
      empty <~ is_empty

      if status? do
        output(:full, 1) <~ is_full
        output(:level, n + 1) <~ count
      end

      sync do
        overflow <~ (push and is_full)
        if push and not is_full, do: wp <~ add_wrap(wp, 1)
        if pop and not is_empty, do: rp <~ add_wrap(rp, 1)
      end
    end
  end
end
