defmodule StrataTest do
  use ExUnit.Case
  doctest Strata

  test "application starts successfully" do
    assert {:ok, _pid} = Application.ensure_all_started(:strata)
  end
end
