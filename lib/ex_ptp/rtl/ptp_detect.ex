defmodule ExPtp.RTL.PtpDetect do
  @moduledoc """
  PTP message detection on an AXI4-Stream passively tapped: no stream
  signals are driven, the design observes accepted beats.

  Recognised, after zero, one or two VLAN tags (TPID 0x8100 or 0x88A8):

    * L2: EtherType 0x88F7
    * IPv4 (version 4, IHL 5) UDP with destination port 319 or 320

  The first 51 bytes of each frame are kept in a small register file
  (byte `p` of beat `p div (width/8)`, lane `p mod (width/8)`, little endian
  lanes: byte 0 in `tdata[7:0]`), and the classification is combinational
  from it, so it is valid in the cycle after the beat holding the last
  needed byte was accepted. Not detected: IPv6, IP options, three or more
  tags, fragments (such frames just pass as non-PTP).

  Inputs: `valid` (a beat is accepted this cycle, `tvalid and tready`),
  `data`, `keep`, `last`. Bytes beyond a short last beat (`keep` low) count as absent. Outputs describe the frame of the beat accepted most
  recently and stay until the next frame's first beat is accepted:

  | Output | Meaning |
  |---|---|
  | `beat` | index of that beat in the frame (saturates at 254) |
  | `ptp` | PTP message recognised and its messageType byte was seen |
  | `udp` | ... transported over UDP (else L2) |
  | `mtype` | messageType (4 bits), valid with `ptp` |
  | `ptp_off` | byte offset of the PTP header, valid with `ptp` |
  | `ev_port` | UDP destination port 319 seen (event port; valid earlier than `ptp`) |
  | `l4_off` | byte offset of the UDP header, valid with `ev_port` |

  `classify/1` is the same decision as an Elixir model on a whole frame.
  """
  use ExHdl.RTL
  import Bitwise

  @need 51
  @tpids [0x8100, 0x88A8]

  @doc """
  `%{ptp: bool, udp: bool, mtype: 0..15, ptp_off: n, ev_port: bool, l4_off: n}`
  for a frame (binary) as the hardware decides it.

      iex> ExPtp.RTL.PtpDetect.classify(<<0::96, 0x88F7::16, 1, 0::400>>).mtype
      1
  """
  def classify(frame) do
    none = %{ptp: false, udp: false, mtype: 0, ptp_off: 0, ev_port: false, l4_off: 0}
    seek(frame, 12, 0, none)
  end

  defp seek(f, off, tags, none) when byte_size(f) >= off + 2 and tags <= 2 do
    <<_::binary-size(off), et::16, _::binary>> = f
    l = off + 2

    cond do
      et in @tpids and tags < 2 ->
        seek(f, off + 4, tags + 1, none)

      et in @tpids ->
        none

      et == 0x88F7 and byte_size(f) > l ->
        %{none | ptp: true, mtype: byte(f, l) &&& 15, ptp_off: l}

      et == 0x0800 ->
        ipv4(f, l, none)

      true ->
        none
    end
  end

  defp seek(_, _, _, none), do: none

  defp ipv4(f, l, none) do
    with true <- byte_size(f) > l + 23,
         0x45 <- byte(f, l),
         17 <- byte(f, l + 9),
         port when port in [319, 320] <- byte(f, l + 22) <<< 8 ||| byte(f, l + 23) do
      info = %{none | ev_port: port == 319, l4_off: l + 20}

      if byte_size(f) > l + 28,
        do: %{info | ptp: true, udp: true, mtype: byte(f, l + 28) &&& 15, ptp_off: l + 28},
        else: info
    else
      _ -> none
    end
  end

  defp byte(f, i), do: :binary.at(f, i)

  @outs [:beat, :ptp, :udp, :mtype, :ptp_off, :ev_port, :l4_off]

  @doc "`outs` selects the output ports (all by default); unused outputs of an instance do not lint clean."
  def build(bits \\ 64, outs \\ @outs) do
    wb = div(bits, 8)
    nbeats = div(@need + wb - 1, wb)

    tag =
      if outs == @outs,
        do: "",
        else: "_" <> Enum.map_join(outs, "", &(&1 |> Atom.to_string() |> String.first()))

    module "ptp_detect_w#{bits}#{tag}" do
      valid = input(:valid, 1)
      data = input(:data, bits)
      keep = input(:keep, wb)
      last = input(:last, 1)
      out = fn name, w -> if name in outs, do: output(name, w) end
      beat = out.(:beat, 8)
      ptp = out.(:ptp, 1)
      udp = out.(:udp, 1)
      mtype = out.(:mtype, 4)
      ptp_off = out.(:ptp_off, 6)
      ev_port = out.(:ev_port, 1)
      l4_off = out.(:l4_off, 6)

      first = reg(:first, 1, reset: 1)
      nb = reg(:nb, 8)
      keep_r = reg(:keep_r, wb)
      hb = for k <- 0..(nbeats - 1), do: reg(:"hb#{k}", bits)

      idx = wire(:idx, mux(first, 0, nb))

      sync do
        if valid do
          first <~ last
          keep_r <~ keep
          if idx != 255, do: nb <~ add_wrap(idx, 1)
          if idx == 255, do: nb <~ 255

          for {r, k} <- Enum.with_index(hb) do
            if idx == k, do: r <~ data
          end
        end
      end

      byte = fn p ->
        r = Enum.at(hb, div(p, wb))
        lane = rem(p, wb)
        r[(lane * 8)..(lane * 8 + 7)]
      end

      # earlier beats are full, the newest one is as wide as its tkeep says
      have = fn p -> nb > div(p, wb) + 1 or (nb == div(p, wb) + 1 and keep_r[rem(p, wb)]) end
      tag? = fn et -> et == hd(@tpids) or et == List.last(@tpids) end
      pair = fn p -> cat([byte.(p), byte.(p + 1)]) end

      # one candidate per number of tags
      cands =
        for n <- 0..2 do
          l = 14 + 4 * n
          et = pair.(l - 2)
          tags = for k <- 0..(n - 1)//1, do: tag?.(pair.(12 + 4 * k))
          ok = Enum.reduce(tags, have.(l - 1) and not tag?.(et), &(&1 and &2))
          l2 = ok and et == 0x88F7 and have.(l)

          ip =
            ok and et == 0x0800 and have.(l + 23) and byte.(l) == 0x45 and byte.(l + 9) == 17 and
              (pair.(l + 22) == 319 or pair.(l + 22) == 320)

          %{
            l2: l2,
            ip: ip,
            ev: ip and pair.(l + 22) == 319,
            udp: ip and have.(l + 28),
            mt: mux(l2, byte.(l)[0..3], byte.(l + 28)[0..3]),
            off: mux(l2, const(l, u(6)), const(l + 28, u(6)))
          }
        end

      any = fn f -> Enum.reduce(cands, false, fn c, acc -> acc or f.(c) end) end
      udp_full = wire(:udp_full, any.(& &1.udp))
      l2_full = wire(:l2_full, any.(& &1.l2))

      pick = fn field, w ->
        Enum.reduce(cands, const(0, u(w)), fn c, acc ->
          mux(c.l2 or c.udp, c |> Map.fetch!(field) |> resize(w), acc)
        end)
      end

      if :beat in outs, do: beat <~ sub_wrap(nb, 1)
      if :ptp in outs, do: ptp <~ (udp_full or l2_full)
      if :udp in outs, do: udp <~ udp_full
      if :ev_port in outs, do: ev_port <~ any.(& &1.ev)
      if :mtype in outs, do: mtype <~ pick.(:mt, 4)
      if :ptp_off in outs, do: ptp_off <~ pick.(:off, 6)

      if :l4_off in outs do
        l4_off
        <~ Enum.reduce(Enum.with_index(cands), const(0, u(6)), fn {c, n}, acc ->
          mux(c.ip, const(34 + 4 * n, u(6)), acc)
        end)
      end
    end
  end
end
