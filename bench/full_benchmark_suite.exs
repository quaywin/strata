# Comprehensive Micro-Benchmark Suite for Strata (Pure Native Elixir)
# Run with: mix run bench/full_benchmark_suite.exs

alias Strata.DataStore
alias Strata.Formatter
alias Strata.UI.Components.DataGrid
alias Strata.UI.Renderer

IO.puts("=================================================================")
IO.puts(" 🗄️ Strata Comprehensive Benchmark Suite")
IO.puts("=================================================================\n")

_ = DataGrid.new()
_ = DataStore.start_link()

columns = ["id", "uuid", "created_at", "status", "amount", "payload"]

sample_rows_5k =
  Enum.map(1..5_000, fn i ->
    uuid_bin = <<i::32, 0::96>>

    [
      i,
      uuid_bin,
      "2026-08-07 12:34:56.789",
      Enum.at(["active", "pending", "completed", "failed"], rem(i, 4)),
      1234.56 + i,
      %{"user_id" => i, "meta" => "test_payload_string"}
    ]
  end)

DataStore.put_result_set("bench_tab", columns, sample_rows_5k)

grid_5k = DataGrid.new(columns, sample_rows_5k, page_size: 50)
app_mock = %{
  window_size: {120, 40},
  active_view: :table_view,
  selected_table: "bench_users",
  datagrid_state: grid_5k,
  focus: :datagrid,
  sidebar_nodes: [],
  selected_tree_node_id: nil,
  modals: []
}

static_w = DataGrid.static_widths(columns, sample_rows_5k)

benchmarks = [
  # 1. Formatter
  {"[Formatter] sanitize_cell (Integer)", fn -> Formatter.sanitize_cell(12_345_678) end},
  {"[Formatter] sanitize_cell (16-byte Raw Binary UUID)", fn -> Formatter.sanitize_cell(<<1234::32, 0::96>>) end},
  {"[Formatter] sanitize_cell (JSON Map)", fn -> Formatter.sanitize_cell(%{"status" => 200, "ok" => true}) end},

  # 2. DataStore (ETS Zero-Latency Reads)
  {"[DataStore] get_page (ETS 50 rows slice from 5,000)", fn -> DataStore.get_page("bench_tab", 1, 50) end},
  {"[DataStore] put_result_set (Insert 5,000 rows into ETS)", fn -> DataStore.put_result_set("bench_tab", columns, sample_rows_5k) end},

  # 3. DataGrid Viewport & Slicing Math
  {"[DataGrid] static_widths (Sampling 50 rows)", fn -> DataGrid.static_widths(columns, sample_rows_5k) end},
  {"[DataGrid] max_col_offset (O(1) precomputed integer list)", fn -> DataGrid.max_col_offset(static_w, 117) end},
  {"[DataGrid] move_selection (:down)", fn -> DataGrid.move_selection(grid_5k, :down, 27, max_width: 117, step: 3) end},

  # 4. Full UI Renderer (2D Matrix Virtual Slicing)
  {"[Renderer] render_datagrid (Render 5,000 rows viewport frame)", fn -> Renderer.render(app_mock) end}
]

run_bench = fn name, func ->
  # Warmup
  Enum.each(1..20, fn _ -> func.() end)

  iterations = 10_000
  {total_us, _} = :timer.tc(fn ->
    Enum.each(1..iterations, fn _ -> func.() end)
  end)

  avg_us = total_us / iterations
  ips = 1_000_000 / max(0.001, avg_us)

  formatted_ips =
    cond do
      ips >= 1_000_000 -> "#{Float.round(ips / 1_000_000, 2)}M ops/s"
      ips >= 1_000 -> "#{Float.round(ips / 1_000, 2)}K ops/s"
      true -> "#{Float.round(ips, 2)} ops/s"
    end

  formatted_time =
    cond do
      avg_us < 1.0 -> "#{Float.round(avg_us * 1_000, 2)} ns"
      avg_us < 1_000.0 -> "#{Float.round(avg_us, 2)} µs"
      true -> "#{Float.round(avg_us / 1_000, 2)} ms"
    end

  IO.puts(String.pad_trailing(name, 55) <> " │ " <> String.pad_leading(formatted_ips, 14) <> " │ " <> String.pad_leading(formatted_time, 10))
end

IO.puts("Benchmark Name                                          │       Throughput │    Avg Time")
IO.puts("────────────────────────────────────────────────────────┼──────────────────┼───────────")

Enum.each(benchmarks, fn {name, func} -> run_bench.(name, func) end)

IO.puts("────────────────────────────────────────────────────────┴──────────────────┴───────────\n")
