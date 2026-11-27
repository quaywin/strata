defmodule Strata.UI.Components.UpdateModalTest do
  use ExUnit.Case, async: true

  alias Strata.UI.App
  alias Strata.UI.Components.{ActionsModal, DataGrid, UpdateModal}
  alias Strata.UI.Renderer

  describe "UpdateModal" do
    test "initializes, navigates buttons, and renders cleanly" do
      modal =
        UpdateModal.new(
          current_version: "0.1.9",
          install_target: %{
            mode: :burrito,
            binary_path: "/tmp/strata",
            target: :macos_aarch64,
            writable?: true,
            reason: nil
          }
        )

      assert modal.focused_field == :check_button
      assert UpdateModal.visible_buttons(modal) == [:check_button, :close_button]

      moved = UpdateModal.handle_key(modal, :tab)
      assert moved.focused_field == :close_button
      assert {:cancel, _} = UpdateModal.handle_key(moved, :enter)

      assert {:check, _} = UpdateModal.handle_key(modal, :enter)
      assert {:cancel, _} = UpdateModal.handle_key(modal, :esc)

      rendered = UpdateModal.render(modal, %{x: 0, y: 0, width: 76, height: 18})
      assert rendered.title == "APP UPDATE"
      assert Enum.any?(rendered.fields, &(&1.key == :current_version and &1.value == "v0.1.9"))
      assert Enum.any?(rendered.fields, &(&1.key == :check_button))
    end

    test "reveals Install Update button when an update is available" do
      modal =
        UpdateModal.new(
          current_version: "0.1.9",
          install_target: %{
            mode: :burrito,
            binary_path: "/tmp/strata",
            target: :macos_aarch64,
            writable?: true,
            reason: nil
          }
        )

      info = %{
        status: :update_available,
        current_version: "0.1.9",
        latest_version: "0.1.10",
        tag_name: "v0.1.10",
        release_name: "v0.1.10",
        release_url: "https://github.com/quaywin/strata/releases/tag/v0.1.10",
        release_notes: "# Release\nImproved update flow",
        published_at: "2026-11-27T10:00:00Z",
        target: :macos_aarch64,
        asset_name: "strata_macos_aarch64",
        download_url: "https://example.test/strata_macos_aarch64",
        asset_size: 1024,
        asset_digest: nil
      }

      updated = UpdateModal.apply_check_result(modal, {:ok, info})
      assert updated.status == :update_available
      assert updated.latest_version == "0.1.10"
      assert updated.focused_field == :update_button
      assert updated.release_notes == "Improved update flow"

      assert UpdateModal.visible_buttons(updated) == [
               :check_button,
               :update_button,
               :close_button
             ]

      assert {:install, _} = UpdateModal.handle_key(updated, :enter)

      done =
        UpdateModal.apply_install_result(
          updated,
          {:ok, %{version: "0.1.10", tag_name: "v0.1.10", binary_path: "/tmp/strata"}}
        )

      assert done.status == :updated
      assert done.status_message =~ "Updated to v0.1.10"
      assert done.focused_field == :close_button
    end

    test "formats exception and POSIX errors cleanly on check/install failure" do
      modal = UpdateModal.new(current_version: "0.1.9")

      err = %RuntimeError{message: "GitHub API unavailable"}
      failed_check = UpdateModal.apply_check_result(modal, {:error, err})
      assert failed_check.status == :error
      assert failed_check.status_message == "❌ GitHub API unavailable"

      failed_install = UpdateModal.apply_install_result(modal, {:error, :eacces})
      assert failed_install.status == :error
      assert failed_install.status_message == "❌ Update failed: Permission denied (:eacces)"
    end
  end

  describe "App and ActionsModal update integration" do
    test "ActionsModal includes Check for Updates and displays badge when update_info is present" do
      grid = DataGrid.new(["id"], [[1]])

      default_actions = ActionsModal.new(grid, :table_view)
      assert Enum.any?(default_actions.items, &(&1.id == :check_updates))

      badged_actions =
        ActionsModal.new(grid, :table_view,
          update_info: %{status: :update_available, latest_version: "0.1.10"}
        )

      item = Enum.find(badged_actions.items, &(&1.id == :check_updates))
      assert item.label =~ "0.1.10"
    end

    test "App handles startup update notification, UpdateModal messages, and rendering" do
      app = App.new(terminal: false)

      info = %{
        status: :update_available,
        current_version: "0.1.9",
        latest_version: "0.1.10",
        tag_name: "v0.1.10",
        release_name: "v0.1.10",
        release_url: "https://github.com/quaywin/strata/releases/tag/v0.1.10",
        release_notes: "Release notes",
        published_at: nil,
        target: :macos_aarch64,
        asset_name: "strata_macos_aarch64",
        download_url: "https://example.test/strata_macos_aarch64",
        asset_size: 100,
        asset_digest: nil
      }

      {:noreply, app_notified} =
        App.handle_info({:startup_update_check_finished, {:ok, info}}, app)

      assert app_notified.update_info == info
      assert app_notified.status_message =~ "v0.1.10"

      app_with_modal = App.open_update_modal(app_notified)
      assert [%UpdateModal{status: :update_available}] = app_with_modal.modals

      widgets = Renderer.render(app_with_modal)
      assert is_list(widgets) and length(widgets) > 0

      closed_app = App.handle_key(app_with_modal, :esc)
      assert closed_app.modals == []
    end
  end
end
