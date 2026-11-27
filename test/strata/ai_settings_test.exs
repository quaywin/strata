defmodule Strata.AISettingsTest do
  use ExUnit.Case, async: false

  alias Strata.AISettings
  alias Strata.AISettingsStore

  describe "AISettings" do
    test "serializes and deserializes settings safely" do
      settings = %AISettings{
        provider: :codex,
        model: "gpt-5.4",
        context_scope: :focused_only,
        keep_conversation: false
      }

      map = AISettings.to_map(settings)
      assert map["provider"] == "codex"
      assert map["model"] == "gpt-5.4"
      assert map["context_scope"] == "focused_only"
      assert map["keep_conversation"] == false

      decoded = AISettings.from_map(map)
      assert decoded == settings
    end

    test "normalizes invalid provider or scope values safely" do
      decoded =
        AISettings.from_map(%{
          "provider" => "unknown",
          "model" => "  sonnet  ",
          "context_scope" => "invalid",
          "keep_conversation" => true
        })

      assert decoded.provider in AISettings.providers()
      assert decoded.model == "sonnet"
      assert decoded.context_scope == :focused_and_related
      assert decoded.keep_conversation == true
    end
  end

  describe "AISettingsStore" do
    test "persists settings to disk and reloads on restart" do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "strata_ai_settings_test_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(tmp_path) end)

      name = :"ai_store_#{System.unique_integer([:positive])}"
      {:ok, pid1} = AISettingsStore.start_link(name: name, settings_path: tmp_path)

      custom = %AISettings{
        provider: :agy,
        model: "gemini-pro",
        context_scope: :focused_only,
        keep_conversation: false
      }

      assert :ok == AISettingsStore.put(pid1, custom)
      assert AISettingsStore.get(pid1) == custom
      GenServer.stop(pid1)

      {:ok, pid2} = AISettingsStore.start_link(name: name, settings_path: tmp_path)
      assert AISettingsStore.get(pid2) == custom
      GenServer.stop(pid2)
    end
  end
end
