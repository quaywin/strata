defmodule DBData.UI.Renderer do
  @moduledoc """
  Ratatui layout dispatcher and component tree renderer helper.
  Partitions terminal window into grid chunks and dispatches rendering for panes and modals.
  """

  alias DBData.UI.Components.DataGrid
  alias DBData.UI.Components.Footer
  alias DBData.UI.Components.LogPane
  alias DBData.UI.Components.Sidebar
  alias DBData.UI.Components.SQLEditor

  @type rect :: %{x: non_neg_integer(), y: non_neg_integer(), width: pos_integer(), height: pos_integer()}

  @doc """
  Computes layout grid rectangles for main UI panes based on window size {width, height}.
  """
  @spec layout({pos_integer(), pos_integer()}) :: map()
  def layout({width, height}) when is_integer(width) and is_integer(height) do
    footer_height = 1
    header_height = 1

    content_height = max(1, height - footer_height - header_height)

    sidebar_width = max(24, min(40, round(width * 0.25)))
    right_width = max(1, width - sidebar_width)

    editor_height = round(content_height * 0.35)
    datagrid_height = round(content_height * 0.45)
    log_height = max(1, content_height - editor_height - datagrid_height)

    %{
      header: %{x: 0, y: 0, width: width, height: header_height},
      sidebar: %{x: 0, y: header_height, width: sidebar_width, height: content_height},
      editor: %{
        x: sidebar_width,
        y: header_height,
        width: right_width,
        height: editor_height
      },
      datagrid: %{
        x: sidebar_width,
        y: header_height + editor_height,
        width: right_width,
        height: datagrid_height
      },
      log: %{
        x: sidebar_width,
        y: header_height + editor_height + datagrid_height,
        width: right_width,
        height: log_height
      },
      footer: %{
        x: 0,
        y: height - footer_height,
        width: width,
        height: footer_height
      }
    }
  end

  @doc """
  Computes centered rect area for overlay modals given window size and desired modal dimensions.
  """
  @spec modal_layout({pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}) :: rect()
  def modal_layout({ww, wh}, {mw, mh}) do
    width = min(ww, mw)
    height = min(wh, mh)
    x = max(0, div(ww - width, 2))
    y = max(0, div(wh - height, 2))

    %{x: x, y: y, width: width, height: height}
  end

  @doc """
  Renders the complete UI component tree for current app state.
  """
  def render(app) do
    areas = layout(app.window_size)

    sidebar_chunk = Sidebar.render(app, areas.sidebar)
    footer_chunk = Footer.render(app, areas.footer)

    header_chunk = %{
      area: areas.header,
      tabs: app.tabs,
      active_tab_id: app.active_tab_id
    }

    editor_chunk = SQLEditor.render(app, areas.editor)
    datagrid_chunk = DataGrid.render(app, areas.datagrid, app.datagrid_state || DataGrid.new())
    log_chunk = LogPane.render(app, areas.log, app.log_state || LogPane.new())

    modal_chunk =
      case app.modals do
        [top | _] ->
          modal_area = modal_layout(app.window_size, {60, 20})

          %{
            title: Map.get(top, :title, "Modal"),
            type: Map.get(top, :type, :generic),
            area: modal_area,
            data: top
          }

        [] ->
          nil
      end

    %{
      window_size: app.window_size,
      active_focus: app.focus,
      chunks: %{
        header: header_chunk,
        sidebar: sidebar_chunk,
        editor: editor_chunk,
        datagrid: datagrid_chunk,
        log: log_chunk,
        footer: footer_chunk
      },
      modal: modal_chunk
    }
  end

  @doc """
  Converts rendered component tree into ANSI terminal string representation.
  """
  def to_ansi(app) do
    {width, _height} = app.window_size

    header_line = "\e[1;44;37m 🗄️  DBData TUI — Database Manager \e[0m" <> String.duplicate(" ", max(0, width - 36)) <> "\n"
    sidebar = " [🔌 CONNECTIONS]\n  ├─ 📂 public\n  │   ├─ 📋 users\n  │   └─ 📋 orders\n"
    editor = " [📜 SQL EDITOR]\n  1 │ SELECT * FROM users LIMIT 50;\n"
    datagrid = " [📊 DATA GRID (0 rows)]\n  (No data loaded)\n"
    footer = "\n\e[7m <F1> Conn  <F2> SQL  <F5> Run  <F6> Table Data  <Ctrl+A> Add Conn  <q> Quit \e[0m"

    header_line <> sidebar <> "\n" <> editor <> "\n" <> datagrid <> footer
  end
end

