defmodule Strata.UI.Components.ActionsModalTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.KeyRegistry
  alias Strata.UI.Components.{ActionsModal, DataGrid}

  describe "ActionsModal" do
    test "includes commit/revert only when grid has staged changes and structure toggle only in :table_view" do
      clean_grid = DataGrid.new(["id", "name"], [[1, "Alice"]])
      clean_modal = ActionsModal.new(clean_grid, :query_view)
      clean_ids = Enum.map(clean_modal.items, & &1.id)

      refute :commit_changes in clean_ids
      refute :revert_changes in clean_ids
      refute :toggle_structure in clean_ids
      assert :edit_cell in clean_ids
      assert :sort_col in clean_ids

      dirty_grid = DataGrid.stage_cell_edit(clean_grid, 0, 1, "Bob")
      dirty_modal = ActionsModal.new(dirty_grid, :table_view)
      dirty_ids = Enum.map(dirty_modal.items, & &1.id)

      assert :commit_changes in dirty_ids
      assert :revert_changes in dirty_ids
      assert :toggle_structure in dirty_ids
    end

    test "supports wrap-around navigation, execution, and cancellation" do
      grid = DataGrid.new(["id"], [[1]])
      modal = ActionsModal.new(grid, :table_view)
      last_idx = length(modal.items) - 1

      # Up from index 0 wraps to last item
      wrapped_up = ActionsModal.handle_key(modal, :up)
      assert wrapped_up.selected_index == last_idx

      # Down wraps back to 0 and executes first action
      wrapped_down = ActionsModal.handle_key(wrapped_up, "j")
      assert wrapped_down.selected_index == 0

      first_id = hd(modal.items).id
      assert {:execute, ^first_id, _} = ActionsModal.handle_key(wrapped_down, :enter)
      assert {:cancel, _} = ActionsModal.handle_key(wrapped_down, "?")
      assert {:cancel, _} = ActionsModal.handle_key(wrapped_down, :esc)
    end
  end

  describe "Unified compact KeyRegistry" do
    test "selects compact contextual key sets with Actions trigger" do
      dirty_grid =
        DataGrid.new(["id", "name"], [[1, "Alice"]])
        |> DataGrid.stage_cell_edit(0, 1, "Bob")

      dirty_app = App.new(focus: :datagrid, datagrid_state: dirty_grid)
      assert KeyRegistry.determine_context(dirty_app) == :datagrid_dirty

      dirty_keys = Enum.map(KeyRegistry.get_shortcuts(dirty_app), &elem(&1, 0))
      assert "Ctrl+S" in dirty_keys
      assert "Ctrl+Z" in dirty_keys
      assert "?" in dirty_keys

      editing_app =
        App.new(
          focus: :datagrid,
          datagrid_state: %{dirty_grid | editing_cell: {0, 1}}
        )

      assert KeyRegistry.determine_context(editing_app) == :datagrid_editing
    end
  end
end
