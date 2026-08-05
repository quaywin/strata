defmodule DBDataTest do
  use ExUnit.Case
  doctest DBData

  test "application starts successfully" do
    assert {:ok, _pid} = Application.ensure_all_started(:db_data)
  end
end
