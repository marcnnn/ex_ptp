defmodule ExPtp.PortState do
  @moduledoc """
  Port state machine of an ordinary clock (clause 9.2.5, table 27).

  States: `:initializing`, `:faulty`, `:disabled`, `:listening`,
  `:pre_master`, `:master`, `:passive`, `:uncalibrated`, `:slave`.

  Events: `:initialize`, `:initialized`, `:fault_detected`, `:fault_cleared`,
  `:designated_enabled`, `:designated_disabled`, `:rs_master`, `:rs_slave`,
  `:rs_slave_new_master`, `:rs_passive`, `:announce_receipt_timeout`,
  `:qualification_timeout`, `:master_clock_selected`,
  `:synchronization_fault`. A slave-only clock never becomes master: master
  recommendations and timeouts leave it in (or send it to) `:listening`.

      iex> alias ExPtp.PortState, as: S
      iex> :initializing |> S.next(:initialized) |> S.next(:rs_slave) |> S.next(:master_clock_selected)
      :slave
      iex> S.next(:slave, :announce_receipt_timeout)
      :master
      iex> S.next(:slave, :announce_receipt_timeout, true)
      :listening
  """

  @type state ::
          :initializing
          | :faulty
          | :disabled
          | :listening
          | :pre_master
          | :master
          | :passive
          | :uncalibrated
          | :slave

  @doc "Next state; unknown or irrelevant events leave the state unchanged."
  def next(state, event, slave_only \\ false)

  def next(_, :designated_disabled, _), do: :disabled
  def next(_, :fault_detected, _), do: :faulty
  def next(_, :initialize, _), do: :initializing
  def next(:initializing, :initialized, _), do: :listening
  def next(:faulty, :fault_cleared, _), do: :initializing
  def next(:disabled, :designated_enabled, _), do: :initializing

  def next(state, event, true) when event in [:rs_master, :announce_receipt_timeout] do
    if state in [:initializing, :faulty, :disabled], do: state, else: :listening
  end

  def next(state, :rs_master, _) when state in [:listening, :passive, :uncalibrated, :slave],
    do: :pre_master

  def next(:pre_master, :qualification_timeout, _), do: :master

  def next(state, :rs_slave, _) when state in [:listening, :pre_master, :master, :passive],
    do: :uncalibrated

  def next(state, :rs_slave_new_master, _) when state in [:uncalibrated, :slave],
    do: :uncalibrated

  def next(:uncalibrated, :master_clock_selected, _), do: :slave
  def next(:slave, :synchronization_fault, _), do: :uncalibrated

  def next(state, :rs_passive, _)
      when state in [:listening, :pre_master, :master, :uncalibrated, :slave],
      do: :passive

  def next(state, :announce_receipt_timeout, _)
      when state in [:listening, :passive, :uncalibrated, :slave],
      do: :master

  def next(state, _, _), do: state
end
