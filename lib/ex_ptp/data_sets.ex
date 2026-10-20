defmodule ExPtp.DataSets do
  @moduledoc """
  The IEEE 1588 data sets of an ordinary clock (clause 8) as structs:
  `Default` (defaultDS), `Current` (currentDS), `Parent` (parentDS),
  `TimeProperties` (timePropertiesDS) and `Port` (portDS). The
  foreignMasterDS lives in `ExPtp.ForeignMasters`.

      iex> alias ExPtp.DataSets.Default
      iex> ds = Default.new(<<1, 2, 3, 4, 5, 6, 7, 8>>, profile: :aes67, clock_class: 248)
      iex> {ds.domain_number, ds.clock_quality.clock_class, ds.priority1}
      {0, 248, 128}
  """

  defmodule Default do
    @moduledoc "defaultDS. `slave_only` forces clockClass 255."
    defstruct [
      :clock_identity,
      two_step: true,
      number_ports: 1,
      clock_quality: %{clock_class: 248, clock_accuracy: 0xFE, offset_scaled_log_variance: 0xFFFF},
      priority1: 128,
      priority2: 128,
      domain_number: 0,
      slave_only: false,
      sdo_id: 0
    ]

    @doc """
    Options: `:profile` (priority and domain defaults, default `:default`),
    `:clock_class`, `:clock_accuracy`, `:offset_scaled_log_variance`,
    `:priority1`, `:priority2`, `:domain_number`, `:slave_only`, `:two_step`.
    """
    def new(clock_identity, opts \\ []) when byte_size(clock_identity) == 8 do
      p = ExPtp.Profile.get(opts[:profile] || :default)
      slave_only = Keyword.get(opts, :slave_only, false)

      quality = %{
        clock_class: if(slave_only, do: 255, else: opts[:clock_class] || 248),
        clock_accuracy: opts[:clock_accuracy] || 0xFE,
        offset_scaled_log_variance: opts[:offset_scaled_log_variance] || 0xFFFF
      }

      %__MODULE__{
        clock_identity: clock_identity,
        two_step: Keyword.get(opts, :two_step, true),
        clock_quality: quality,
        priority1: opts[:priority1] || p.priority1,
        priority2: opts[:priority2] || p.priority2,
        domain_number: opts[:domain_number] || p.domain,
        slave_only: slave_only
      }
    end
  end

  defmodule Current do
    @moduledoc "currentDS; `offset_from_master` and `mean_path_delay` in scaled ns."
    defstruct steps_removed: 0, offset_from_master: 0, mean_path_delay: 0
  end

  defmodule Parent do
    @moduledoc "parentDS, initialised from the clock's own defaultDS."
    defstruct [
      :parent_port_identity,
      :grandmaster_identity,
      :grandmaster_clock_quality,
      :grandmaster_priority1,
      :grandmaster_priority2,
      parent_stats: false,
      observed_parent_offset_scaled_log_variance: 0xFFFF,
      observed_parent_clock_phase_change_rate: 0x7FFFFFFF
    ]

    def from_default(%Default{} = d) do
      %__MODULE__{
        parent_port_identity: {d.clock_identity, 0},
        grandmaster_identity: d.clock_identity,
        grandmaster_clock_quality: d.clock_quality,
        grandmaster_priority1: d.priority1,
        grandmaster_priority2: d.priority2
      }
    end
  end

  defmodule TimeProperties do
    @moduledoc "timePropertiesDS. `time_source` 0xA is INTERNAL_OSCILLATOR."
    defstruct current_utc_offset: 37,
              current_utc_offset_valid: false,
              leap59: false,
              leap61: false,
              time_traceable: false,
              frequency_traceable: false,
              ptp_timescale: true,
              time_source: 0xA

    @doc "From an Announce message (flags and body)."
    def from_announce(%ExPtp.Message{body: b} = m) do
      f = &ExPtp.Message.flag?(m, &1)

      %__MODULE__{
        current_utc_offset: b.current_utc_offset,
        current_utc_offset_valid: f.(:current_utc_offset_valid),
        leap59: f.(:leap59),
        leap61: f.(:leap61),
        time_traceable: f.(:time_traceable),
        frequency_traceable: f.(:frequency_traceable),
        ptp_timescale: f.(:ptp_timescale),
        time_source: b.time_source
      }
    end

    @doc "Announce flag names for these properties."
    def flag_names(%__MODULE__{} = t) do
      for {on, name} <- [
            {t.current_utc_offset_valid, :current_utc_offset_valid},
            {t.leap59, :leap59},
            {t.leap61, :leap61},
            {t.time_traceable, :time_traceable},
            {t.frequency_traceable, :frequency_traceable},
            {t.ptp_timescale, :ptp_timescale}
          ],
          on,
          do: name
    end
  end

  defmodule Port do
    @moduledoc "portDS. `announce_receipt_timeout` is in announce intervals."
    defstruct [
      :port_identity,
      port_state: :initializing,
      log_min_delay_req_interval: 0,
      peer_mean_path_delay: 0,
      log_announce_interval: 0,
      announce_receipt_timeout: 3,
      log_sync_interval: -3,
      delay_mechanism: :e2e,
      log_min_pdelay_req_interval: 0,
      version_number: 2
    ]

    @doc "From a clock identity, port number and profile (`ExPtp.Profile`)."
    def new(clock_identity, port_number, profile \\ :default, overrides \\ []) do
      p = ExPtp.Profile.get(profile)

      struct!(
        %__MODULE__{
          port_identity: {clock_identity, port_number},
          log_min_delay_req_interval: p.log_min_delay_req_interval,
          log_announce_interval: p.log_announce_interval,
          announce_receipt_timeout: p.announce_receipt_timeout,
          log_sync_interval: p.log_sync_interval,
          delay_mechanism: p.delay_mechanism
        },
        overrides
      )
    end
  end
end
