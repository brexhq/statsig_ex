defmodule StatsigEx.StatsigExTest do
  use ExUnit.Case

  test "retrieving the tier works as expected" do
    assert :test_test == StatsigEx.get_tier(:test)
  end
end
