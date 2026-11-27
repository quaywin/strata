defmodule Strata.UI.Components.SQLTabPickerModal do
  @moduledoc """
  Searchable picker modal shown when opening a SQL tab (`[+ SQL]` / `Ctrl+T`) while
  recently closed SQL tabs exist. Lets the user create a blank SQL tab or reopen any
  closed query tab (showing closed timestamp, tab name, AI chat count, and SQL preview).
  """

  defstruct closed_tabs: [],
            filter: "",
            selected_index: 0

  @type t :: %__MODULE__{
          closed_tabs: [map()],
          filter: String.t(),
          selected_index: non_neg_integer()
        }

  @doc """
  Initializes a `SQLTabPickerModal` with the list of recently closed SQL tabs.
  """
  @spec new([map()]) :: t()
  def new(closed_tabs \\ []) when is_list(closed_tabs) do
    %__MODULE__{closed_tabs: closed_tabs, filter: "", selected_index: 0}
  end

  @doc """
  Returns the visible list of selectable items (`+ New Blank SQL Tab` + filtered closed tabs).
  """
  @spec visible_items(t()) :: [map()]
  def visible_items(%__MODULE__{closed_tabs: closed_tabs, filter: filter}) do
    q = String.downcase(String.trim(to_string(filter || "")))

    filtered =
      if q == "" do
        closed_tabs
      else
        Enum.filter(closed_tabs, fn tab ->
          haystack =
            String.downcase(
              "#{Map.get(tab, :name, "")} #{Map.get(tab, :content, "")} #{format_closed_at(Map.get(tab, :closed_at))}"
            )

          String.contains?(haystack, q)
        end)
      end

    closed_items =
      Enum.map(filtered, fn tab ->
        %{
          kind: :closed_tab,
          id: Map.get(tab, :id),
          tab: tab,
          label: format_closed_item_label(tab)
        }
      end)

    [%{kind: :new_blank, id: "__new_blank__", label: "+ New Blank SQL Tab"}] ++ closed_items
  end

  @doc """
  Formats `"YYYY-MM-DDTHH:MM:SS"` into compact `"DD/MM HH:MM"` for the picker list.
  """
  @spec format_closed_at(String.t() | nil) :: String.t()
  def format_closed_at(iso) when is_binary(iso) do
    case NaiveDateTime.from_iso8601(String.trim(iso)) do
      {:ok, ndt} ->
        dd = ndt.day |> Integer.to_string() |> String.pad_leading(2, "0")
        mm = ndt.month |> Integer.to_string() |> String.pad_leading(2, "0")
        hh = ndt.hour |> Integer.to_string() |> String.pad_leading(2, "0")
        mi = ndt.minute |> Integer.to_string() |> String.pad_leading(2, "0")
        "#{dd}/#{mm} #{hh}:#{mi}"

      _ ->
        "--/-- --:--"
    end
  end

  def format_closed_at(_), do: "--/-- --:--"

  @doc """
  Handles keyboard navigation, live search filtering, reopen, new tab, delete, and cancel.
  """
  def handle_key(%__MODULE__{} = modal, key) do
    items = visible_items(modal)
    max_idx = max(0, length(items) - 1)
    idx = min(modal.selected_index, max_idx)

    case key do
      :esc ->
        if String.trim(modal.filter || "") != "" do
          %{modal | filter: "", selected_index: 0}
        else
          {:cancel, modal}
        end

      :up ->
        next = if idx <= 0, do: max_idx, else: idx - 1
        %{modal | selected_index: next}

      :down ->
        next = if idx >= max_idx, do: 0, else: idx + 1
        %{modal | selected_index: next}

      :home ->
        %{modal | selected_index: 0}

      :end ->
        %{modal | selected_index: max_idx}

      :enter ->
        case Enum.at(items, idx) do
          %{kind: :new_blank} -> {:new_blank, modal}
          %{kind: :closed_tab, tab: tab} -> {:reopen, tab, modal}
          nil -> {:new_blank, modal}
        end

      k when k in [:delete, {:ctrl, "d"}] ->
        case Enum.at(items, idx) do
          %{kind: :closed_tab, id: closed_id} ->
            updated_closed = Enum.reject(modal.closed_tabs, &(Map.get(&1, :id) == closed_id))
            next_modal = %{modal | closed_tabs: updated_closed}
            new_max = max(0, length(visible_items(next_modal)) - 1)

            {:delete_closed, closed_id, %{next_modal | selected_index: min(idx, new_max)}}

          _ ->
            modal
        end

      k when k in [{:ctrl, "u"}, {:ctrl, "k"}] ->
        %{modal | filter: "", selected_index: 0}

      :backspace ->
        f = modal.filter || ""
        new_f = String.slice(f, 0, max(0, String.length(f) - 1))
        %{modal | filter: new_f, selected_index: 0}

      ch when is_binary(ch) ->
        if String.printable?(ch) do
          %{modal | filter: (modal.filter || "") <> ch, selected_index: 0}
        else
          modal
        end

      _ ->
        modal
    end
  end

  defp format_closed_item_label(tab) do
    ts = format_closed_at(Map.get(tab, :closed_at))
    name = Map.get(tab, :name) || "Query"
    ai_cnt = length(Map.get(tab, :ai_messages, []))
    ai_part = if ai_cnt > 0, do: " [AI:#{ai_cnt}]", else: ""

    sql_one_line =
      tab
      |> Map.get(:content, "")
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    preview =
      cond do
        sql_one_line == "" -> "(AI chat only)"
        String.length(sql_one_line) > 34 -> String.slice(sql_one_line, 0, 33) <> "…"
        true -> sql_one_line
      end

    "↺ #{ts} · #{name}#{ai_part} · #{preview}"
  end
end
